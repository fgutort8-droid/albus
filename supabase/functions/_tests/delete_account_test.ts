import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { appleClientSecret, type AppleConfig } from "../_shared/apple_auth.ts";
import { HttpError } from "../_shared/http.ts";
import { createDeleteAccountHandler } from "../delete-account/handler.ts";

const CODE = "private-authorization-code";
const SUB = "private-apple-subject";
const EMAIL = "private-student@example.invalid";
const REFRESH = "private-refresh-token";
const ACCESS = "private-access-token";
const now = 1_790_000_000_123;

function decode(segment: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(
    atob(segment.replace(/-/g, "+").replace(/_/g, "/")),
    (c) => c.charCodeAt(0),
  );
}
function jwt(sub = SUB): string {
  return `header.${btoa(JSON.stringify({ sub, email: EMAIL }))}.signature`;
}
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

Deno.test("Apple client secret verifies, has exact claims, and accepts both PEM newline forms", async () => {
  for (const privateKey of [pem, pem.replace(/\n/g, "\\n")]) {
    const token = await appleClientSecret({ ...config, privateKey }, now);
    const [header, claims, signature] = token.split(".");
    assertEquals(JSON.parse(new TextDecoder().decode(decode(header))), {
      alg: "ES256",
      kid: config.keyId,
    });
    const payload = JSON.parse(new TextDecoder().decode(decode(claims)));
    assertEquals(payload, {
      iss: config.teamId,
      iat: Math.floor(now / 1000),
      exp: Math.floor(now / 1000) + 300,
      aud: "https://appleid.apple.com",
      sub: config.clientId,
    });
    assertEquals(payload.exp - payload.iat, 300);
    assert(
      await crypto.subtle.verify(
        { name: "ECDSA", hash: "SHA-256" },
        pair.publicKey,
        decode(signature),
        new TextEncoder().encode(`${header}.${claims}`),
      ),
    );
  }
});

type Options = {
  apple?: boolean;
  missing?: string;
  noCaller?: boolean;
  identityFallback?: boolean;
  exchange?: Response | Error;
  revoke?: Response | Error;
  deleteError?: boolean;
  adminError?: boolean;
  logError?: boolean;
};
function fixture(options: Options = {}) {
  const calls: string[] = [];
  const forms: URLSearchParams[] = [];
  const events: Record<string, unknown>[] = [];
  const env: Record<string, string> = {
    APPLE_TEAM_ID: config.teamId,
    APPLE_KEY_ID: config.keyId,
    APPLE_PRIVATE_KEY: pem,
    APPLE_CLIENT_ID: config.clientId,
  };
  const handler = createDeleteAccountHandler({
    env: (name) => name === options.missing ? undefined : env[name],
    now: () => now,
    requireUser: async () => {
      if (options.noCaller) throw new HttpError(401, "MISSING_TOKEN");
      return {
        id: "caller",
        db: {
          rpc: (name) => {
            assertEquals(name, "delete_my_account");
            calls.push("delete");
            return Promise.resolve({ error: options.deleteError ? { message: CODE } : null });
          },
        },
      };
    },
    adminClient: () => ({
      auth: {
        admin: {
          getUserById: async (id) => {
            assertEquals(id, "caller");
            return {
              data: {
                user: {
                  identities: options.apple === false ? [{ provider: "email", id: EMAIL }] : [{
                    provider: "apple",
                    id: SUB,
                    identity_data: options.identityFallback ? {} : { sub: SUB },
                  }],
                },
              },
              error: options.adminError ? EMAIL : null,
            };
          },
        },
      },
      rpc: async (name, args) => {
        assertEquals(name, "log_security_event");
        calls.push("event-start");
        await Promise.resolve();
        events.push(args!);
        calls.push("event-done");
        if (options.logError) throw new Error(REFRESH);
        return { error: null };
      },
    }),
    fetch: (async (url, init) => {
      assertEquals(init?.method, "POST");
      assertEquals(
        new Headers(init?.headers).get("Content-Type"),
        "application/x-www-form-urlencoded",
      );
      assert(init?.signal instanceof AbortSignal);
      assertEquals(init.redirect, "error");
      const exchange = String(url).endsWith("/token");
      assertEquals(String(url), `https://appleid.apple.com/auth/${exchange ? "token" : "revoke"}`);
      calls.push(exchange ? "exchange" : "revoke");
      forms.push(new URLSearchParams(String(init.body)));
      const response = exchange ? options.exchange : options.revoke;
      if (response instanceof Error) throw response;
      return response ??
        (exchange
          ? json({ id_token: jwt(), refresh_token: REFRESH, access_token: ACCESS })
          : new Response(null, { status: 200 }));
    }) as typeof fetch,
  });
  return { handler, calls, forms, events };
}
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
function request(body: unknown = { apple_authorization_code: CODE }, method = "POST"): Request {
  return new Request("https://unit.invalid/delete-account", {
    method,
    ...(method === "POST" ? { body: JSON.stringify(body) } : {}),
  });
}

