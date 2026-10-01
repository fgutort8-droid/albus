import { adminClient } from "./auth.ts";
import { HttpError } from "./http.ts";

/** Authenticated, allowlisted inputs only; NEVER the original webhook body. */
export async function persistFinancialEvent(
  configuredApps: string,
  eventID: string,
  payload: Record<string, unknown>,
): Promise<string> {
  const scope = [...new Set(configuredApps.split(",").map((id) => id.trim()).filter(Boolean))]
    .sort().join(",");
  const db = adminClient();
  const { data: id, error: acceptanceError } = await db.rpc("enqueue_revenuecat_event", {
    p_scope: scope,
    p_event_id: eventID,
    p_payload: payload,
  });
  if (acceptanceError || typeof id !== "string") {
    console.error("financial event acceptance failed");
    throw new HttpError(503, "FINANCIAL_ACCEPTANCE_FAILED");
  }
  // Separate transaction: a crash here leaves a pending, replayable event.
  const { data: result, error } = await db.rpc("process_financial_event", { p_id: id });
  if (error || typeof result !== "string") {
    console.error("durable financial event requires recovery");
    throw new HttpError(503, "FINANCIAL_PROCESSING_FAILED");
  }
  if (result === "retry" || result === "dead") {
    throw new HttpError(503, "FINANCIAL_EVENT_PENDING");
  }
  return result;
}
