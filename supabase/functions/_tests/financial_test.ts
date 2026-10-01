import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { persistFinancialEvent } from "../_shared/financial.ts";
import { HttpError } from "../_shared/http.ts";

Deno.test("financial acceptance commits before processing and failures remain closed", async (t) => {
  const names = ["SUPABASE_URL", "ALBUS_SUPABASE_SECRET_KEY"];
  const previous = names.map((name) => Deno.env.get(name));
  const originalFetch = globalThis.fetch;
  const originalLog = console.error;
  try {
    Deno.env.set("SUPABASE_URL", "https://financial.invalid");
    Deno.env.set("ALBUS_SUPABASE_SECRET_KEY", "synthetic-server-key");
    const calls: string[] = [];
    const logs: unknown[][] = [];
    console.error = (...args) => logs.push(args);
    let failure = "";
    globalThis.fetch = async (input, init) => {
      const url = new URL(String(input));
      if (url.hostname !== "financial.invalid") throw new Error("Unexpected network request");
      const operation = url.pathname.split("/").at(-1)!;
      calls.push(operation);
      if (operation === "enqueue_revenuecat_event") {
        assertEquals(JSON.parse(String(init?.body)).p_scope, "app-a,app-b");
      }
      return new Response(
        JSON.stringify(
          operation === failure
            ? { message: "SENTINEL_SECRET_PROVIDER_ERROR" }
            : operation === "enqueue_revenuecat_event"
            ? "e1000000-0000-4000-8000-000000000001"
            : failure === "retry"
            ? "retry"
            : "active_plus",
        ),
        {
          status: operation === failure ? 500 : 200,
          headers: { "Content-Type": "application/json" },
        },
      );
    };
    await t.step("durable acceptance precedes effects", async () => {
      assertEquals(await persistFinancialEvent("app-b,app-a,app-b", "event", {}), "active_plus");
      assertEquals(calls, ["enqueue_revenuecat_event", "process_financial_event"]);
    });
    for (const operation of ["enqueue_revenuecat_event", "process_financial_event", "retry"]) {
      await t.step(operation + " fails closed without sensitive diagnostics", async () => {
        calls.length = 0;
        failure = operation;
        await assertRejects(() => persistFinancialEvent("app-b,app-a", "event", {}), HttpError);
        assertEquals(calls.length, operation === "enqueue_revenuecat_event" ? 1 : 2);
        assertEquals(JSON.stringify(logs).includes("SENTINEL_SECRET_PROVIDER_ERROR"), false);
      });
    }
  } finally {
    globalThis.fetch = originalFetch;
    console.error = originalLog;
    names.forEach((name, index) => {
      if (previous[index] === undefined) Deno.env.delete(name);
      else Deno.env.set(name, previous[index]!);
    });
  }
});
