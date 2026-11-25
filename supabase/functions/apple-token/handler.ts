import { appleConfig, exchangeAppleCode } from "../_shared/apple_auth.ts";
import { readJsonBody } from "../_shared/body.ts";
import { errorResponse, HttpError, jsonResponse } from "../_shared/http.ts";

// Keeps the Apple refresh token for the signed-in account, so deleting it
// later can revoke Sign in with Apple without sending the student back through
// Apple's sheet (`delete-account`). The app calls this once per sign-in with
// that sign-in's authorization code, which is single-use and lasts minutes.
//
// Best-effort by design: an account with no token kept still deletes, through
// the sheet, exactly as before this existed. So every refusal from Apple is a
// quiet `{ stored: false }`, and only a malformed request or a missing caller
// is an error. The token is checked against the caller's own Apple ID before
// it is kept, and it is kept in Vault (`store_apple_refresh_token`).

type Rpc = (
  name: string,
  args?: Record<string, unknown>,
) => PromiseLike<{ data?: unknown; error: unknown }>;
interface Dependencies {
  requireUser: (req: Request) => Promise<{ id: string }>;
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

async function authorizationCode(req: Request): Promise<string> {
  try {
    const body = await readJsonBody<unknown>(req, 2_048);
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error();
    const fields = body as Record<string, unknown>;
    if (Object.keys(fields).some((key) => key !== "apple_authorization_code")) throw new Error();
    const code = fields.apple_authorization_code;
    if (typeof code !== "string" || !code.trim() || code.length > 1_024) throw new Error();
    return code;
  } catch {
    throw new HttpError(400, "INVALID_REQUEST");
  }
}

export function createAppleTokenHandler(deps: Dependencies) {
  return async (req: Request): Promise<Response> => {
    try {
      if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");
      const code = await authorizationCode(req);
      const caller = await deps.requireUser(req);
      const config = appleConfig(deps.env);
      if (!config) return jsonResponse({ stored: false });

      const admin = deps.adminClient();
      const { data, error } = await admin.auth.admin.getUserById(caller.id);
      if (error || !data.user) throw new HttpError(500, "INTERNAL_ERROR");
      const identity = data.user.identities?.find((identity) => identity.provider === "apple");
      if (!identity) return jsonResponse({ stored: false });
      const sub = identity.identity_data?.sub;
      const subject = typeof sub === "string" && sub ? sub : identity.id;

      let exchange;
      try {
        exchange = await exchangeAppleCode(config, code, subject, deps.fetch, deps.now());
      } catch {
        // A spent code, or another Apple ID's: nothing to keep.
        return jsonResponse({ stored: false });
      }
      if (!exchange.ok || !exchange.refresh) return jsonResponse({ stored: false });

      const kept = await admin.rpc("store_apple_refresh_token", {
        p_user_id: caller.id,
        p_token: exchange.refresh,
      });
      if (kept.error) throw new HttpError(500, "INTERNAL_ERROR");
      return jsonResponse({ stored: true });
    } catch (error) {
      return errorResponse(error);
    }
  };
}
