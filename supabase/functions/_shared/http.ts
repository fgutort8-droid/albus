// _shared/http.ts — transport concerns only. No business logic.

export class HttpError extends Error {
  constructor(public status: number, public code: string, message?: string) {
    super(message ?? code);
  }
}

/** The iOS app is a native client, so no browser origin needs allowing. */
const BASE_HEADERS = { "Content-Type": "application/json" } as const;

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: BASE_HEADERS });
}

export function errorResponse(e: unknown): Response {
  if (e instanceof HttpError) {
    return jsonResponse({ error: e.code, message: e.message }, e.status);
  }
  // Keep arbitrary error details out of both client responses and logs.
  console.error("unhandled application error");
  return jsonResponse({ error: "INTERNAL_ERROR" }, 500);
}

/**
 * Postgres errors surface as opaque strings. Map the ones the RPC raises
 * deliberately onto real HTTP codes; treat anything else as internal.
 */
export function mapPostgresError(message: string): HttpError {
  // ── Order matters ─────────────────────────────────────────────────────────
  //
  // Two families of refusal live here and they must never be confused:
  //
  //   402 PLAN_*     the plan does not include this. The answer is a price.
  //   402 ALLOWANCE_*  the plan includes it and this window is used up. The
  //                    answer is a date, and the meter already knows which one.
  //   429 RATE_LIMIT_* going too fast. The answer is "in a minute".
  //
  // Collapsing the first two is how a paying student gets shown a paywall for
  // something they already bought.

  // ── Not on this plan ──────────────────────────────────────────────────────
  if (message.includes("PLAN_UPGRADE_REQUIRED")) {
    return new HttpError(
      402,
      "PLAN_UPGRADE_REQUIRED",
      "That's part of a paid plan.",
    );
  }
  if (message.includes("PLAN_TASK_LIMIT_REACHED") || message.includes("FREE_PLAN_LIMIT_REACHED")) {
    return new HttpError(
      402,
      "PLAN_TASK_LIMIT_REACHED",
      "That's as many tasks as your plan keeps open at once. Finish one, or upgrade.",
    );
  }
  if (message.includes("RUBRIC_PLAN_LIMIT")) {
    return new HttpError(
      402,
      "RUBRIC_PLAN_LIMIT",
      "That's as many rubrics as your plan saves. Upgrade, or delete one you've finished with.",
    );
  }

  // ── Bought, and used up ───────────────────────────────────────────────────
  //
  // 402 rather than 429 for both: a student who has used the week's markings is
  // not being rate-limited for misbehaving, they have reached the end of what
  // they bought — which the app renders as a plan screen, not as an error.
  if (message.includes("ALLOWANCE_WEEKLY") || message.includes("RATE_LIMIT_WEEKLY")) {
    return new HttpError(
      402,
      "ALLOWANCE_WEEKLY",
      "That's this week's markings used.",
    );
  }
  if (message.includes("ALLOWANCE_MONTHLY")) {
    return new HttpError(
      402,
      "ALLOWANCE_MONTHLY",
      "That's this month's messages used.",
    );
  }
  if (message.includes("FAIR_USE_REACHED")) {
    return new HttpError(
      402,
      "FAIR_USE_REACHED",
      "This account has reached its monthly AI safety limit. Capacity returns gradually over 30 days.",
    );
  }

  // ── Going too fast ────────────────────────────────────────────────────────
  if (message.includes("RATE_LIMIT_HOURLY")) {
    return new HttpError(
      429,
      "RATE_LIMIT_HOURLY",
      "Too many requests in the last hour. Try again shortly.",
    );
  }
  if (message.includes("RATE_LIMIT_DAILY")) {
    return new HttpError(
      429,
      "RATE_LIMIT_DAILY",
      "You have reached today's limit. It resets tomorrow.",
    );
  }
  if (message.includes("API_RATE_LIMIT")) {
    return new HttpError(
      429,
      "RATE_LIMIT_HOURLY",
      "Too many requests. Wait a moment and try again.",
    );
  }

  // ── Risk ──────────────────────────────────────────────────────────────────
  //
  // Deliberately vague to the client, and deliberately specific in the log.
  // Telling somebody which signal tripped is telling them which one to change,
  // and the people most likely to read the detail closely are the ones it is
  // there to stop. A genuine student sees a way forward — sign in properly —
  // rather than a number they cannot argue with.
  if (message.includes("VERIFICATION_REQUIRED")) {
    return new HttpError(
      403,
      "VERIFICATION_REQUIRED",
      "Sign in to carry on. It takes a moment and it's a one-off.",
    );
  }
  if (message.includes("ABUSE_SUSPECTED")) {
    return new HttpError(
      403,
      "ABUSE_SUSPECTED",
      "Albus has paused AI features on this account. They come back on their own.",
    );
  }

  // ── Ownership and shape ───────────────────────────────────────────────────
  if (
    message.includes("RUBRIC_NOT_YOURS") ||
    message.includes("rubric does not belong to this user")
  ) {
    return new HttpError(403, "RUBRIC_NOT_YOURS", "That rubric isn't yours.");
  }
  if (message.includes("TOO_MANY_CRITERIA")) {
    return new HttpError(422, "TOO_MANY_CRITERIA", "That's more criteria than a rubric can hold.");
  }
  if (message.includes("COURSE_NOT_YOURS") || message.includes("ASSIGNMENT_NOT_YOURS")) {
    return new HttpError(403, "NOT_YOURS", "That item isn't yours.");
  }
  if (message.includes("ASSIGNMENT_REQUIRED")) {
    return new HttpError(422, "ASSIGNMENT_REQUIRED", "Open an assignment first.");
  }
  if (message.includes("ASSIGNMENT_NOT_FOUND")) {
    return new HttpError(404, "ASSIGNMENT_NOT_FOUND", "That assignment is unavailable.");
  }
  if (message.includes("RUBRIC_NAME_REQUIRED") || message.includes("RUBRIC_ID_REQUIRED")) {
    return new HttpError(422, "INVALID_RUBRIC", "That rubric is missing a name.");
  }
  if (
    message.includes("RUBRIC_CEILING") ||
    message.includes("COURSE_CEILING") ||
    message.includes("ASSIGNMENT_CEILING") ||
    message.includes("rubric limit reached") ||
    message.includes("rubric criterion limit reached")
  ) {
    return new HttpError(422, "STORAGE_LIMIT", "That's more than Albus can safely hold.");
  }
  if (message.includes("NOT_AUTHENTICATED")) {
    return new HttpError(401, "NOT_AUTHENTICATED");
  }
  if (message.includes("SUBTASKS_REQUIRED") || message.includes("TOO_MANY_SUBTASKS")) {
    return new HttpError(422, "INVALID_PLAN");
  }

  // ── Ours, not theirs ──────────────────────────────────────────────────────
  //
  // The global spend fuse (migration 0013). Without this case it fell through
  // to the branch below and reached the client as a 500, so the app could not
  // tell "we are at capacity, retry later" from "we are broken".
  if (
    message.includes("GLOBAL_CAPACITY_REACHED") ||
    message.includes("AI_EMERGENCY_STOP")
  ) {
    return new HttpError(
      503,
      "GLOBAL_CAPACITY_REACHED",
      "Albus is at capacity right now. Try again shortly.",
    );
  }
  // A tier with no plan row. Unreachable through the foreign key on
  // entitlements, and mapped anyway: "should be unreachable" is how the NULL
  // bug in migration 0009 got in.
  if (message.includes("PLAN_UNKNOWN")) {
    console.error("entitlement names a tier with no plan row");
    return new HttpError(500, "INTERNAL_ERROR");
  }
  if (message.includes("AI_BUDGET_UNKNOWN")) {
    console.error("entitlement has no AI financial-safety budget");
    return new HttpError(503, "GLOBAL_CAPACITY_REACHED", "Albus is at capacity right now.");
  }

  // Unmapped backend text may contain submitted content. Log only the category.
  console.error("unmapped postgres error");
  return new HttpError(500, "INTERNAL_ERROR");
}
