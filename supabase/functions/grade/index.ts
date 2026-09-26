// grade/index.ts
//
// Mark finished work against the student's own rubric.
//
// The first paid endpoint, and the most expensive call the app makes. Three
// things about it are deliberate:
//
//   * **The paywall is in Postgres.** `check_and_record_ai_usage` resolves the
//     plan, checks the weekly allowance and reserves the slot in one
//     transaction, under a per-user lock. A gate in this file — or on the
//     device — would be one `curl` away from free unlimited marking, and a gate
//     without the lock is one `curl -P` away from it (migration 0036).
//   * **The rubric is loaded by id, never read from the body.** It comes back
//     through the caller's own client, so RLS decides what the id resolves to.
//     A forged id resolves to nothing, not to a stranger's rubric.
//   * **The work is never stored.** Marks, feedback and a character count are
//     written; the essay itself exists only for the length of the request.

import { adminClient, requireUser } from "../_shared/auth.ts";
import { readJsonBody } from "../_shared/body.ts";
import { errorResponse, HttpError, jsonResponse, mapPostgresError } from "../_shared/http.ts";
import {
  assertAPIRequestRate,
  finalizeAIUsage,
  reserveAIUsage,
  usageFailureCode,
} from "../_shared/quota.ts";
import { noteRefusal, recordSignals, type Signals } from "../_shared/signals.ts";
import { loadPersonalRubric, resolveGradingRubric } from "../_shared/rubric.ts";
import { gradeWork, providerUsage } from "../_shared/anthropic.ts";
import {
  buildGradeSystemPrompt,
  buildGradeUserPrompt,
  type GradeBasis,
  gradeModelFor,
  InvalidGradeError,
  MAX_PRESENTATION_CHARS,
  MAX_WORK_CHARS,
  MIN_WORK_CHARS,
  normaliseGrade,
  normaliseWork,
  sha256,
} from "../_shared/grade_prompt.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

interface RequestBody {
  assignment_id?: unknown;
  rubric_id?: unknown;
  work?: unknown;
  presentation?: unknown;
  title?: unknown;
}

/** What a grading is called afterwards. The work itself is never stored. */
const MAX_TITLE_CHARS = 80;

function parseBody(body: RequestBody) {
  const uuid = (v: unknown): string | null => typeof v === "string" && UUID_RE.test(v) ? v : null;

  // Optional. When present it is what lets Albus find the right mark scheme
  // without asking — it carries the component and any attached rubric. When
  // absent the student is grading something loose, pasted or photographed,
  // which has no rubric to find and is marked blind unless they name one.
  const assignmentId = uuid(body.assignment_id);

  // Optional, and only an override. Absent is the normal case now.
  const rubricId = uuid(body.rubric_id);

  // Normalised before it is measured, not after: the caps should describe the
  // work as the model will see it, and OCR output can be a fifth whitespace.
  const work = typeof body.work === "string" ? normaliseWork(body.work) : "";

  // Rejected, not truncated. Silently marking the first 20,000 characters of a
  // longer essay would return a grade for work the student did not submit.
  if (work.length > MAX_WORK_CHARS) {
    throw new HttpError(
      413,
      "WORK_TOO_LONG",
      `That's longer than Albus can mark in one go (${MAX_WORK_CHARS.toLocaleString()} characters).`,
    );
  }
  if (work.length < MIN_WORK_CHARS) {
    throw new HttpError(422, "WORK_TOO_SHORT", "There isn't enough here to mark yet.");
  }

  // Truncated rather than rejected, unlike the work. A preference that runs
  // long is someone typing a paragraph about how they like their feedback, not
  // a submission that would be silently half-marked — there is nothing lost by
  // taking the first 400 characters of it.
  const presentation = typeof body.presentation === "string"
    ? body.presentation.trim().slice(0, MAX_PRESENTATION_CHARS)
    : null;

  // What the student was marking, in their words — a filename, "Photo of your
  // work", or nothing. Only ever used to label their own history row and, once
  // fenced, to tell the model what kind of thing it is looking at.
  const title = typeof body.title === "string"
    ? body.title.replace(/\s+/g, " ").trim().slice(0, MAX_TITLE_CHARS)
    : "";

  return { assignmentId, rubricId, work, presentation, title };
}

