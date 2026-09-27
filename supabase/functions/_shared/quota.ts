// _shared/quota.ts
//
// The free tier caps ACTIVE plans, not plans per month — a student in exam
// season must never hit a wall mid-week. Finishing an assignment frees a slot.
//
// This is the *pre-flight* check and it is an optimisation, not a control: it
// exists so we never pay Anthropic for a generation we are about to reject.
// The enforcement is a trigger on `public.assignments` (migration 0036), which
// holds whatever path the write arrives by — including the one that skips this
// file entirely by POSTing straight to the table, which is how the cap was
// bypassed before that trigger existed.

import { adminClient, type Caller } from "./auth.ts";
import { HttpError, mapPostgresError } from "./http.ts";

/**
 * Refuse early if the student is already holding as many open tasks as their
 * plan allows.
 *
 * The limit is read from `public.plans` rather than written here. Three tiers
 * with five limits each is fifteen numbers, and a copy of any of them in this
 * file is a number that will eventually disagree with the one the database
 * enforces — which is the bug migration 0033 had to fix on the meter.
 */
export async function assertCanGeneratePlan(caller: Caller): Promise<void> {
  const admin = adminClient();

  const { data: tier, error: tierError } = await admin
    .rpc("effective_tier", { p_uid: caller.id });

  // Fail open on an infrastructure error: the trigger still enforces the cap,
  // so the worst case is a wasted generation, not a bypassed limit.
  if (tierError) {
    console.warn("quota pre-check could not resolve tier");
    return;
  }

  const { data: plan } = await admin
    .from("plans")
    .select("active_tasks")
    .eq("tier", (tier as string) ?? "free")
    .maybeSingle();

  const limit = plan?.active_tasks as number | null | undefined;
  // null is unlimited; undefined means the lookup failed and the trigger has it.
  if (limit === null || limit === undefined) return;

  const { count, error } = await admin
    .from("assignments")
    .select("id", { count: "exact", head: true })
    .eq("user_id", caller.id)
    .eq("status", "active");

  if (error) {
    console.warn("quota pre-check failed, deferring to the trigger");
    return;
  }

  if ((count ?? 0) >= limit) {
    throw new HttpError(
      402,
      "PLAN_TASK_LIMIT_REACHED",
      "That's as many tasks as your plan keeps open at once. Finish one, or upgrade.",
    );
  }
}

export type AIKind = "breakdown" | "chat" | "grade";
export type AIUsageState = "completed" | "failed";

/**
 * Bound all authenticated traffic before parsing or telemetry writes.
 *
 * AI-specific limits are intentionally much tighter, but they happen after a
 * request has proved it is eligible. Without this outer gate a free account
 * could call a paid endpoint forever, be refused before reserving AI usage,
 * and still create auth, database and security-log work on every request.
 */
export async function assertAPIRequestRate(userId: string, endpoint: AIKind): Promise<void> {
  const { error } = await adminClient().rpc("check_api_request_rate", {
    p_user_id: userId,
    p_endpoint: endpoint,
  });
  if (error) throw mapPostgresError(error.message);
}

/**
 * Reserve with the service client, never the caller-scoped client.
 *
 * The old RPC had to be executable by `authenticated` because it recovered the
 * user from `auth.uid()`. That meant a modified client could call the metering
 * API directly and fill the project-wide fuse without ever touching a model.
 * The replacement accepts only the id we got from a verified JWT and is granted
 * only to `service_role`.
 */
export async function reserveAIUsage(
  userId: string,
  kind: AIKind,
  model: string,
): Promise<string> {
  const { data, error } = await adminClient().rpc("check_and_record_ai_usage", {
    p_user_id: userId,
    p_kind: kind,
    p_model: model,
  });
  if (error) throw mapPostgresError(error.message);
  if (typeof data !== "string" || data.length === 0) {
    throw new HttpError(500, "USAGE_RESERVATION_FAILED");
  }
  return data;
}

/**
 * Finish one reservation exactly once.
 *
 * Failed work remains in the attempt ledger because it may have reached the
 * provider and must continue to count against rate and monetary limits. The
 * database excludes it from the student's purchased allowance. Accounting is
 * awaited instead of detached: Edge isolates may be torn down immediately
 * after a response, and a cost ledger that only usually writes is not a ledger.
 *
 * Failure is soft for the product response. The original reservation already
 * carries a conservative cost and remains rate-limited even if this write has
 * an infrastructure failure, so financial protection fails closed.
 */
export async function finalizeAIUsage(
  usageId: string,
  state: AIUsageState,
  inputTokens: number | null = null,
  outputTokens: number | null = null,
  failureCode: string | null = null,
  // Anthropic reports cached tokens in separate fields that `input_tokens`
  // excludes, and bills for both — a cache write at 1.25x the input rate, a
  // read at 0.10x. Omitting them did not make them free; it made them
  // invisible to the ledger the monthly ceiling is computed from.
  cacheWriteTokens: number | null = null,
  cacheReadTokens: number | null = null,
): Promise<boolean> {
  // A transient database/network edge after a paid provider response should
  // not leave the ledger reserved merely because one write was unlucky. Keep
  // retries bounded and synchronous; the database transition itself is
  // one-way, so a retry cannot double-charge or rewrite a terminal outcome.
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const { data, error } = await adminClient().rpc("finalize_ai_usage", {
        p_usage_id: usageId,
        p_state: state,
        p_input_tokens: inputTokens,
        p_output_tokens: outputTokens,
        p_failure_code: failureCode,
        p_cache_write_tokens: cacheWriteTokens,
        p_cache_read_tokens: cacheReadTokens,
      });
      if (!error) {
        if (data !== true) {
          console.error("AI usage finalisation changed no reservation", { state });
        }
        return data === true;
      }
    } catch {
      // Retry without retaining arbitrary backend or transport details.
    }
  }
  console.error("AI usage finalisation failed after three attempts");
  return false;
}

/** Only a short machine code reaches the ledger; never a prompt or provider message. */
export function usageFailureCode(error: unknown): string {
  const raw = (error as { code?: unknown })?.code;
  return typeof raw === "string" && /^[A-Z0-9_]{1,64}$/.test(raw) ? raw : "UNKNOWN";
}
