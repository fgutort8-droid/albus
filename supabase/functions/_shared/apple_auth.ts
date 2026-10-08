import { HttpError } from "./http.ts";

export interface AppleConfig {
  teamId: string;
  keyId: string;
  privateKey: string;
  clientId: string;
}

export function appleConfig(env: (name: string) => string | undefined): AppleConfig | null {
  const teamId = env("APPLE_TEAM_ID");
  const keyId = env("APPLE_KEY_ID");
  const privateKey = env("APPLE_PRIVATE_KEY");
  const clientId = env("APPLE_CLIENT_ID");
  return teamId && keyId && privateKey && clientId ? { teamId, keyId, privateKey, clientId } : null;
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/=/g, "").replace(/\+/g, "-").replace(
    /\//g,
    "_",
  );
}

function encode(value: unknown): string {
  return base64url(new TextEncoder().encode(JSON.stringify(value)));
}

export async function appleClientSecret(config: AppleConfig, now: number): Promise<string> {
  const pem = config.privateKey.replace(/\\n/g, "\n")
    .replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const key = await crypto.subtle.importKey(
    "pkcs8",
    Uint8Array.from(atob(pem), (char) => char.charCodeAt(0)),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const iat = Math.floor(now / 1000);
  const unsigned = `${encode({ alg: "ES256", kid: config.keyId })}.${
    encode({
      iss: config.teamId,
      iat,
      exp: iat + 300,
      aud: "https://appleid.apple.com",
      sub: config.clientId,
    })
  }`;
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(unsigned),
  );
  return `${unsigned}.${base64url(new Uint8Array(signature))}`;
}

export type AppleRevocation = { revoked: true } | { revoked: false; code: string };

// Only recognized machine codes may enter telemetry. Arbitrary upstream text
// could contain a token or other personal data; fall back to the HTTP status.
const APPLE_ERRORS = new Set([
  "invalid_client",
  "invalid_grant",
  "invalid_request",
  "unauthorized_client",
  "unsupported_grant_type",
  "invalid_scope",
  "invalid_token",
  "server_error",
  "temporarily_unavailable",
]);

function failureCode(body: Record<string, unknown>, status: number): string {
  return typeof body.error === "string" && APPLE_ERRORS.has(body.error)
    ? body.error
    : String(status);
}

async function objectBody(response: Response): Promise<Record<string, unknown>> {
  const body: unknown = await response.json();
  if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error("invalid response");
  return body as Record<string, unknown>;
}

function tokenSubject(token: unknown): string | null {
  if (typeof token !== "string" || token.split(".").length !== 3) return null;
  try {
    const segment = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const bytes = Uint8Array.from(atob(segment), (char) => char.charCodeAt(0));
    const payload = JSON.parse(new TextDecoder().decode(bytes));
    return typeof payload?.sub === "string" && payload.sub ? payload.sub : null;
  } catch {
    return null;
  }
}

export async function revokeApple(
  config: AppleConfig,
  code: string,
  subject: string,
  fetcher: typeof fetch,
  now: number,
): Promise<AppleRevocation> {
  let clientSecret: string;
  try {
    clientSecret = await appleClientSecret(config, now);
  } catch {
    return { revoked: false, code: "invalid_client" };
  }
  const post = (path: string, fields: Record<string, string>) =>
    fetcher(
      `https://appleid.apple.com/auth/${path}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          client_id: config.clientId,
          client_secret: clientSecret,
          ...fields,
        }),
        signal: AbortSignal.timeout(8_000),
        redirect: "error",
      },
    );
  try {
    const exchange = await post("token", { code, grant_type: "authorization_code" });
    const body = await objectBody(exchange);
    if (exchange.status === 400 && body.error === "invalid_grant") {
      throw new HttpError(400, "APPLE_CODE_INVALID");
    }
    if (!exchange.ok) return { revoked: false, code: failureCode(body, exchange.status) };
    // The id_token came directly from Apple's TLS endpoint in response to our
    // signed exchange, so only its payload is read; no signature verification.
    const returnedSubject = tokenSubject(body.id_token);
    if (!returnedSubject) return { revoked: false, code: String(exchange.status) };
    if (returnedSubject !== subject) throw new HttpError(400, "APPLE_ACCOUNT_MISMATCH");
    const refresh = typeof body.refresh_token === "string" && body.refresh_token;
    const access = typeof body.access_token === "string" && body.access_token;
    if (!refresh && !access) return { revoked: false, code: String(exchange.status) };
    const revoke = await post("revoke", {
      token: refresh || access || "",
      token_type_hint: refresh ? "refresh_token" : "access_token",
    });
    if (revoke.status === 200) return { revoked: true };
    let revokeBody = {};
    try {
      revokeBody = await objectBody(revoke);
    } catch { /* Status is sufficient. */ }
    return { revoked: false, code: failureCode(revokeBody, revoke.status) };
  } catch (error) {
    if (error instanceof HttpError) throw error;
    return {
      revoked: false,
      code: error instanceof DOMException &&
          (error.name === "TimeoutError" || error.name === "AbortError")
        ? "timeout"
        : "network",
    };
  }
}
