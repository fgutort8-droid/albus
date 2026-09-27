// _shared/signals.ts
//
// The abuse-detection layer's eyes, and the only place raw identifiers exist.
//
// ── What leaves this file ───────────────────────────────────────────────────
//
// Two SHA-256 HMACs and nothing else. The IP address and the device identifier
// are read from the request, hashed here, and dropped. Postgres never receives
// either one — not in a column, not in a query log, not in a backup — so the
// correlation the risk model needs exists without the data it would normally
// need to keep.
//
// ── Which device identifier, and why that one ───────────────────────────────
//
// iOS `identifierForVendor`. It is per-vendor rather than per-device, it resets
// when the user deletes every app of ours, and it is not a hardware serial. It
// is the *weakest* identifier that can answer "has this device made five
// accounts this afternoon", which is the correct one to choose. The client is
// free to withhold it and everything still works — the signal is simply absent,
// and an absent signal cannot escalate anything on its own (see 0035).
//
// ── Which part of the IP ────────────────────────────────────────────────────
//
// A prefix, never the address: /24 for IPv4 and /48 for IPv6. Two reasons, and
// the second is the important one. It is less identifying — a /24 is up to 254
// households — and it is the right granularity for the question, because
// consumer addresses rotate and mobile carriers hand the same address to
// thousands of people. Scoring the full address would produce a signal that is
// simultaneously more invasive and less useful.

import { adminClient } from "./auth.ts";

export interface Signals {
  deviceHash: string | null;
  ipPrefixHash: string | null;
}

/**
 * The pepper that makes these hashes un-reversible without our secrets.
 *
 * Prefer an explicitly configured `ALBUS_SIGNAL_PEPPER`: rotating it retires
 * the whole correlation set in one move, which is a real privacy control and
 * worth having a dedicated knob for.
 *
 * With none set, derive one from the service key rather than doing nothing. A
 * derived pepper still lives only in function secrets, so the property that
 * matters — Postgres cannot reverse what it stores — holds either way. Hashing
 * with a constant, or skipping the feature until somebody remembers to set a
 * secret, would both be worse.
 */
let cachedPepper: Promise<CryptoKey> | null = null;

function pepperKey(): Promise<CryptoKey> {
  if (cachedPepper) return cachedPepper;
  cachedPepper = (async () => {
    // Guarded. `Deno.env.get` *throws* without `--allow-env` rather than
    // returning undefined, and an abuse-telemetry helper must never be the
    // thing that raises out of a student's request. Without permission there is
    // no pepper, and no pepper means no signal — `recordSignals` catches this
    // and records nothing, which is the correct degradation. Falling back to a
    // constant would be worse than useless: it would produce hashes anyone
    // knowing the constant could reverse.
    const env = (name: string): string | undefined => {
      try {
        return Deno.env.get(name);
      } catch {
        return undefined;
      }
    };
    const explicit = env("ALBUS_SIGNAL_PEPPER");
    const fallback = env("ALBUS_SUPABASE_SECRET_KEY") ??
      env("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    if (!explicit && !fallback) {
      throw new Error("no pepper material available; refusing to hash unpeppered");
    }
    const material = explicit ?? `albus-signal-pepper|${fallback}`;
    return await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(material),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
  })();
  return cachedPepper;
}

