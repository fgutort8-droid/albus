// revenuecat-webhook/index.ts
//
// RevenueCat tells us what a student bought. This is the ONLY path by which
// anyone becomes Plus or Pro.
//
// This endpoint is PUBLIC — RevenueCat cannot present a user JWT — so the
// shared Authorization secret and RevenueCat's signed raw body are both
// checked before any event field is trusted.
//
// Deploy with --no-verify-jwt. That is deliberate and safe here precisely
// because authentication happens in-process, against a secret the client never
// sees.
//
// Nothing about tier is decided here. The body says what was bought and when
// it expires; `apply_subscription_state` decides what that means, which is
// also where the stolen-subscription check lives. Whether Apple's sandbox
// purchases count is decided there too, by `app_config.allow_sandbox_subscriptions`:
// App Review and TestFlight buy in the sandbox against this backend.

import { adminClient } from "../_shared/auth.ts";
import { readRawBody } from "../_shared/body.ts";
import { errorResponse, HttpError, jsonResponse } from "../_shared/http.ts";
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

const MAX_BODY_BYTES = 65_536;

/// Events that change entitlement. Anything else is acknowledged and ignored:
/// returning 200 stops RevenueCat retrying something we deliberately skipped.
///
/// PRODUCT_CHANGE is ignored on purpose. On the App Store an upgrade arrives
/// as PRODUCT_CHANGE followed by a RENEWAL for the new product, and a
/// downgrade takes effect at the next renewal; both RENEWALs carry the product
/// that is actually in force, so acting on PRODUCT_CHANGE could only jump the
/// gun. BILLING_ISSUE is ignored because Albus offers no billing grace period.
const HANDLED = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "CANCELLATION",
  "UNCANCELLATION",
  "EXPIRATION",
  "SUBSCRIPTION_PAUSED",
  "SUBSCRIPTION_EXTENDED",
  "REFUND_REVERSED",
  "TRANSFER",
]);

/// Events that can move money. `record_subscription_revenue` decides which of
/// them actually did — a cancellation is only a refund when support issued one.
const MAY_CARRY_REVENUE = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "CANCELLATION",
  "REFUND_REVERSED",
]);

interface RevenueCatEvent {
  type?: unknown;
  id?: unknown;
  app_id?: unknown;
  store?: unknown;
  event_timestamp_ms?: unknown;
  app_user_id?: unknown;
  original_app_user_id?: unknown;
  transferred_from?: unknown;
  transferred_to?: unknown;
  product_id?: unknown;
  environment?: unknown;
  purchased_at_ms?: unknown;
  expiration_at_ms?: unknown;
  cancel_reason?: unknown;
  original_transaction_id?: unknown;
  transaction_id?: unknown;
  price?: unknown;
  tax_percentage?: unknown;
  commission_percentage?: unknown;
}

/**
 * Constant-time string comparison.
 *
 * `a === b` on secrets leaks length and prefix through timing. The difference
 * is small over the internet but free to avoid, and this is the single check
 * standing between a stranger and premium for everyone.
 */
function requireAuthorised(req: Request): void {
  const expected = Deno.env.get("REVENUECAT_WEBHOOK_SECRET") ?? "";
  if (!expected) {
    // Refuse rather than accept-everything. An unconfigured secret must never
    // mean an open endpoint that grants entitlements.
    console.error("REVENUECAT_WEBHOOK_SECRET is not set; rejecting.");
    throw new HttpError(503, "NOT_CONFIGURED");
  }
  const provided = req.headers.get("Authorization") ?? "";
  if (!constantTimeEqual(provided, expected)) {
    throw new HttpError(401, "UNAUTHORISED");
  }
}

/**
 * Verify RevenueCat's HMAC over the exact request bytes.
 *
 * The Authorization header protects the endpoint from casual forgery. HMAC
 * additionally proves the body itself is what RevenueCat signed, and the
 * five-minute delivery timestamp prevents a captured request being replayed
 * indefinitely. RevenueCat re-signs legitimate retries with a fresh delivery
 * timestamp while keeping the event id stable.
 */