Deno.serve(async (req) => {
  // Hoisted so the `catch` can attribute a refusal. A denial that cannot
  // be attributed is a denial the risk model cannot count.
  let callerId: string | null = null;
  let signals: Signals = { deviceHash: null, ipPrefixHash: null };
  try {
    if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");

    const caller = await requireUser(req);
    callerId = caller.id;
    await assertAPIRequestRate(caller.id, "grade");
    // Hashed here and only here. What reaches Postgres is two digests.
    signals = await recordSignals(req, caller.id);

    const body = await readJsonBody<RequestBody>(req, 131_072);
    const input = parseBody(body);

    // Bind an optional assignment to the verified caller before doing any
    // rubric work, cache lookup, quota reservation, or provider call. The
    // final grading write uses the service role, so RLS at the lookup is not
    // enough by itself: a missing/foreign id must become a hard stop here.
    let assignment: { title: string; task_type: string } | null = null;
    if (input.assignmentId) {
      const { data, error } = await caller.db
        .from("assignments")
        .select("title, task_type")
        .eq("id", input.assignmentId)
        .maybeSingle();
      if (error) {
        console.error("assignment ownership lookup failed");
        throw new HttpError(500, "INTERNAL_ERROR");
      }
      if (!data) {
        // Unknown and foreign ids deliberately look identical.
        throw new HttpError(404, "ASSIGNMENT_NOT_FOUND", "That assignment is unavailable.");
      }
      assignment = data as { title: string; task_type: string };
    }

    // What are we marking against?
    //
    // An explicit rubric_id is an override and still wins; otherwise Albus
    // works it out from the assignment. Either way the read goes through the
    // caller's own client, so RLS is what makes a foreign id resolve to
    // nothing rather than to someone else's criteria.
    //
    // **No rubric is a supported outcome, not a failure.** It used to 404 here,
    // which is why a student without a saved rubric could never grade anything
    // at all. Now it grades blind and says so — the honesty is the feature.
    let rubric = null;
    let basis: GradeBasis = "blind";

    if (input.rubricId) {
      rubric = await loadPersonalRubric(caller.db, input.rubricId);
      if (!rubric) {
        throw new HttpError(
          404,
          "RUBRIC_NOT_FOUND",
          "That rubric isn't available. Try saving it again.",
        );
      }
      basis = "personal";
    } else if (input.assignmentId) {
      const resolved = await resolveGradingRubric(caller.db, input.assignmentId);
      rubric = resolved.rubric;
      basis = resolved.basis;
    }

    // What this piece is called.
    //
    // An assignment's own title wins — it is the one the student will recognise
    // in their history — and what they typed is the fallback for loose work
    // that belongs to no assignment.
    let title = input.title || "Your work";
    let taskType = "other";
    if (assignment) {
      title = assignment.title || title;
      taskType = assignment.task_type ?? taskType;
    }

    // Have we already produced exactly this answer?
    //
    // Before the quota call on purpose: no model call happens, so no grading
    // should be spent. A student who taps Grade twice, re-grades without
    // editing, or retries after a dropped connection gets the same marks back
    // for nothing — which is both the honest outcome and the largest saving
    // available on this endpoint.
    //
    // The hash covers what it was marked against as well as the work, so the
    // same essay against a different rubric is a different answer.
    const workHash = await sha256([
      input.work,
      basis,
      // In the hash because it is in the prompt: the same paragraphs submitted
      // as "Lab report" and as "Personal statement" are two different questions
      // and must not share one answer.
      title,
      taskType,
      rubric?.name ?? "",
      (rubric?.criteria ?? []).map((c) => `${c.code}:${c.name}:${c.marks}`).join("|"),
      input.presentation ?? "",
    ].join("\u0000"));

    const { data: existing } = await caller.db
      .from("gradings")
      // deno-fmt-ignore — one string literal on purpose: supabase-js infers the
      // row type from the literal, and splitting it widens to `string`, which
      // types every field of the result as an error.
      .select(
        "id, created_at, overall_marks, total_marks, grade_label, grade_note, work_title, breakdown, feedback, improvements, model, basis",
      )
      // RLS already scopes this; the explicit filter is here so a hash
      // collision cannot hand one student another student's marks even if RLS
      // were ever loosened.
      .eq("user_id", caller.id)
      .eq("work_hash", workHash)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (existing) {
      return jsonResponse({
        id: existing.id,
        created_at: existing.created_at,
        overall_marks: existing.overall_marks,
        total_marks: existing.total_marks,
        grade_label: existing.grade_label,
        grade_note: existing.grade_note,
        title: existing.work_title,
        criteria: existing.breakdown,
        feedback: existing.feedback,
        improvements: existing.improvements,
        model: existing.model,
        basis: existing.basis,
        rubric_name: rubric?.name ?? null,
        // So the client can say "you already marked this" rather than silently
        // showing a result with a stale timestamp.
        reused: true,
      }, 200);
    }

    // Which model marks is decided by what we found above, so the usage row
    // records the model actually billed rather than a constant.
    const model = gradeModelFor(basis);

    // Entitlement, rate limit and the usage slot, atomically. Everything below
    // this line costs money, and nothing above it does.
    const usageId = await reserveAIUsage(caller.id, "grade", model);

    // Everything from here can fail *after* a grading has been reserved, and a
    // student who gets no marks must not lose one of five for the week. The
    // slot is handed back on any failure below. The attempt itself is retained:
    // it may have reached Anthropic, so deleting it would let a scripted client
    // repeat expensive failures without hitting rate or project-cost limits.
    let generated: Awaited<ReturnType<typeof gradeWork>> | null = null;
    const refund = async (error: unknown) => {
      const usage = generated ?? providerUsage(error);
      await finalizeAIUsage(
        usageId,
        "failed",
        usage?.inputTokens ?? null,
        usage?.outputTokens ?? null,
        usageFailureCode(error),
        usage?.cacheWriteTokens ?? null,
        usage?.cacheReadTokens ?? null,
      );
    };

    try {
      generated = await gradeWork(
        buildGradeSystemPrompt(basis),
        buildGradeUserPrompt({
          taskTitle: title,
          taskType,
          rubric,
          work: input.work,
          presentation: input.presentation,
        }),
        model,
      );
    } catch (e) {
      await refund(e);
      throw e;
    }

    let grade;
    try {
      grade = normaliseGrade(generated.raw, rubric);
    } catch (e) {
      await refund(e);
      if (e instanceof InvalidGradeError) {
        console.error("model produced an unusable grade:", e.message);
        throw new HttpError(
          502,
          "MALFORMED_RESPONSE",
          "Marking failed, and your grading has been given back.",
        );
      }
      throw e;
    }

    // Written with the service role because `authenticated` deliberately has no
    // INSERT on this table: a student who could write their own grading row
    // could award themselves full marks, and could fabricate the record the
    // paywall exists to sell. user_id comes from the verified JWT, never the
    // body, so the row cannot be attributed to anyone else.
    // Serialised explicitly rather than by spreading the internal shape.
    //
    // `normaliseGrade` returns camelCase because it is TypeScript; every other
    // response this API sends is snake_case. Leaking `outOf` into the payload
    // meant the iOS client decoded `out_of` as nil and lost every per-criterion
    // denominator — a bug that type-checked on both sides and only showed up
    // against the live endpoint.
    const criteriaPayload = grade.criteria.map((c) => ({
      code: c.code,
      name: c.name,
      marks: c.marks,
      out_of: c.outOf,
      comment: c.comment,
      quote: c.quote,
      where: c.where,
    }));

    const { data: saved, error: writeError } = await adminClient()
      .from("gradings")
      .insert({
        user_id: caller.id,
        assignment_id: input.assignmentId,
        rubric_id: basis === "personal" ? input.rubricId : null,
        model: generated.model,
        input_chars: input.work.length,
        overall_marks: grade.overallMarks,
        total_marks: grade.totalMarks,
        grade_label: grade.gradeLabel,
        grade_note: grade.gradeNote,
        work_title: title,
        // Which reservation paid for this. It is what lets the quota count ask
        // "was anything actually bought" instead of "is there a row", so a
        // reservation the runtime killed before the refund could run stops
        // counting against the student instead of costing them one forever.
        usage_id: usageId ?? null,
        breakdown: criteriaPayload,
        feedback: grade.feedback,
        improvements: grade.improvements,
        work_hash: workHash,
        // Stored, not inferred. A blind reading and a rubric grading that
        // awarded no marks are identical on the wire — both nulls — so without
        // this a saved blind reading could later be rendered as a grade.
        basis,
      })
      .select("id, created_at")
      .single();
    if (writeError) {
      const mapped = mapPostgresError(writeError.message);
      await refund(mapped);
      throw mapped;
    }

    await finalizeAIUsage(
      usageId,
      "completed",
      generated.inputTokens,
      generated.outputTokens,
      null,
      generated.cacheWriteTokens,
      generated.cacheReadTokens,
    );

    return jsonResponse({
      id: saved.id,
      created_at: saved.created_at,
      overall_marks: grade.overallMarks,
      total_marks: grade.totalMarks,
      grade_label: grade.gradeLabel,
      grade_note: grade.gradeNote,
      title,
      criteria: criteriaPayload,
      feedback: grade.feedback,
      improvements: grade.improvements,
      model: generated.model,
      // The client must never infer this from whether marks came back. A
      // A rubric with no marks and a blind reading both return nulls,
      // and only one of them is allowed to call itself a grade.
      basis,
      rubric_name: rubric?.name ?? null,
      reused: false,
    }, 201);
  } catch (e) {
    noteRefusal(e, callerId, "grade", signals);
    return errorResponse(e);
  }
});