export async function peppered(value: string): Promise<string> {
  const key = await pepperKey();
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * The network prefix, as text, or null if there is nothing usable.
 *
 * `x-forwarded-for` is a list and only the entries our own edge appended are
 * trustworthy — a client can send whatever it likes in that header. The *first*
 * entry is conventionally the origin client and is therefore the spoofable one;
 * the **last** is the one the closest proxy observed. Taking the last means a
 * forged header changes nothing, which is the whole point of reading it at all.
 */
export function ipPrefix(req: Request): string | null {
  const raw = req.headers.get("x-forwarded-for");
  if (!raw) return null;
  const parts = raw.split(",").map((s) => s.trim()).filter(Boolean);
  const addr = parts.at(-1);
  if (!addr) return null;

  if (addr.includes(":")) {
    // IPv6 → /48. Three hextets is a site, which is the household equivalent.
    const hextets = addr.split(":").slice(0, 3);
    return hextets.length === 3 ? `v6:${hextets.join(":")}` : null;
  }
  const octets = addr.split(".");
  if (
    octets.length !== 4 ||
    octets.some((o) => !/^\d{1,3}$/.test(o) || Number(o) > 255)
  ) return null;
  return `v4:${octets.slice(0, 3).join(".")}`;
}

/** The device identifier the client chose to send. Bounded and shape-checked. */
export function deviceId(req: Request): string | null {
  const raw = req.headers.get("x-albus-device");
  if (!raw) return null;
  const trimmed = raw.trim();
  // An IDFV is a UUID. Anything else is a client bug or someone probing, and
  // either way it is not worth hashing — an unbounded header must never become
  // an unbounded write.
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
      .test(trimmed)
    ? trimmed.toLowerCase()
    : null;
}

/**
 * Hash what this request reveals, and record it against the caller.
 *
 * Fire-and-forget by design. This is telemetry for an abuse control: a student
 * whose essay fails to be marked because a signal write timed out has been
 * failed by a feature that exists to protect them.
 */
export async function recordSignals(req: Request, userId: string): Promise<Signals> {
  let deviceHash: string | null = null;
  let ipPrefixHash: string | null = null;

  try {
    const device = deviceId(req);
    const prefix = ipPrefix(req);
    if (device) deviceHash = await peppered(`device|${device}`);
    if (prefix) ipPrefixHash = await peppered(`ip|${prefix}`);

    if (deviceHash || ipPrefixHash) {
      const admin = adminClient();
      // PromiseLike, not Promise: a PostgREST builder is thenable but is not
      // a Promise, and `Promise.all` is happy with either.
      const writes: PromiseLike<unknown>[] = [];
      if (deviceHash) {
        writes.push(admin.rpc("record_identity_link", {
          p_user_id: userId,
          p_kind: "device",
          p_hash: deviceHash,
        }));
      }
      if (ipPrefixHash) {
        writes.push(admin.rpc("record_identity_link", {
          p_user_id: userId,
          p_kind: "ip_prefix",
          p_hash: ipPrefixHash,
        }));
      }
      await Promise.all(writes);
    }
  } catch {
    console.warn("signal recording failed");
  }

  return { deviceHash, ipPrefixHash };
}

/**
 * Record that something was refused.
 *
 * This lives here rather than in the gate because a raised exception rolls back
 * its own transaction — a log line written next to a `raise` in Postgres is
 * discarded along with it, so the denial would vanish exactly when it mattered.
 * A separate request from here survives.
 *
 * `detail` carries the error code and the endpoint. Never the request body,
 * never the work, never the message: this table is read to answer "is somebody
 * probing us", and nothing else in a student's request helps answer that.
 */
export function logSecurityEvent(
  userId: string | null,
  kind: string,
  severity: "info" | "warn" | "alert",
  signals: Signals,
  detail: Record<string, string | number | boolean> = {},
): void {
  const write = (async () => {
    try {
      await adminClient().rpc("log_security_event", {
        p_user_id: userId,
        p_kind: kind,
        p_severity: severity,
        p_device_hash: signals.deviceHash,
        p_ip_prefix_hash: signals.ipPrefixHash,
        p_detail: detail,
      });
    } catch {
      console.warn("security event write failed");
    }
  })();

  const runtime = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } })
    .EdgeRuntime;
  if (runtime?.waitUntil) runtime.waitUntil(write);
}

/** Which refusals are worth a row, and how loud each one is. */
const DENIAL_SEVERITY: Record<string, "info" | "warn" | "alert"> = {
  PLAN_UPGRADE_REQUIRED: "info",
  ALLOWANCE_WEEKLY: "info",
  ALLOWANCE_MONTHLY: "info",
  PLAN_TASK_LIMIT_REACHED: "info",
  RUBRIC_PLAN_LIMIT: "info",
  RATE_LIMIT_HOURLY: "warn",
  RATE_LIMIT_DAILY: "warn",
  API_RATE_LIMIT: "warn",
  GLOBAL_CAPACITY_REACHED: "alert",
  AI_EMERGENCY_STOP: "alert",
  FAIR_USE_REACHED: "warn",
  VERIFICATION_REQUIRED: "warn",
  ABUSE_SUSPECTED: "alert",
  RUBRIC_CEILING: "alert",
};

/**
 * Classify a refusal and log it.
 *
 * The kind is coarse on purpose — `entitlement.denied`, `ratelimit.hit`,
 * `risk.blocked` — because those three are what `account_risk` counts, and a
 * hundred distinct kinds would be a hundred things to remember to count.
 */
export function logDenial(
  userId: string,
  code: string,
  endpoint: string,
  signals: Signals,
): void {
  const severity = DENIAL_SEVERITY[code];
  if (!severity) return;

  const kind = code === "ABUSE_SUSPECTED" || code === "VERIFICATION_REQUIRED"
    ? "risk.blocked"
    : code.startsWith("RATE_LIMIT") || code === "GLOBAL_CAPACITY_REACHED" ||
        code === "AI_EMERGENCY_STOP"
    ? "ratelimit.hit"
    : "entitlement.denied";

  logSecurityEvent(userId, kind, severity, signals, { code, endpoint });
}

/**
 * Log a refusal on the way out of a handler.
 *
 * Called from the `catch` rather than at each `throw` so no future refusal can
 * be added without being logged — there is one exit and it goes through here.
 * Silent for anything that is not a refusal we classify: a malformed JSON body
 * is a bug in somebody's client, not an attack, and a log full of those is a
 * log nobody reads.
 */
export function noteRefusal(
  e: unknown,
  userId: string | null,
  endpoint: string,
  signals: Signals,
): void {
  if (!userId) return;
  const code = (e as { code?: unknown })?.code;
  if (typeof code === "string") logDenial(userId, code, endpoint, signals);
}
