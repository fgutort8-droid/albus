import { assertEquals } from "jsr:@std/assert@1";

Deno.test("provider response accounting survives unusable results without logging provider text", async (t) => {
  const env = {
    SUPABASE_URL: "https://unit.invalid",
    SUPABASE_ANON_KEY: "unit-anon",
    SUPABASE_SERVICE_ROLE_KEY: "unit-service",
    ANTHROPIC_API_KEY: "unit-provider",
  };
  const previous = Object.fromEntries(Object.keys(env).map((k) => [k, Deno.env.get(k)]));
  const originalFetch = globalThis.fetch;
  const originalServe = Deno.serve;
  const originalError = console.error;
  const handlers: ((r: Request) => Promise<Response>)[] = [];
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const logs: string[] = [];
  let mode = "refusal";
  let providerCalls = 0;
  const usage = {
    input_tokens: 90000,
    output_tokens: 20,
    cache_creation_input_tokens: 4000,
    cache_read_input_tokens: 5000,
  };
  const reply = (value: unknown, status = 200) =>
    new Response(JSON.stringify(value), {
      status,
      headers: { "content-type": "application/json" },
    });
  try {
    for (const [k, v] of Object.entries(env)) Deno.env.set(k, v);
    console.error = (...args) => logs.push(args.map(String).join(" "));
    Deno.serve = ((h: (r: Request) => Promise<Response>) => {
      handlers.push(h);
      return {};
    }) as typeof Deno.serve;
    globalThis.fetch = async (input, init) => {
      const request = new Request(input, init);
      const url = new URL(request.url);
      if (url.hostname === "api.anthropic.com") {
        providerCalls++;
        if (mode === "transport") throw new Error("SENTINEL_STUDENT_CONTENT");
        if (["rejected", "rate-limit", "server-error"].includes(mode)) {
          return reply({
            type: "error",
            error: { type: "invalid_request_error", message: "SENTINEL_STUDENT_CONTENT" },
          }, mode === "rate-limit" ? 429 : mode === "server-error" ? 503 : 400);
        }
        return reply({
          id: "unit",
          type: "message",
          role: "assistant",
          model: "unit-model",
          content: mode === "empty" ? [] : [{
            type: "text",
            text: mode === "malformed" ? "SENTINEL_STUDENT_CONTENT" : '{"ok":true}',
          }],
          stop_reason: mode === "refusal"
            ? "refusal"
            : mode === "truncated"
            ? "max_tokens"
            : "end_turn",
          usage: mode === "invalid-usage" ? { ...usage, input_tokens: -1 } : usage,
        });
      }
      if (url.hostname !== "unit.invalid") throw new Error("Unexpected network destination");
      if (url.pathname === "/auth/v1/user") {
        return reply({ id: "a9700000-0000-4000-8000-000000000001", is_anonymous: true });
      }
      if (url.pathname === "/rest/v1/plans") return reply({ active_tasks: null });
      if (url.pathname === "/rest/v1/gradings") return reply(null);
      if (url.pathname.startsWith("/rest/v1/rpc/")) {
        const name = url.pathname.split("/").at(-1)!;
        calls.push({ name, args: await request.json() });
        return reply(
          name === "effective_tier"
            ? "pro"
            : name === "check_and_record_ai_usage"
            ? "a9700000-0000-4000-8000-000000000002"
            : true,
        );
      }
      throw new Error("Unexpected request path: " + url.pathname);
    };
    await import("../breakdown/index.ts");
    await import("../grade/index.ts");
    for (const endpoint of [0, 1]) {
      for (
        const failure of [
          "refusal",
          "malformed",
          "empty",
          ...(endpoint === 1 ? ["truncated"] : []),
          "transport",
          "rejected",
          "rate-limit",
          "server-error",
        ]
      ) {
        await t.step(`${endpoint === 0 ? "planning" : "grading"}: ${failure}`, async () => {
          mode = failure;
          calls.length = 0;
          logs.length = 0;
          providerCalls = 0;
          const body = endpoint === 0
            ? {
              title: "Unit assignment",
              task_type: "essay",
              deadline: "2027-01-01",
              estimated_minutes: 60,
            }
            : { work: "Synthetic student work for a local accounting test. ".repeat(10) };
          const response = await handlers[endpoint](
            new Request("https://unit.invalid/function", {
              method: "POST",
              headers: { Authorization: "Bearer unit-token", "content-type": "application/json" },
              body: JSON.stringify(body),
            }),
          );
          assertEquals(response.status >= 400, true);
          assertEquals((await response.text()).includes("SENTINEL_STUDENT_CONTENT"), false);
          assertEquals(providerCalls, 1, "one reservation must permit only one provider request");
          const writes = calls.filter((c) => c.name === "finalize_ai_usage");
          assertEquals(writes.length, 1);
          const known = !["transport", "rejected", "rate-limit", "server-error"].includes(failure);
          assertEquals(writes[0].args.p_state, "failed");
          assertEquals(writes[0].args.p_input_tokens, known ? 90000 : null);
          assertEquals(writes[0].args.p_output_tokens, known ? 20 : null);
          assertEquals(writes[0].args.p_cache_write_tokens, known ? 4000 : null);
          assertEquals(writes[0].args.p_cache_read_tokens, known ? 5000 : null);
          assertEquals(JSON.stringify(writes).includes("SENTINEL_STUDENT_CONTENT"), false);
          assertEquals(logs.join(" ").includes("SENTINEL_STUDENT_CONTENT"), false);
        });
      }
    }
    await t.step("invalid usage retains the reservation instead of recording zero", async () => {
      mode = "invalid-usage";
      calls.length = 0;
      const response = await handlers[0](
        new Request("https://unit.invalid/function", {
          method: "POST",
          headers: { Authorization: "Bearer unit-token", "content-type": "application/json" },
          body: JSON.stringify({
            title: "Unit assignment",
            deadline: "2027-01-01",
            estimated_minutes: 60,
          }),
        }),
      );
      assertEquals(response.status, 502);
      const write = calls.find((c) => c.name === "finalize_ai_usage")!;
      assertEquals(write.args.p_input_tokens, null);
      assertEquals(write.args.p_output_tokens, null);
      assertEquals(write.args.p_failure_code, "INVALID_PROVIDER_USAGE");
    });
    await t.step("valid structured output retains all token fields", async () => {
      mode = "success";
      const { generateBreakdown } = await import("../_shared/anthropic.ts");
      const result = await generateBreakdown("unit-model", "Synthetic system", "Synthetic task");
      assertEquals(result.raw, { ok: true });
      assertEquals([
        result.inputTokens,
        result.outputTokens,
        result.cacheWriteTokens,
        result.cacheReadTokens,
      ], [90000, 20, 4000, 5000]);
    });
  } finally {
    globalThis.fetch = originalFetch;
    Deno.serve = originalServe;
    console.error = originalError;
    for (const [k, v] of Object.entries(previous)) {
      v === undefined ? Deno.env.delete(k) : Deno.env.set(k, v);
    }
  }
});
