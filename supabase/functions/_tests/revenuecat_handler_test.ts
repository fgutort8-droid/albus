import { assertEquals } from "jsr:@std/assert@1";

Deno.test("signed transfer delivery preserves ordering inputs and all authorization gates", async (t) => {
  const env = {
    REVENUECAT_WEBHOOK_SECRET: "unit-header",
    REVENUECAT_WEBHOOK_SIGNING_SECRET: "unit-signing",
    REVENUECAT_APP_IDS: "unit-app",
    SUPABASE_URL: "https://unit.invalid",
    SUPABASE_SERVICE_ROLE_KEY: "unit-service",
  };
  const previous = Object.fromEntries(Object.keys(env).map((key) => [key, Deno.env.get(key)]));
  const originalServe = Deno.serve;
  const originalFetch = globalThis.fetch;
  const originalError = console.error;
  const originalWarn = console.warn;
  let handler: (request: Request) => Promise<Response>;
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  let result = "transferred";
  try {
    for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
    Deno.serve = ((fn: typeof handler) => {
      handler = fn;
      return {};
    }) as typeof Deno.serve;
    globalThis.fetch = async (input, init) => {
      const url = new URL(
        typeof input === "string" ? input : input instanceof URL ? input.href : input.url,
      );
      if (url.hostname !== "unit.invalid" || !url.pathname.startsWith("/rest/v1/rpc/")) {
        throw new Error("Unexpected network request");
      }
      calls.push({ name: url.pathname.split("/").at(-1)!, args: JSON.parse(String(init?.body)) });
      return new Response(JSON.stringify(result), {
        headers: { "Content-Type": "application/json" },
      });
    };
    await import("../revenuecat-webhook/index.ts");
    const base = {
      type: "TRANSFER",
      id: "unit-transfer",
      event_timestamp_ms: 1_000_000,
      transferred_from: ["a9500000-0000-4000-8000-000000000001"],
      transferred_to: ["a9500000-0000-4000-8000-000000000002"],
    };
    async function deliver(
      extra = {},
      options: { age?: number; auth?: string; tamper?: boolean } = {},
    ) {
      const body = JSON.stringify({ event: { ...base, ...extra } });
      const time = Math.floor(Date.now() / 1000) - (options.age ?? 0);
      const encoder = new TextEncoder();
      const key = await crypto.subtle.importKey(
        "raw",
        encoder.encode(env.REVENUECAT_WEBHOOK_SIGNING_SECRET),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"],
      );
      const signature = Array.from(
        new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(`${time}.${body}`))),
        (byte) => byte.toString(16).padStart(2, "0"),
      ).join("");
      return handler!(
        new Request("https://unit.invalid/webhook", {
          method: "POST",
          headers: {
            Authorization: options.auth ?? env.REVENUECAT_WEBHOOK_SECRET,
            "x-revenuecat-webhook-signature": `t=${time},v1=${signature}`,
          },
          body: options.tamper ? body + " " : body,
        }),
      );
    }
    await t.step("omitted metadata uses verified stored purchase scope", async () => {
      const response = await deliver();
      assertEquals(response.status, 200);
      assertEquals(calls.at(-1)?.name, "transfer_verified_subscriptions");
      assertEquals(calls.at(-1)?.args.p_allowed_app_ids, ["unit-app"]);
      assertEquals(calls.at(-1)?.args.p_store, null);
      assertEquals(calls.at(-1)?.args.p_environment, null);
    });
    await t.step("out-of-order timestamps reach the database unchanged", async () => {
      await deliver({ id: "newer", event_timestamp_ms: 2_000_000 });
      await deliver({ id: "older", event_timestamp_ms: 1_000_000 });
      assertEquals(calls.at(-2)?.args.p_event_at, new Date(2_000_000).toISOString());
      assertEquals(calls.at(-1)?.args.p_event_at, new Date(1_000_000).toISOString());
    });
    await t.step("duplicate deliveries preserve identity and database stale result", async () => {
      result = "stale";
      const response = await deliver();
      assertEquals(await response.json(), { ok: true, result: "stale" });
      assertEquals(calls.at(-1)?.args.p_event_id, "unit-transfer");
    });
    for (
      const [name, extra, options, expected] of [
        ["replayed signed delivery", {}, { age: 601 }, 401],
        ["wrong authorization", {}, { auth: "wrong" }, 401],
        ["changed signed body", {}, { tamper: true }, 401],
        ["other app", { app_id: "other-app" }, {}, 200],
        ["Test Store", { store: "TEST_STORE" }, {}, 200],
        ["promotional store", { store: "PROMOTIONAL" }, {}, 200],
        ["invalid environment", { environment: "other" }, {}, 422],
      ] as const
    ) {
      await t.step(name, async () => {
        const count = calls.length;
        assertEquals((await deliver(extra, options)).status, expected);
        assertEquals(calls.length, count);
      });
    }
    await t.step(
      "non-grant diagnostics retain only a stable opaque event correlation",
      async () => {
        const logs: unknown[][] = [];
        console.error = (...args) => logs.push(args);
        console.warn = console.error;
        result = "invalid";
        for (const type of ["TRANSFER", "INITIAL_PURCHASE"]) {
          logs.length = 0;
          const extra = {
            type,
            id: "SENTINEL_STUDENT_CONTENT",
            app_id: "unit-app",
            store: "APP_STORE",
            environment: "Production",
            original_transaction_id: "SENTINEL_STUDENT_CONTENT",
            product_id: "SENTINEL_STUDENT_CONTENT",
            app_user_id: base.transferred_from[0],
          };
          assertEquals((await deliver(extra)).status, 200);
          assertEquals((await deliver(extra)).status, 200);
          const fields = logs.map((args) => args[1] as { correlation?: string } | undefined);
          assertEquals(/^[a-f0-9]{64}$/.test(fields[0]?.correlation ?? ""), true);
          assertEquals(fields[0]?.correlation, fields[1]?.correlation);
          assertEquals(JSON.stringify(logs).includes("SENTINEL_STUDENT_CONTENT"), false);
          assertEquals(JSON.stringify(logs).includes(base.transferred_from[0]), false);
        }
        console.error = originalError;
        console.warn = originalWarn;
      },
    );
    await t.step("missing app configuration remains closed", async () => {
      Deno.env.delete("REVENUECAT_APP_IDS");
      const count = calls.length;
      assertEquals((await deliver()).status, 503);
      assertEquals(calls.length, count);
    });
  } finally {
    console.error = originalError;
    console.warn = originalWarn;
    Deno.serve = originalServe;
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
});
