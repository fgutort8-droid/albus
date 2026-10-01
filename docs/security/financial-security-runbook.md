# Payment event operations

How RevenueCat payment events are handled, and what to do when one gets stuck.

## How it works

1. The webhook checks the Authorization secret, RevenueCat's signature, the app id, the store and the environment, as before.
2. It saves the event's allowlisted arguments in `private.financial_inbox`, keyed by provider, app-id scope and event id. The raw body is never stored.
3. It processes the event in a separate transaction: `apply_verified_subscription_state` or `transfer_verified_subscriptions`, then `record_subscription_revenue`, an audit row and the "completed" mark, all or nothing. The one exception is a product missing from `subscription_products`: its revenue is recorded, and the event waits in the queue for the mapping.
4. The webhook answers 200 only for a completed event. Otherwise it answers 503: RevenueCat redelivers, and the `albus-financial-drain` job retries ready events every five minutes.

Retries back off from one minute to one hour. After ten failed attempts, about four hours, the event becomes a dead letter and stops retrying.

## Check the queue

In the Supabase SQL editor (owner session):

```sql
select state, count(*), min(received_at) from private.financial_inbox group by state;

select id, event_id, attempts, error_code, received_at
from private.financial_inbox where state in ('retry','dead') order by received_at;
```

`error_code` is a Postgres SQLSTATE. `Q0020` means the product id is missing from `subscription_products`; the money is already in `subscription_revenue`, and only the plan is waiting.

## Recover a dead letter

1. Fix the cause first. For `Q0020`, add the product mapping.
2. Requeue the event with a ticket or note reference:

   ```sql
   select public.requeue_financial_event('<inbox id>', 'INC-2026-10-01');
   ```

3. The next drain run, within five minutes, processes it. Check that its state is `completed`.

Never insert purchase events or entitlements by hand to make a check pass, and never switch signature checks off.

## Audit log

`private.financial_audit` records every change to entitlements, subscription transactions, revenue, products and `app_config`: the database role, the action, a SHA-256 hash of the account or key, the event it came from, and the before and after values of financial fields only. Updates, deletes and truncation are refused.

`reason` is `verified_provider_event` for changes made by a webhook event, `baseline_free_entitlement` for a new account's free plan, and `outside_event_processor` for anything else. An unexpected `outside_event_processor` row is worth looking into.

## Retention

A completed event keeps its payload and account for 30 days, then only its id, hash and result, which is enough to refuse a replay. Pending, retrying and dead events keep both until they are recovered, and account cleanup never removes an account that one names. Audit rows have no automatic expiry yet.

## Rotating the RevenueCat secrets

RevenueCat's signing secret stops working as soon as it is replaced, so change it in RevenueCat and in the Supabase secret together, then check that deliveries succeed. Events that fail during the switch are redelivered or stay queued, and go through once both sides match. Rotate the Authorization secret separately. Never log headers or secret values.

## Deploying and rolling back

Apply the migration first, then deploy `revenuecat-webhook`. A webhook deployed first answers 503 until the migration exists, and RevenueCat redelivers.

Don't roll back to the old webhook once events have been accepted: queued events would never be processed. Fix forward and let the queue drain.

## Tests

- `supabase test db --local` runs `supabase/tests/financial_pipeline_test.sql`.
- `python3 scripts/security/financial-concurrency.py` sends 12 simultaneous deliveries and 12 simultaneous processors at the local database and checks for exactly one effect and one revenue row. It removes its fixtures afterwards but leaves a few audit rows behind, because audit rows cannot be deleted.
- CI scans the full history for secrets with Gitleaks (`scripts/security/scan-secrets.sh`).
