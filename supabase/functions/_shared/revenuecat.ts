// Pure RevenueCat webhook primitives. No server, environment, or database, so
// signature and replay-window behaviour can be tested without live secrets.

/** Constant-time comparison over a fixed maximum length. */
export function constantTimeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

/** Milliseconds since epoch to ISO, rejecting values that could become no expiry. */
export function isoFromMilliseconds(value: unknown): string | null {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

/** Translate RevenueCat's exact public enum; anything else fails closed. */
export function normaliseRevenueCatEnvironment(
  value: unknown,
): "Production" | "Sandbox" | null {
  if (typeof value !== "string") return null;
  switch (value.toUpperCase()) {
    case "PRODUCTION":
      return "Production";
    case "SANDBOX":
      return "Sandbox";
    default:
      return null;
  }
}

/**
 * Only EXPIRATION means access has ended immediately.
 *
 * RevenueCat's SUBSCRIPTION_PAUSED event schedules a pause at the end of the
 * current paid period. Revoking on that event takes away time the student has
 * already paid for; the later EXPIRATION event is the revocation signal.
 */
export function revokesImmediately(eventType: string): boolean {
  return eventType === "EXPIRATION";
}

/**
 * A webhook integration can cover several apps; only Albus app ids may grant.
 *
 * `allowMissing` is for TRANSFER, which RevenueCat can send without an app id
 * because it moves a customer rather than a store purchase. An app id that is
 * present must still be one of ours.
 */
export function revenueCatAppIsAllowed(
  appId: unknown,
  configuredIds: string,
  { allowMissing = false }: { allowMissing?: boolean } = {},
): boolean {
  const allowed = configuredIds.split(",").map((id) => id.trim()).filter(Boolean);
  if (allowed.length === 0) return false;
  if (appId === undefined || appId === null) return allowMissing;
  return typeof appId === "string" && allowed.includes(appId);
}

/**
 * Only purchases Apple processed can change a plan.
 *
 * RevenueCat's Test Store makes purchases that look real and cost nothing, and
 * promotional grants have no store transaction at all. Anything that is not
 * the App Store fails closed, including an event that names no store.
 */
export function storeCanGrant(store: unknown): boolean {
  return store === "APP_STORE" || store === "MAC_APP_STORE";
}

const USER_ID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** A Supabase user id. The app tells RevenueCat to use it as the App User ID. */
export function isUserID(value: unknown): value is string {
  return typeof value === "string" && USER_ID_RE.test(value);
}

/**
 * The Albus accounts named in a TRANSFER id list. RevenueCat also lists its
 * own anonymous ids (`$RCAnonymousID:...`), which belong to nobody here.
 */
export function userIDsIn(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return [...new Set(value.filter(isUserID).map((id) => id.toLowerCase()))];
}

/** A finite number RevenueCat sent, or null. */
export function finiteOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

/** Verify `t=<unix>,v1=<hex>` over the exact raw JSON bytes. */
export async function verifyRevenueCatSignature(
  raw: Uint8Array,
  header: string,
  secret: string,
  nowMs: number = Date.now(),
  toleranceSeconds = 300,
): Promise<boolean> {
  if (!secret) return false;
  const timestamp = /(?:^|,)\s*t=(\d+)/.exec(header)?.[1] ?? "";
  const provided = /(?:^|,)\s*v1=([0-9a-f]{64})/i.exec(header)?.[1]?.toLowerCase() ?? "";
  const unix = Number(timestamp);
  if (
    !Number.isSafeInteger(unix) ||
    Math.abs(nowMs / 1000 - unix) > toleranceSeconds
  ) return false;

  const prefix = new TextEncoder().encode(`${timestamp}.`);
  const signed = new Uint8Array(prefix.length + raw.length);
  signed.set(prefix);
  signed.set(raw, prefix.length);

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, signed));
  const expected = [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
  return constantTimeEqual(provided, expected);
}

/** How the webhook should answer one `apply_subscription_state` outcome. */
export interface SubscriptionOutcome {
  /**
   * Ask RevenueCat to redeliver. Reserve this for states a later attempt can
   * actually resolve — a malformed payload retried is still malformed, and a
   * permanent 5xx would only bury the useful signal in noise.
   */
  retry: boolean;
  /** What an operator should see. `none` is the ordinary path. */
  severity: "none" | "warn" | "error";
}

/**
 * Classify what the database decided, so the transport does not have to.
 *
 * **The case this exists for is `unknown_product`.** It means the purchase was
 * real, the signature verified, and no `subscription_products` row mapped the
 * identifier to a tier — so nothing was granted while Apple had already taken
 * the money. It used to return 200 with no log, which told RevenueCat the event
 * was handled and left no trace anywhere a human would look.
 *
 * It is retryable on purpose: the fix is a row in a table, and once that row
 * exists RevenueCat's own backoff redelivers the purchase and grants it without
 * anyone replaying anything by hand.
 */
export function classifySubscriptionResult(result: string | null): SubscriptionOutcome {
  switch (result) {
    // Paid, verified, and granted nothing. Recoverable by seeding the mapping.
    case "unknown_product":
      return { retry: true, severity: "error" };
    // This subscription already belongs to another account. Not recoverable by
    // retrying — a person has to look at it.
    case "conflict":
    // Bad identity or an environment we do not accept. The payload will not
    // improve on redelivery.
    case "invalid":
      return { retry: false, severity: "error" };
    // Legitimately transient: RevenueCat can deliver a purchase before it has
    // identified the buyer, and a later event links it.
    case "unlinked":
      return { retry: false, severity: "warn" };
    // `stale` is duplicate or out-of-order delivery, which the idempotency
    // guard is supposed to absorb; `sandbox_ignored` is the configured
    // behaviour. Both are working as intended.
    default:
      return { retry: false, severity: "none" };
  }
}
