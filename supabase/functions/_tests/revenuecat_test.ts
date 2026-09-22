import { assertEquals } from "jsr:@std/assert@1";
import {
  classifySubscriptionResult,
  constantTimeEqual,
  finiteOrNull,
  isoFromMilliseconds,
  isUserID,
  normaliseRevenueCatEnvironment,
  revenueCatAppIsAllowed,
  revokesImmediately,
  storeCanGrant,
  userIDsIn,
  verifyRevenueCatSignature,
} from "../_shared/revenuecat.ts";

async function signature(
  raw: Uint8Array,
  timestamp: number,
  secret: string,
): Promise<string> {
  const prefix = new TextEncoder().encode(`${timestamp}.`);
  const signed = new Uint8Array(prefix.length + raw.length);
  signed.set(prefix);
  signed.set(raw, prefix.length);
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, signed));
  return [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.test("RevenueCat HMAC accepts the exact signed bytes", async () => {
  const now = 1_800_000_000_000;
  const timestamp = Math.floor(now / 1000);
  const raw = new TextEncoder().encode('{"event":{"id":"evt_1"}}');
  const secret = "test-signing-secret";
  const digest = await signature(raw, timestamp, secret);
  assertEquals(
    await verifyRevenueCatSignature(raw, `t=${timestamp},v1=${digest}`, secret, now),
    true,
  );
});

Deno.test("RevenueCat HMAC rejects a changed body and wrong secret", async () => {
  const now = 1_800_000_000_000;
  const timestamp = Math.floor(now / 1000);
  const original = new TextEncoder().encode('{"event":{"id":"evt_1"}}');
  const changed = new TextEncoder().encode('{"event":{"id":"evt_2"}}');
  const digest = await signature(original, timestamp, "right-secret");
  const header = `t=${timestamp},v1=${digest}`;
  assertEquals(
    await verifyRevenueCatSignature(changed, header, "right-secret", now),
    false,
  );
  assertEquals(
    await verifyRevenueCatSignature(original, header, "wrong-secret", now),
    false,
  );
});

Deno.test("RevenueCat HMAC rejects stale and malformed delivery timestamps", async () => {
  const now = 1_800_000_000_000;
  const stale = Math.floor(now / 1000) - 301;
  const raw = new TextEncoder().encode("{}");
  const digest = await signature(raw, stale, "secret");
  assertEquals(
    await verifyRevenueCatSignature(raw, `t=${stale},v1=${digest}`, "secret", now),
    false,
  );
  assertEquals(await verifyRevenueCatSignature(raw, "garbage", "secret", now), false);
});

Deno.test("RevenueCat timestamps never turn invalid data into no-expiry", () => {
  assertEquals(isoFromMilliseconds(null), null);
  assertEquals(isoFromMilliseconds(Number.NaN), null);
  assertEquals(isoFromMilliseconds(-1), null);
  assertEquals(isoFromMilliseconds(1_800_000_000_000), "2027-01-15T08:00:00.000Z");
});

Deno.test("RevenueCat environment accepts only the documented enum", () => {
  assertEquals(normaliseRevenueCatEnvironment("PRODUCTION"), "Production");
  assertEquals(normaliseRevenueCatEnvironment("sandbox"), "Sandbox");
  assertEquals(normaliseRevenueCatEnvironment("preview"), null);
  assertEquals(normaliseRevenueCatEnvironment(null), null);
});

Deno.test("constant-time comparator still compares value and length", () => {
  assertEquals(constantTimeEqual("abc", "abc"), true);
  assertEquals(constantTimeEqual("abc", "abd"), false);
  assertEquals(constantTimeEqual("abc", "abc0"), false);
});

Deno.test("only expiration revokes immediately", () => {
  assertEquals(revokesImmediately("EXPIRATION"), true);
  assertEquals(revokesImmediately("SUBSCRIPTION_PAUSED"), false);
  assertEquals(revokesImmediately("CANCELLATION"), false);
});

Deno.test("RevenueCat events must belong to an explicitly allowed app", () => {
  assertEquals(revenueCatAppIsAllowed("app_albus_ios", "app_albus_ios"), true);
  assertEquals(
    revenueCatAppIsAllowed("app_albus_ios", "app_other, app_albus_ios"),
    true,
  );
  assertEquals(revenueCatAppIsAllowed("app_other", "app_albus_ios"), false);
  assertEquals(revenueCatAppIsAllowed("app_albus_ios", ""), false);
  assertEquals(revenueCatAppIsAllowed(null, "app_albus_ios"), false);
});

Deno.test("only a TRANSFER may omit its app id, and a named app must still be ours", () => {
  const allowMissing = { allowMissing: true };
  assertEquals(revenueCatAppIsAllowed(undefined, "app_albus_ios", allowMissing), true);
  assertEquals(revenueCatAppIsAllowed(null, "app_albus_ios", allowMissing), true);
  assertEquals(revenueCatAppIsAllowed("app_other", "app_albus_ios", allowMissing), false);
  assertEquals(revenueCatAppIsAllowed("", "app_albus_ios", allowMissing), false);
  // An unconfigured webhook refuses even a transfer.
  assertEquals(revenueCatAppIsAllowed(undefined, "", allowMissing), false);
  assertEquals(revenueCatAppIsAllowed(undefined, "app_albus_ios"), false);
});

Deno.test("only App Store purchases can change a plan", () => {
  assertEquals(storeCanGrant("APP_STORE"), true);
  assertEquals(storeCanGrant("MAC_APP_STORE"), true);
  // The Test Store makes purchases that cost nothing.
  for (const store of ["TEST_STORE", "PROMOTIONAL", "PLAY_STORE", "STRIPE", "app_store", "", null, undefined]) {
    assertEquals(storeCanGrant(store), false, String(store));
  }
});

Deno.test("a transfer names Albus accounts only, once each", () => {
  const id = "3f2c1b7e-9a4d-4c5e-8f1a-2b3c4d5e6f70";
  assertEquals(isUserID(id), true);
  assertEquals(isUserID("$RCAnonymousID:8b1f0f2e8f6a4c1e"), false);
  assertEquals(
    userIDsIn(["$RCAnonymousID:8b1f0f2e8f6a4c1e", id, id.toUpperCase(), 42, null]),
    [id],
  );
  assertEquals(userIDsIn("not a list"), []);
  assertEquals(userIDsIn(undefined), []);
});

Deno.test("prices are numbers or nothing", () => {
  assertEquals(finiteOrNull(9.99), 9.99);
  assertEquals(finiteOrNull(-9.99), -9.99);
  assertEquals(finiteOrNull(0), 0);
  assertEquals(finiteOrNull("9.99"), null);
  assertEquals(finiteOrNull(Number.POSITIVE_INFINITY), null);
  assertEquals(finiteOrNull(Number.NaN), null);
  assertEquals(finiteOrNull(null), null);
});

Deno.test("an unmapped product is loud and retryable, not a silent 200", () => {
  // The case that matters: the purchase was real and the signature verified,
  // but no `subscription_products` row mapped it to a tier. Apple has taken the
  // money. Acknowledging that with 200 is how it stayed invisible.
  const unmapped = classifySubscriptionResult("unknown_product");
  assertEquals(unmapped.retry, true);
  assertEquals(unmapped.severity, "error");
});

Deno.test("outcomes a retry cannot fix are never retried", () => {
  // `conflict` needs a person; `invalid` will not improve on redelivery.
  for (const result of ["conflict", "invalid"]) {
    assertEquals(classifySubscriptionResult(result).retry, false, result);
    assertEquals(classifySubscriptionResult(result).severity, "error", result);
  }
});

Deno.test("ordinary outcomes stay quiet so the loud ones keep meaning something", () => {
  for (const result of ["active_pro", "active_plus", "inactive", "stale", "sandbox_ignored"]) {
    assertEquals(classifySubscriptionResult(result), { retry: false, severity: "none" }, result);
  }
  // A transaction RevenueCat has not yet attached to a buyer is normal and
  // resolves itself on a later event — visible, not alarming.
  assertEquals(classifySubscriptionResult("unlinked"), { retry: false, severity: "warn" });
  // An unrecognised or absent result must not accidentally become retryable.
  assertEquals(classifySubscriptionResult(null), { retry: false, severity: "none" });
  assertEquals(classifySubscriptionResult("something_new"), { retry: false, severity: "none" });
});
