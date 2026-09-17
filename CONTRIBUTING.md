# Working on Albus

## First, install the hooks

```bash
./scripts/install-hooks.sh
```

**Do this in every clone.** `core.hooksPath` is local repository config — it is
not committed and does not survive `git clone`, so a fresh clone has no
protection against pushing straight to `main`. The script is idempotent.

A server-side workflow (`main guard`) also fails any commit that reaches `main`
without a pull request. It cannot prevent the push — nothing on this plan can —
but it makes one loud instead of silent.

## The one rule

**`main` is protected.** No direct commits, no direct pushes, no force-pushes.
Every change reaches `main` through a reviewed pull request.

This is not ceremony. Production is deployed from `main`, and a bad migration
is the one class of mistake that is genuinely hard to undo.

**Nothing deploys automatically, by design.** There is no deploy workflow, and
merging changes nothing in production. The owner applies each deploy by hand,
after the merge (see "How a migration reaches production" below).

A `Deploy migrations` workflow used to exist and failed on all twelve of its
runs, since the three secrets it needed were never set. It was removed on
10 Sep 2026: a permanently red check trains everyone to ignore CI, and the
version of it that *worked* would have been worse than the version that did
not — see the history section below.

## Branch names

| Prefix      | For                                  |
|-------------|--------------------------------------|
| `feat/`     | new functionality                    |
| `fix/`      | bug fixes                            |
| `db/`       | migrations and schema work           |
| `chore/`    | tooling, CI, dependencies            |
| `docs/`     | documentation only                   |

## The loop

```bash
git checkout main && git pull
git checkout -b db/add-streaks-table

# ... work ...

git add -A
git commit -m "Add streaks table with owner-only RLS"
git push -u origin db/add-streaks-table
gh pr create --fill
```

Then: CI green → self-review the diff → merge → delete the branch.

## Migrations are append-only

Once a migration has been applied to the live database it is **history**.
Never edit it, never delete it, never renumber it. Fix forward with a new file.
CI enforces this on every PR.

Naming: `YYYYMMDDHHMMSS_short_description.sql`, the form
`supabase migration new` creates. The timestamp is the version production
records, so it must be later than every existing one. `0001`–`0037` predate
this and keep their names.

## Before you open a PR

The PR template carries the full checklist. The three that matter most:

1. New public table? It needs `enable row level security`, the minimum grants
   the app actually uses, and allow-and-deny policy tests for every granted
   operation. Server-owned ledgers should have no client table grants at all.
2. New user-owned table? It needs an index on `user_id` — RLS filters on it
   for every single query.
3. Run `supabase test db --local` and
   `scripts/security-concurrency-local.sh`. Both must pass.

## How a migration reaches production

After its pull request merges, the owner runs `supabase db push`. It applies
every migration whose version production has not recorded, and records each
one under its filename version. The owner runs it from a deploy script written
for that change. The script has a dry-run mode, checks each step before the
next, and stops at the first problem. When a change also touches an Edge
Function, its pull request says which goes first.

**Never apply a migration through the dashboard's SQL editor or the MCP
`apply_migration` tool.** Both record the moment of application as the version
instead of the filename's, and `db push` would later apply that migration a
second time. That is how the history drifted, twice (below).

Don't reach into the database by hand either. Two migrations were once applied
by hand and never written to a file, so the repo could not rebuild the
database it described. They were recovered from
`supabase_migrations.schema_migrations` and are now `0016` and `0017`. If you
ever have to apply something directly, write the file in the same change — a
migration that exists only in the database is a migration nobody can review,
roll forward, or reproduce.

### The history table drifted, and was repaired on 16 Sep 2026

It happened again, in the other direction. Every migration from `0030` to
`20260901200000` was applied by hand through the dashboard, which stamps its
own timestamp, so the recorded `version` stopped matching the filename:

| File | Recorded as |
| --- | --- |
| `0030_grading_free_quota.sql` … `0037_chat_becomes_pro_only.sql` | `20260826172040` … `20260827210655` |
| `20260830104329_production_financial_safety.sql` | `20260901192220` |
| `20260830114547_close_direct_write_and_request_abuse.sql` | `20260901192432` |
| `20260831174227_drop_scaffold_course_templates.sql` | `20260901225530` |
| `20260901200000_ib_student_context.sql` | **not recorded at all** |

The schema was fine; only the bookkeeping was wrong. It still mattered: `db
push` applies every migration whose version it does not recognise, and it did
not recognise thirteen of them, so it would have replayed the entire security
hardening against a database that already had it. That is why `db push` was
off limits until then, and why the deploy workflow was removed rather than
fixed.

`scripts/deploy-2026-09-05.sql` repaired the history on 16 Sep 2026. It also
applied the three migrations still pending. `supabase db push` then applied the
rest. Every migration is now recorded under its filename version. The
pre-repair table is kept as
`supabase_migrations.schema_migrations_backup_20260905`.
