import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { adminClient, keySources, requireUser, resolveKey } from "../_shared/auth.ts";
import { HttpError } from "../_shared/http.ts";

// Placeholders shaped like the real thing. Never a real key.
const OVERRIDE = "sb_secret_override_xxxxxxxx";
const PLATFORM = "sb_secret_platform_xxxxxxxx";
const LOCAL = "sb_secret_local_xxxxxxxx";
const LEGACY = "legacy.service.role";

const envOf = (values: Record<string, string>) => (name: string) => values[name];

Deno.test("the platform's own secret key wins over the legacy one", () => {
  // Exactly what a deployed function sees today: both kinds injected. The
  // legacy key stops working at the end of 2026, so it must not be the one
  // picked while a new key is there.
  const env = envOf({
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: PLATFORM }),
    SUPABASE_SERVICE_ROLE_KEY: LEGACY,
  });
  assertEquals(resolveKey("secret", env), PLATFORM);
});

Deno.test("the platform's own publishable key wins over the legacy anon key", () => {
  const env = envOf({
    SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "sb_publishable_platform" }),
    SUPABASE_ANON_KEY: "legacy.anon",
  });
  assertEquals(resolveKey("publishable", env), "sb_publishable_platform");
});

Deno.test("a hand-set override wins over everything the platform injects", () => {
  const env = envOf({
    ALBUS_SUPABASE_SECRET_KEY: OVERRIDE,
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: PLATFORM }),
    SUPABASE_SECRET_KEY: LOCAL,
    SUPABASE_SERVICE_ROLE_KEY: LEGACY,
  });
  assertEquals(resolveKey("secret", env), OVERRIDE);
});

Deno.test("the local stack's single key is used when there is no dictionary", () => {
  const env = envOf({ SUPABASE_SECRET_KEY: LOCAL, SUPABASE_SERVICE_ROLE_KEY: LEGACY });
  assertEquals(resolveKey("secret", env), LOCAL);
});

Deno.test("a project with only legacy keys still runs", () => {
  assertEquals(resolveKey("secret", envOf({ SUPABASE_SERVICE_ROLE_KEY: LEGACY })), LEGACY);
  assertEquals(
    resolveKey("publishable", envOf({ SUPABASE_ANON_KEY: "legacy.anon" })),
    "legacy.anon",
  );
});

Deno.test("an unreadable or keyless dictionary falls through instead of failing", () => {
  for (
    const dictionary of ["not json", "null", "5", "[]", "{}", '{"default":""}', '{"other":"x"}']
  ) {
    const env = envOf({ SUPABASE_SECRET_KEYS: dictionary, SUPABASE_SERVICE_ROLE_KEY: LEGACY });
    assertEquals(resolveKey("secret", env), LEGACY, `dictionary ${dictionary}`);
  }
});

Deno.test("no key at all is a configuration error, not a client built with nothing", () => {
  const error = assertThrows(() => resolveKey("secret", envOf({})), HttpError);
  assertEquals(error.status, 500);
  assertEquals(error.code, "MISCONFIGURED");
  // Names the kind, never a value.
  assertEquals(error.message, "no secret key is set");
});

Deno.test("a secret key is never taken from the publishable side, or the reverse", () => {
  const env = envOf({
    SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "sb_publishable_only" }),
    SUPABASE_ANON_KEY: "legacy.anon",
  });
  assertThrows(() => resolveKey("secret", env), HttpError);
  assertThrows(
    () =>
      resolveKey(
        "publishable",
        envOf({ SUPABASE_SECRET_KEYS: JSON.stringify({ default: PLATFORM }) }),
      ),
    HttpError,
  );
});

Deno.test("the startup log names where each key comes from, never the key", () => {
  const platform = envOf({
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: PLATFORM }),
    SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "sb_publishable_platform" }),
    SUPABASE_SERVICE_ROLE_KEY: LEGACY,
    SUPABASE_ANON_KEY: "legacy.anon",
  });
  assertEquals(keySources(platform), { secret: "platform", publishable: "platform" });
  assertEquals(JSON.stringify(keySources(platform)).includes("sb_"), false);

  // What would break when the legacy keys are switched off: an override, or a
  // dictionary whose key is not named `default`.
  assertEquals(
    keySources(envOf({ ALBUS_SUPABASE_SECRET_KEY: OVERRIDE, SUPABASE_ANON_KEY: "legacy.anon" })),
    { secret: "override", publishable: "legacy" },
  );
  assertEquals(
    keySources(envOf({
      SUPABASE_SECRET_KEYS: JSON.stringify({ billing: PLATFORM }),
      SUPABASE_SERVICE_ROLE_KEY: LEGACY,
    })),
    { secret: "legacy", publishable: "missing" },
  );
  assertEquals(keySources(envOf({ SUPABASE_SECRET_KEY: LOCAL })).secret, "local");
});

