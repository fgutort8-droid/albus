import { appleConfig, revokeApple } from "../_shared/apple_auth.ts";
import { readJsonBody } from "../_shared/body.ts";
import { errorResponse, HttpError, jsonResponse } from "../_shared/http.ts";

type Rpc = (name: string, args?: Record<string, unknown>) => PromiseLike<{ error: unknown }>;
interface Dependencies {
  requireUser: (req: Request) => Promise<{ id: string; db: { rpc: Rpc } }>;
  adminClient: () => {
    rpc: Rpc;
    auth: {
      admin: {
        getUserById: (id: string) => Promise<{
          data: {
            user: {
              identities?: {
                provider: string;
                id: string;
                identity_data?: Record<string, unknown>;
              }[];
            } | null;
          };
          error: unknown;
        }>;
      };
    };
  };
  env: (name: string) => string | undefined;
  fetch: typeof fetch;
  now: () => number;
}

async function authorizationCode(req: Request): Promise<string | undefined> {
  try {
    const body = await readJsonBody<unknown>(req, 2_048);
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error();
    const fields = body as Record<string, unknown>;
    if (Object.keys(fields).some((key) => key !== "apple_authorization_code")) throw new Error();
    const code = fields.apple_authorization_code;
    if (code !== undefined && (typeof code !== "string" || !code.trim() || code.length > 1_024)) {
      throw new Error();
    }
    return code as string | undefined;
  } catch {
    throw new HttpError(400, "INVALID_REQUEST");
  }
}

export function createDeleteAccountHandler(deps: Dependencies) {
  return async (req: Request): Promise<Response> => {
    try {
      if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");
      const code = await authorizationCode(req);
      const caller = await deps.requireUser(req);
      const admin = deps.adminClient();
      const { data, error } = await admin.auth.admin.getUserById(caller.id);
      if (error || !data.user) throw new HttpError(500, "INTERNAL_ERROR");
      const identity = data.user.identities?.find((identity) => identity.provider === "apple");
      let appleRevoked = false;
      if (identity) {
        const config = appleConfig(deps.env);
        let failure: { kind: string; code: string } | undefined;
        if (!config) {
          failure = { kind: "apple_revoke_unconfigured", code: "invalid_client" };
        } else {
          if (!code) throw new HttpError(428, "APPLE_REAUTH_REQUIRED");
          const sub = identity.identity_data?.sub;
          const subject = typeof sub === "string" && sub ? sub : identity.id;
          const result = await revokeApple(config, code, subject, deps.fetch, deps.now());
          appleRevoked = result.revoked;
          if (!result.revoked) failure = { kind: "apple_revoke_failed", code: result.code };
        }
        if (failure) {
          // Await before deletion: log_security_event drops nonexistent users.
          // ON DELETE SET NULL keeps the warning after erasure, with no hashes.
          try {
            const { error } = await admin.rpc("log_security_event", {
              p_user_id: caller.id,
              p_kind: failure.kind,
              p_severity: "warn",
              p_device_hash: null,
              p_ip_prefix_hash: null,
              p_detail: { endpoint: "delete-account", code: failure.code },
            });
            if (error) console.warn("security event write failed");
          } catch {
            console.warn("security event write failed");
          }
        }
      }
      // No API rate gate: its SQL allowlist covers only breakdown/chat/grade.
      // Each request makes at most one exchange and revoke; success deletes the
      // authenticated caller, and the code comes from their Apple sign-in sheet.
      const result = await caller.db.rpc("delete_my_account");
      if (result.error) throw new HttpError(500, "INTERNAL_ERROR");
      return jsonResponse({ deleted: true, apple_revoked: appleRevoked });
    } catch (error) {
      return errorResponse(error);
    }
  };
}
