// _shared/auth.ts
//
// One rule, enforced here so no function can forget it:
//   the caller's identity comes from their verified JWT, never from the body.
//
// A request that says {"user_id": "..."} is making a claim, not a statement.
// requireUser() ignores the body entirely and resolves the user from the
// Authorization header, which Supabase Auth has already signed.

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2.112.3";
import { HttpError } from "./http.ts";

export interface Caller {
  id: string;
  isAnonymous: boolean;
  /** Scoped to the caller — RLS applies. Use for anything user-owned. */
  db: SupabaseClient;
}

function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (v) return v;
  throw new HttpError(500, "MISCONFIGURED", `${name} is not set`);
}

type Env = (name: string) => string | undefined;

/**
 * The key a client is built with, newest kind first.
 *
 * Supabase's legacy `anon` / `service_role` keys stop working at the end of
 * 2026, so they come last: kept only so a project without the new keys still
 * runs. Before them, in order:
 *
 *   1. `ALBUS_SUPABASE_*_KEY`, an override set by hand. The `SUPABASE_` prefix
 *      is reserved for the platform, hence the name.
 *   2. `SUPABASE_*_KEYS`, which the platform injects into every deployed
 *      function: a JSON object of named keys, of which `default` is the one
 *      the dashboard creates.
 *   3. `SUPABASE_*_KEY`, the single key `supabase start` injects locally.
 *   4. The legacy key.
 *
 * The new keys rotate one at a time, and a secret key refuses to work from a
 * browser. A legacy key is a JWT signed with the project's shared secret, so
 * replacing it means replacing that secret.
 */
export function resolveKey(
  kind: "secret" | "publishable",
  env: Env = (name) => Deno.env.get(name),
): string {
  const found = resolve(kind, env);
  if (found) return found.key;
  throw new HttpError(500, "MISCONFIGURED", `no ${kind} key is set`);
}

/** Where `resolveKey` takes a key from, in its order. */
type KeySource = "override" | "platform" | "local" | "legacy";

function resolve(
  kind: "secret" | "publishable",
  env: Env,
): { key: string; source: KeySource } | undefined {
  const upper = kind === "secret" ? "SECRET" : "PUBLISHABLE";
  const legacy = kind === "secret" ? "SUPABASE_SERVICE_ROLE_KEY" : "SUPABASE_ANON_KEY";
  const candidates: [KeySource, string | undefined][] = [
    ["override", env(`ALBUS_SUPABASE_${upper}_KEY`)],
    ["platform", namedDefault(env(`SUPABASE_${upper}_KEYS`))],
    ["local", env(`SUPABASE_${upper}_KEY`)],
    ["legacy", env(legacy)],
  ];
  const found = candidates.find(([, key]) => key);
  return found ? { source: found[0], key: found[1]! } : undefined;
}

/**
 * Which source each key comes from, by name and never by value. Logged once
 * as a function starts: before the legacy keys are switched off, the logs
 * must say `platform` for both, since an override or a dictionary without a
 * `default` entry would leave a function on a legacy key.
 */
export function keySources(
  env: Env = (name) => Deno.env.get(name),
): Record<"secret" | "publishable", KeySource | "missing"> {
  return {
    secret: resolve("secret", env)?.source ?? "missing",
    publishable: resolve("publishable", env)?.source ?? "missing",
  };
}

console.info("supabase keys", keySources());

/** A platform key dictionary's `default` entry; nothing when absent or unreadable. */
export function namedDefault(dictionary: string | undefined): string | undefined {
  if (!dictionary) return undefined;
  try {
    const value = (JSON.parse(dictionary) as Record<string, unknown>)?.["default"];
    return typeof value === "string" && value.length > 0 ? value : undefined;
  } catch {
    return undefined;
  }
}

/** Bypasses RLS. Only for writes the user must not control (entitlements, usage). */
export function adminClient(): SupabaseClient {
  return createClient(
    requireEnv("SUPABASE_URL"),
    resolveKey("secret"),
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
}

export async function requireUser(req: Request): Promise<Caller> {
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) {
    throw new HttpError(401, "MISSING_TOKEN", "Missing bearer token");
  }

  // Client bound to the caller's token: every query it runs is subject to RLS,
  // so even a bug in a function cannot read another user's rows.
  const db = createClient(
    requireEnv("SUPABASE_URL"),
    resolveKey("publishable"),
    {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    },
  );

  const { data, error } = await db.auth.getUser();
  if (error || !data.user) {
    throw new HttpError(401, "INVALID_SESSION", "Invalid or expired session");
  }

  return { id: data.user.id, isAnonymous: data.user.is_anonymous === true, db };
}
