import { assert, assertEquals } from "jsr:@std/assert@1";
import type { AppleConfig } from "../_shared/apple_auth.ts";
import { HttpError } from "../_shared/http.ts";
import { createAppleTokenHandler } from "../apple-token/handler.ts";

// The refresh token kept at sign-in, so deletion needs no second sign-in.

const CODE = "private-authorization-code";
const SUB = "private-apple-subject";
const REFRESH = "private-refresh-token";
const now = 1_790_000_000_123;

const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
  "sign",
  "verify",
]);
const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
const pem = `-----BEGIN PRIVATE KEY-----\n${
  btoa(String.fromCharCode(...der))
}\n-----END PRIVATE KEY-----`;
const config: AppleConfig = {
  teamId: "test-team",
  keyId: "test-key",
  privateKey: pem,
  clientId: "com.felipegutierrez.albus",
};

function jwt(sub = SUB): string {
  return `header.${btoa(JSON.stringify({ sub }))}.signature`;
}
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

type Options = {
  apple?: boolean;
  unconfigured?: boolean;
  noCaller?: boolean;
  exchange?: Response | Error;
  storeError?: boolean;
};
function fixture(options: Options = {}) {
  const calls: string[] = [];
  const forms: URLSearchParams[] = [];
  const stored: Record<string, unknown>[] = [];
  const env: Record<string, string> = {
    APPLE_TEAM_ID: config.teamId,
    APPLE_KEY_ID: config.keyId,
    APPLE_PRIVATE_KEY: pem,
    APPLE_CLIENT_ID: config.clientId,
  };
  const handler = createAppleTokenHandler({
    env: (name) => options.unconfigured ? undefined : env[name],
    now: () => now,
    requireUser: () => {
      if (options.noCaller) return Promise.reject(new HttpError(401, "MISSING_TOKEN"));
      return Promise.resolve({ id: "caller" });
    },
    adminClient: () => ({
      auth: {
        admin: {
          getUserById: (id) => {
            assertEquals(id, "caller");
            return Promise.resolve({
              data: {
                user: {
                  identities: options.apple === false
                    ? [{ provider: "email", id: "x" }]
                    : [{ provider: "apple", id: SUB, identity_data: { sub: SUB } }],
                },
              },
              error: null,
            });
          },
        },
      },
      rpc: (name, args) => {
        assertEquals(name, "store_apple_refresh_token");
        calls.push("store");
        stored.push(args!);
        return Promise.resolve({ error: options.storeError ? { message: REFRESH } : null });
      },
    }),
    fetch: ((url, init) => {
      assertEquals(String(url), "https://appleid.apple.com/auth/token");
      assertEquals(init?.method, "POST");
      calls.push("exchange");
      forms.push(new URLSearchParams(String(init?.body)));
      const response = options.exchange;
      if (response instanceof Error) return Promise.reject(response);
      return Promise.resolve(
        response ?? json({ id_token: jwt(), refresh_token: REFRESH, access_token: "a" }),
      );
    }) as typeof fetch,
  });
  return { handler, calls, forms, stored };
}
function request(body: unknown = { apple_authorization_code: CODE }, method = "POST"): Request {
  return new Request("https://unit.invalid/apple-token", {
    method,
    ...(method === "POST" ? { body: JSON.stringify(body) } : {}),
  });
}

Deno.test("keeps the caller's own refresh token, exchanged with exact fields", async () => {
  const f = fixture();
  const response = await f.handler(request());
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { stored: true });
  assertEquals(f.calls, ["exchange", "store"]);
  assertEquals(f.forms[0].get("code"), CODE);
  assertEquals(f.forms[0].get("grant_type"), "authorization_code");
  assertEquals(f.forms[0].get("client_id"), config.clientId);
  assert((f.forms[0].get("client_secret") ?? "").split(".").length === 3);
  assertEquals(f.stored, [{ p_user_id: "caller", p_token: REFRESH }]);
});

Deno.test("nothing is kept for another Apple ID, a spent code, or Apple refusing", async () => {
  const cases: Response[] = [
    json({ id_token: jwt("someone-else"), refresh_token: REFRESH }),
    json({ error: "invalid_grant" }, 400),
    json({ error: "invalid_client" }, 401),
    json({ id_token: jwt(), access_token: "only-access" }),
  ];
  for (const exchange of cases) {
    const f = fixture({ exchange });
    const response = await f.handler(request());
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { stored: false });
    assertEquals(f.calls, ["exchange"], "nothing stored");
  }
  const offline = fixture({ exchange: new TypeError("network") });
  assertEquals(await (await offline.handler(request())).json(), { stored: false });
  assertEquals(offline.calls, ["exchange"]);
});

Deno.test("an account without Apple, or a server without Apple's keys, keeps nothing", async () => {
  for (const options of [{ apple: false }, { unconfigured: true }]) {
    const f = fixture(options);
    const response = await f.handler(request());
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { stored: false });
    assertEquals(f.calls, []);
  }
});

Deno.test("a bad request or no caller makes no Apple call and keeps nothing", async () => {
  for (
    const [req, status] of [
      [request({}), 400],
      [request({ apple_authorization_code: "" }), 400],
      [request({ apple_authorization_code: CODE, extra: 1 }), 400],
      [request({ apple_authorization_code: "x".repeat(1_025) }), 400],
      [request(undefined, "GET"), 405],
    ] as const
  ) {
    const f = fixture();
    assertEquals((await f.handler(req)).status, status);
    assertEquals(f.calls, []);
  }
  const f = fixture({ noCaller: true });
  assertEquals((await f.handler(request())).status, 401);
  assertEquals(f.calls, []);
});

Deno.test("a failed store is an error, and never repeats the token", async () => {
  const f = fixture({ storeError: true });
  const response = await f.handler(request());
  assertEquals(response.status, 500);
  const text = await response.text();
  assert(!text.includes(REFRESH) && !text.includes(CODE) && !text.includes(SUB));
});