Deno.test("email and legacy anonymous accounts delete without Apple", async () => {
  for (const body of [{}, { apple_authorization_code: CODE }]) {
    const f = fixture({ apple: false });
    const response = await f.handler(request(body));
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { deleted: true, apple_revoked: false });
    assertEquals(f.calls, ["delete"]);
  }
});
Deno.test("Apple account without a code requires reauthentication", async () => {
  const f = fixture();
  const response = await f.handler(request({}));
  assertEquals(response.status, 428);
  assertEquals((await response.json()).error, "APPLE_REAUTH_REQUIRED");
  assertEquals(f.calls, []);
});
Deno.test("expired code and another Apple ID neither revoke nor delete", async () => {
  for (
    const [exchange, expected] of [[json({ error: "invalid_grant" }, 400), "APPLE_CODE_INVALID"], [
      json({ id_token: jwt("another-id"), refresh_token: REFRESH }),
      "APPLE_ACCOUNT_MISMATCH",
    ]] as const
  ) {
    const f = fixture({ exchange });
    const response = await f.handler(request());
    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, expected);
    assertEquals(f.calls, ["exchange"]);
    assertEquals(f.events, []);
  }
});
Deno.test("exchange, compare, refresh revoke, then delete with exact form fields", async () => {
  const f = fixture();
  const response = await f.handler(request());
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { deleted: true, apple_revoked: true });
  assertEquals(f.calls, ["exchange", "revoke", "delete"]);
  const [exchange, revoke] = f.forms;
  assertEquals([...exchange.keys()].sort(), ["client_id", "client_secret", "code", "grant_type"]);
  assertEquals(exchange.get("client_id"), config.clientId);
  assertEquals(exchange.get("code"), CODE);
  assertEquals(exchange.get("grant_type"), "authorization_code");
  assertEquals(Object.fromEntries(revoke), {
    client_id: config.clientId,
    client_secret: exchange.get("client_secret")!,
    token: REFRESH,
    token_type_hint: "refresh_token",
  });
  assertEquals(f.events, []);
});
Deno.test("access token fallback and Apple identity id fallback", async () => {
  const f = fixture({
    identityFallback: true,
    exchange: json({ id_token: jwt(), access_token: ACCESS }),
  });
  assertEquals((await f.handler(request())).status, 200);
  assertEquals(f.forms[1].get("token"), ACCESS);
  assertEquals(f.forms[1].get("token_type_hint"), "access_token");
});
Deno.test("Apple failures await exactly one warning before deletion", async (t) => {
  const cases: [string, Options, string][] = [
    ["5xx", { exchange: json({}, 503) }, "503"],
    ["network", { exchange: new TypeError(CODE) }, "network"],
    ["timeout", { exchange: new DOMException(ACCESS, "TimeoutError") }, "timeout"],
    ["invalid_client", { exchange: json({ error: "invalid_client" }, 400) }, "invalid_client"],
    ["unexpected 4xx", { exchange: json({ error: CODE }, 403) }, "403"],
    ["no tokens", { exchange: json({ id_token: jwt() }) }, "200"],
    ["malformed id token", { exchange: json({ id_token: CODE, refresh_token: REFRESH }) }, "200"],
    ["bad JSON", { exchange: new Response(CODE) }, "network"],
    ["revoke failed", { revoke: json({ error: "invalid_token" }, 400) }, "invalid_token"],
    ["revoke network", { revoke: new TypeError(REFRESH) }, "network"],
  ];
  for (const key of ["APPLE_TEAM_ID", "APPLE_KEY_ID", "APPLE_PRIVATE_KEY", "APPLE_CLIENT_ID"]) {
    cases.push([key, { missing: key }, "invalid_client"]);
  }
  for (const [name, options, expected] of cases) {
    await t.step(name, async () => {
      const f = fixture(options);
      const response = await f.handler(request(options.missing ? {} : undefined));
      assertEquals(response.status, 200);
      assertEquals(await response.json(), { deleted: true, apple_revoked: false });
      assertEquals(f.calls.slice(-3), ["event-start", "event-done", "delete"]);
      assertEquals(f.events.length, 1);
      assertEquals(f.events[0], {
        p_user_id: "caller",
        p_kind: options.missing ? "apple_revoke_unconfigured" : "apple_revoke_failed",
        p_severity: "warn",
        p_device_hash: null,
        p_ip_prefix_hash: null,
        p_detail: { endpoint: "delete-account", code: expected },
      });
    });
  }
});
Deno.test("bad requests and absent caller make no Apple or deletion calls", async () => {
  const requests = [
    request({}, "GET"),
    request(null),
    request([]),
    request("text"),
    request({ apple_authorization_code: 42 }),
    request({ apple_authorization_code: "" }),
    request({ apple_authorization_code: "  " }),
    request({ apple_authorization_code: "x".repeat(1_025) }),
    request({ unknown: true }),
    request({ unknown: "x".repeat(2_048) }),
    new Request("https://unit.invalid", { method: "POST", body: "{" }),
    new Request("https://unit.invalid", {
      method: "POST",
      body: "{}",
      headers: { "Content-Length": "2049" },
    }),
  ];
  for (const req of requests) {
    const f = fixture();
    const response = await f.handler(req);
    assertEquals(response.status, req.method === "GET" ? 405 : 400);
    assertEquals(
      (await response.json()).error,
      req.method === "GET" ? "METHOD_NOT_ALLOWED" : "INVALID_REQUEST",
    );
    assertEquals(f.calls, []);
  }
  const f = fixture({ noCaller: true });
  assertEquals((await f.handler(request())).status, 401);
  assertEquals(f.calls, []);
});
Deno.test("database failures return general errors; event failure still allows deletion", async () => {
  for (const options of [{ deleteError: true }, { adminError: true }]) {
    const f = fixture({ apple: false, ...options });
    const response = await f.handler(request({}));
    assertEquals(response.status, 500);
    assertEquals((await response.json()).error, "INTERNAL_ERROR");
  }
  const f = fixture({ missing: "APPLE_KEY_ID", logError: true });
  const warn = console.warn;
  console.warn = () => {};
  try {
    assertEquals((await f.handler(request({}))).status, 200);
  } finally {
    console.warn = warn;
  }
  assertEquals(f.calls.at(-1), "delete");
});
Deno.test("responses, console and security details never leak private data", async () => {
  const lines: string[] = [];
  const originals = {
    log: console.log,
    warn: console.warn,
    error: console.error,
    info: console.info,
    debug: console.debug,
  };
  for (const level of Object.keys(originals) as (keyof typeof originals)[]) {
    console[level] = (...args: unknown[]) => {
      lines.push(JSON.stringify(args));
    };
  }
  try {
    for (
      const options of [
        {},
        { exchange: json({ error: CODE }, 403) },
        { exchange: new Error(pem) },
        { exchange: json({ id_token: jwt("wrong"), refresh_token: REFRESH }) },
        { missing: "APPLE_KEY_ID", logError: true },
        { apple: false, deleteError: true },
      ]
    ) {
      const f = fixture(options);
      const response = await f.handler(request());
      const exposed = await response.text() + JSON.stringify(f.events) + lines.join("\n");
      for (const secret of [CODE, SUB, EMAIL, REFRESH, ACCESS, pem]) {
        assertFalse(exposed.includes(secret));
      }
    }
  } finally {
    Object.assign(console, originals);
  }
});
