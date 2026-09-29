import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { resolveKey } from "../_shared/auth.ts";
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
