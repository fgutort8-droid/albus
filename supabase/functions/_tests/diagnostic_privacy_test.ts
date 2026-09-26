import { assertEquals } from "jsr:@std/assert@1";
import { errorResponse, mapPostgresError } from "../_shared/http.ts";
import { assertCanGeneratePlan, finalizeAIUsage } from "../_shared/quota.ts";

import { adminClient } from "../_shared/auth.ts";
import { loadPersonalRubric, resolveGradingRubric } from "../_shared/rubric.ts";

Deno.test("diagnostics retain categories without arbitrary error details", async () => {
  const sentinel = "SENTINEL_STUDENT_CONTENT";
  const logs: string[] = [];
  const originalError = console.error;
  const originalWarn = console.warn;
  const originalFetch = globalThis.fetch;
  const names = ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"];
  const previous = names.map((name) => Deno.env.get(name));
  let requests = 0;
  try {
    Deno.env.set(names[0], "https://diagnostic-unit.invalid");
    Deno.env.set(names[1], "unit-service");
    console.error = (...args) =>
      logs.push(
        JSON.stringify(args, (_, value) =>
          value instanceof Error ? { message: value.message } : value),
      );
    console.warn = console.error;
    globalThis.fetch = () => {
      requests++;
      return Promise.resolve(
        new Response(JSON.stringify({ message: sentinel, details: sentinel, code: "XX000" }), {
          status: 500,
          headers: { "content-type": "application/json" },
        }),
      );
    };
    assertEquals(errorResponse(new Error(sentinel)).status, 500);
    assertEquals(mapPostgresError(sentinel).code, "INTERNAL_ERROR");
    assertEquals(
      await finalizeAIUsage("a9800000-0000-4000-8000-000000000001", "failed", 0, 0, "TEST"),
      false,
    );
    assertEquals(requests, 3);
    const db = adminClient();
    assertEquals(await loadPersonalRubric(db, "unit-rubric"), null);
    assertEquals(await resolveGradingRubric(db, "unit-assignment"), {
      rubric: null,
      basis: "blind",
    });
    await assertCanGeneratePlan({ id: "unit-user", isAnonymous: true, db });
    assertEquals(logs.length, 6);
    assertEquals(logs.join(" ").includes(sentinel), false);
    assertEquals(mapPostgresError("ALLOWANCE_WEEKLY").code, "ALLOWANCE_WEEKLY");
  } finally {
    console.error = originalError;
    console.warn = originalWarn;
    globalThis.fetch = originalFetch;
    names.forEach((name, i) =>
      previous[i] === undefined ? Deno.env.delete(name) : Deno.env.set(name, previous[i]!)
    );
  }
});