async function requireValidSignature(req: Request, raw: Uint8Array): Promise<void> {
  const secret = Deno.env.get("REVENUECAT_WEBHOOK_SIGNING_SECRET") ?? "";
  if (!secret) {
    console.error("REVENUECAT_WEBHOOK_SIGNING_SECRET is not set; rejecting.");
    throw new HttpError(503, "NOT_CONFIGURED");
  }

  const header = req.headers.get("x-revenuecat-webhook-signature") ?? "";
  if (!await verifyRevenueCatSignature(raw, header, secret)) {
    throw new HttpError(401, "UNAUTHORISED");
  }
}

/** A non-empty string, truncated, or null. */
function asString(v: unknown, max = 255): string | null {
  return typeof v === "string" && v.length > 0 ? v.slice(0, max) : null;
}

/**
 * A restore on another account. RevenueCat has already moved the purchase and
 * sends this only for the destination; the database moves our copy to match.
 */
async function applyTransfer(
  event: RevenueCatEvent,
  eventID: string,
  eventAt: string,
  configuredAppIDs: string,
): Promise<Response> {
  const to = userIDsIn(event.transferred_to);
  const from = userIDsIn(event.transferred_from).filter((id) => !to.includes(id));
  if (to.length !== 1) {
    // No Albus account, or more than one, to receive it. Nothing here can
    // decide between them, and a redelivery would say the same thing.
    console.error("transfer without exactly one Albus destination", {
      destinations: to.length,
    });
    return jsonResponse({ ok: true, ignored: "transfer_destination" });
  }

  const { data, error } = await adminClient().rpc("transfer_verified_subscriptions", {
    p_from: from,
    p_to: to[0],
    p_event_id: eventID,
    p_event_at: eventAt,
    p_allowed_app_ids: configuredAppIDs.split(",").map((id) => id.trim()).filter(Boolean),
    p_app_id: event.app_id ?? null,
    p_store: event.store ?? null,
    p_environment: event.environment == null
      ? null
      : normaliseRevenueCatEnvironment(event.environment),
  });
  if (error) {
    console.error("transfer_subscriptions failed");
    throw new HttpError(500, "INTERNAL_ERROR");
  }
  if (data === "invalid") {
    // The destination account does not exist any more.
    console.error("transfer refused");
  }
  return jsonResponse({ ok: true, result: data ?? "unknown" });
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");

    // Authenticate BEFORE reading the body, so an unauthorised caller cannot
    // make us parse arbitrary input.
    requireAuthorised(req);

    const raw = await readRawBody(req, MAX_BODY_BYTES);
    await requireValidSignature(req, raw);

    let payload: { event?: RevenueCatEvent };
    try {
      payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw));
    } catch {
      throw new HttpError(400, "INVALID_JSON");
    }

    const event = payload.event ?? {};
    const type = asString(event.type, 64) ?? "";
    if (!HANDLED.has(type)) {
      // Acknowledged, deliberately ignored.
      return jsonResponse({ ok: true, ignored: type || "unknown" });
    }

    // A RevenueCat project may contain several apps and a webhook can be
    // configured for all of them. A valid HMAC proves RevenueCat sent the
    // event; it does not prove the event belongs to Albus. Product ids alone
    // are not a safe namespace, so entitlement-changing events must also name
    // an explicitly configured Albus app id.
    const configuredAppIDs = Deno.env.get("REVENUECAT_APP_IDS") ?? "";
    if (!configuredAppIDs.trim()) {
      console.error("REVENUECAT_APP_IDS is not set; rejecting.");
      throw new HttpError(503, "NOT_CONFIGURED");
    }
    if (
      !revenueCatAppIsAllowed(event.app_id, configuredAppIDs, {
        allowMissing: type === "TRANSFER",
      })
    ) {
      console.warn("ignoring RevenueCat event for another app", { type });
      return jsonResponse({ ok: true, ignored: "app" });
    }

    const eventID = asString(event.id);
    const eventAt = isoFromMilliseconds(event.event_timestamp_ms);
    if (!eventID || !eventAt) throw new HttpError(422, "INVALID_EVENT_IDENTITY");

    // Customer transfers can omit purchase metadata. Explicit metadata still
    // passes the same gates; absent metadata only routes purchases whose stored
    // app and Apple-store provenance matches this configured integration.
    if (type === "TRANSFER") {
      if (event.store != null && !storeCanGrant(event.store)) {
        return jsonResponse({ ok: true, ignored: "store" });
      }
      if (event.environment != null && !normaliseRevenueCatEnvironment(event.environment)) {
        throw new HttpError(422, "INVALID_ENVIRONMENT");
      }
      return await applyTransfer(event, eventID, eventAt, configuredAppIDs);
    }

    // Only the App Store takes real money. A Test Store purchase is free to
    // make and must never reach a plan.
    if (!storeCanGrant(event.store)) {
      console.warn("ignoring event from a store that cannot grant", {
        type,
      });
      return jsonResponse({ ok: true, ignored: "store" });
    }

    const environment = normaliseRevenueCatEnvironment(event.environment);
    if (!environment) throw new HttpError(422, "INVALID_ENVIRONMENT");

    // The Supabase user id. RevenueCat is configured to use it as app_user_id,
    // which is what removes Apple's "notification about a user we cannot
    // identify" case. Anything that is not a UUID is not one of our users.
    const appUserID = asString(event.app_user_id) ?? asString(event.original_app_user_id);
    const userID = isUserID(appUserID) ? appUserID : null;

    // The stable identity of the subscription across renewals.
    const originalID = asString(event.original_transaction_id);
    if (!originalID) throw new HttpError(422, "NO_SUBSCRIPTION_ID");

    const expiresAt = isoFromMilliseconds(event.expiration_at_ms);
    // Only EXPIRATION means access ends now. CANCELLATION runs to the paid
    // period's expiry, and SUBSCRIPTION_PAUSED merely schedules a pause at that
    // boundary. RevenueCat sends EXPIRATION when either has actually ended.
    const revokedAt = revokesImmediately(type) ? new Date().toISOString() : null;
    const productID = asString(event.product_id);

    const admin = adminClient();
    const { data, error } = await admin.rpc("apply_verified_subscription_state", {
      p_original_transaction_id: originalID,
      p_user_id: userID,
      p_latest_transaction_id: asString(event.transaction_id),
      p_product_id: productID,
      p_environment: environment,
      p_purchase_date: isoFromMilliseconds(event.purchased_at_ms),
      p_expires_at: expiresAt,
      p_revoked_at: revokedAt,
      p_event_id: eventID,
      p_event_at: eventAt,
      p_store: event.store,
      p_app_id: event.app_id,
    });

    if (error) {
      // Do not leak the database's words to a caller we do not fully trust.
      console.error("apply_subscription_state failed");
      throw new HttpError(500, "INTERNAL_ERROR");
    }

    // What the database decided is classified in one place, so this function
    // only has to carry it out. See `classifySubscriptionResult`.
    const outcome = classifySubscriptionResult(data ?? null);
    if (outcome.severity === "error") {
      console.error("subscription event not granted", {
        result: data,
        type,
      });
    } else if (outcome.severity === "warn") {
      console.warn("subscription event needs watching", { result: data, type });
    }

    // The money, recorded whatever the plan outcome: it moved either way, and
    // it is what lets the paid AI fuse grow. Keyed on the event id, so a
    // redelivery records nothing twice.
    if (MAY_CARRY_REVENUE.has(type)) {
      const { error: revenueError } = await admin.rpc("record_subscription_revenue", {
        p_event_id: eventID,
        p_event_type: type,
        p_user_id: userID,
        p_original_transaction_id: originalID,
        p_product_id: productID,
        p_environment: environment,
        p_price_usd: finiteOrNull(event.price),
        p_tax_fraction: finiteOrNull(event.tax_percentage),
        p_commission_fraction: finiteOrNull(event.commission_percentage),
        p_cancel_reason: asString(event.cancel_reason, 64),
        p_occurred_at: eventAt,
      });
      if (revenueError) {
        // Retried: the plan change above is idempotent and will read `stale`.
        console.error("record_subscription_revenue failed");
        throw new HttpError(500, "INTERNAL_ERROR");
      }
    }

    // 503 so RevenueCat retries with backoff and marks the integration
    // unhealthy. The only retryable outcome is `unknown_product`, where the fix
    // is a row in `subscription_products` and redelivery then grants the
    // purchase on its own.
    if (outcome.retry) {
      throw new HttpError(503, "PRODUCT_NOT_MAPPED", "Product mapping unavailable.");
    }

    return jsonResponse({ ok: true, result: data ?? "unknown" });
  } catch (e) {
    return errorResponse(e);
  }
});
