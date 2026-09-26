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

/**
 * Supabase reserves the `SUPABASE_` prefix for secrets, so the modern
 * publishable/secret keys cannot be injected under those names. The runtime
 * does auto-inject the legacy `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_ROLE_KEY`
 * into every deployed function.
 *
 * So: prefer the modern key if it has been provided under a non-reserved name,
 * and fall back to the auto-injected legacy one. This keeps deploys working
 * with zero configuration while leaving a clean path to the new keys, which
 * rotate independently.
 */
function requireEnv(...names: string[]): string {
  for (const n of names) {
    const v = Deno.env.get(n);
    if (v) return v;
  }
  throw new HttpError(500, "MISCONFIGURED", `none of ${names.join(", ")} is set`);
}

/** Bypasses RLS. Only for writes the user must not control (entitlements, usage). */
export function adminClient(): SupabaseClient {
  return createClient(
    requireEnv("SUPABASE_URL"),
    requireEnv("ALBUS_SUPABASE_SECRET_KEY", "SUPABASE_SERVICE_ROLE_KEY"),
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
    requireEnv("ALBUS_SUPABASE_PUBLISHABLE_KEY", "SUPABASE_ANON_KEY"),
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