// The clients themselves, as a deployed function builds them: the platform's
// new keys beside the legacy ones, and every request caught before it leaves.
const URL_BASE = "https://keys.unit.invalid";
const PUBLISHABLE = "sb_publishable_platform_xxxxxxxx";
const USER_ID = "7a3f0000-0000-4000-8000-000000000001";
const PLATFORM_ENV = {
  SUPABASE_URL: URL_BASE,
  SUPABASE_SECRET_KEYS: JSON.stringify({ default: PLATFORM }),
  SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: PUBLISHABLE }),
  SUPABASE_SERVICE_ROLE_KEY: LEGACY,
  SUPABASE_ANON_KEY: "legacy.anon",
};

async function onTheWire(
  env: Record<string, string>,
  answer: (url: URL) => unknown,
  run: () => Promise<void>,
): Promise<{ url: URL; headers: Headers }[]> {
  const names = [...Object.keys(env), "ALBUS_SUPABASE_SECRET_KEY", "ALBUS_SUPABASE_PUBLISHABLE_KEY"];
  const previous = Object.fromEntries(names.map((name) => [name, Deno.env.get(name)]));
  const originalFetch = globalThis.fetch;
  const sent: { url: URL; headers: Headers }[] = [];
  try {
    for (const name of names) Deno.env.delete(name);
    for (const [name, value] of Object.entries(env)) Deno.env.set(name, value);
    globalThis.fetch = (input, init) => {
      const request = new Request(input, init);
      const url = new URL(request.url);
      if (url.origin !== URL_BASE) throw new Error("Unexpected network request");
      sent.push({ url, headers: request.headers });
      return Promise.resolve(Response.json(answer(url)));
    };
    await run();
  } finally {
    globalThis.fetch = originalFetch;
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) Deno.env.delete(name);
      else Deno.env.set(name, value);
    }
  }
  return sent;
}

Deno.test("the admin client reaches the database with the platform's secret key", async () => {
  const sent = await onTheWire(PLATFORM_ENV, () => [{ tier: "free" }], async () => {
    const { error } = await adminClient().from("plans").select("tier").limit(1);
    assertEquals(error, null);
  });
  assertEquals(sent.length, 1);
  assertEquals(sent[0].url.pathname, "/rest/v1/plans");
  assertEquals(sent[0].headers.get("apikey"), PLATFORM);
  // With no session the client repeats the key as a bearer token; Supabase's
  // gateway replaces a `Bearer sb_` value with the role's own JWT.
  assertEquals(sent[0].headers.get("authorization"), `Bearer ${PLATFORM}`);
});

Deno.test("a student is identified by their own token, sent with the platform's publishable key", async () => {
  const sent = await onTheWire(
    PLATFORM_ENV,
    () => ({ id: USER_ID, aud: "authenticated", role: "authenticated", is_anonymous: true }),
    async () => {
      const caller = await requireUser(
        new Request("https://function.invalid", { headers: { Authorization: "Bearer student.session.jwt" } }),
      );
      assertEquals(caller.id, USER_ID);
      assertEquals(caller.isAnonymous, true);
    },
  );
  assertEquals(sent.length, 1);
  assertEquals(sent[0].url.pathname, "/auth/v1/user");
  assertEquals(sent[0].headers.get("apikey"), PUBLISHABLE);
  assertEquals(
    sent[0].headers.get("authorization"),
    "Bearer student.session.jwt",
    "the student's token, which the gateway passes through untouched",
  );
});

Deno.test("no client sends a legacy key while the platform's keys are there", async () => {
  const sent = await onTheWire(
    PLATFORM_ENV,
    (url) => url.pathname === "/auth/v1/user" ? { id: USER_ID, aud: "authenticated" } : [],
    async () => {
      await adminClient().rpc("effective_tier", { p_user_id: USER_ID });
      await requireUser(new Request("https://function.invalid", { headers: { Authorization: "Bearer t" } }));
    },
  );
  assertEquals(sent.length, 2);
  for (const { headers } of sent) {
    const values = [...headers.values()].join(" ");
    assertEquals(values.includes(LEGACY) || values.includes("legacy.anon"), false);
  }
});
