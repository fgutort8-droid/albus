# The merge gate

The owner's rule, 24 September 2026:

> Nothing merges until Greptile scores the pull request's **latest commit**
> 5/5.

`.github/workflows/greptile-gate.yml` enforces it, via
`scripts/greptile-gate.sh`.

## Why Greptile's own check is not enough

Greptile posts a **Greptile Review** status check. It reports success at 4/5:
it means "I finished reading", not "this is good". Verified on this repo —
commit `278b49f` scored 4/5 with two open findings and its check was green:

```
278b49f → success | Greptile Review | 6 files reviewed, 2 comments added.
0cc0c73 → success | Greptile Review | 6 files reviewed, 0 comments added.
```

So the score has to be read out of the summary comment, which is what the
script does.

## What the gate does

1. Reads the pull request's head commit.
2. Reads Greptile's summary comment, and **only** Greptile's: it accepts the
   score solely from a comment whose author is `greptile-apps[bot]` **and**
   whose `user.type` is `Bot`. A pull request author could otherwise paste a
   forged `<!-- greptile_confidence_score:5 -->` marker into a comment of their
   own; GitHub reserves the `[bot]` suffix and sets `type` itself, so neither
   can be claimed by a person.
3. Requires the reviewed commit to equal the head commit. A 5/5 earned before
   the last push does not count.
4. Passes only at 5/5. Otherwise it fails, and says what to do.

It **fails closed**, always: no review yet, a review of an older commit, an
unparsable score, Greptile down, or Greptile out of its 50 free monthly
reviews all fail. A gate that passes when it cannot tell is worse than no gate,
because people trust it.

It waits up to 10 minutes for a review to appear, because Greptile takes about
1–3 minutes after a push.

## 5/5 is required, never sufficient

This enforces a floor, not a verdict. On this repo Greptile gave **5/5 "safe to
merge"** to PR #6 while:

- its privacy policy omitted Cloudflare, which the app sends student data to —
  a gap this repo's own `docs/app-store/app-privacy.md` names for that exact
  pull request; and
- the pull request targeted `payments/app`, a branch already squash-merged into
  `main`, so merging it would have changed nothing on `main`.

CI, and a human reading the diff, still decide.

## Switching it on

The workflow reports a check. Only **branch protection** makes a failing check
block a merge. One command, run by the repo owner, after this has merged to
`main`:

```bash
gh api -X PUT repos/fgutort8-droid/albus/branches/main/protection \
  --input docs/merge-gate-protection.json
```

`enforce_admins` is `true` in that file on purpose: the rule is "from anyone",
and the owner is an admin. Without it, an admin merge slips straight past.

That file also makes the six CI checks required, not just this gate — merging
red CI was possible until now — and forbids force-pushing or deleting `main`.
`strict` is `false`, so a pull request does not have to be rebased every time
`main` moves; the gate is about review quality, not branch freshness.

### If it ever locks you out

`enforce_admins: true` means a broken gate blocks **everyone**, including the
owner, including the pull request that would fix it. That is the point, and it
is also the failure mode to know about. If Greptile is removed, runs out of
credits, or this script breaks, nothing merges until protection is lifted:

```bash
gh api -X DELETE repos/fgutort8-droid/albus/branches/main/protection
```

Merge what is needed, then switch it back on with the PUT above. Do not leave
it off.

To check what is in force:

```bash
gh api repos/fgutort8-droid/albus/branches/main/protection \
  --jq '{checks: .required_status_checks.contexts, admins: .enforce_admins.enabled}'
```

To lift it (needs the same admin rights):

```bash
gh api -X DELETE repos/fgutort8-droid/albus/branches/main/protection
```

## When it fails

- **Below 5/5** — fix the valid findings and push. If a finding is wrong, reply
  on its thread with evidence and comment `@greptileai` to re-review, then
  re-run the check. On PR #10 that moved 4/5 to 5/5, because the finding was
  genuinely answered. **Never change the code just to raise the score.**
- **No review yet** — comment `@greptileai` on the pull request, then re-run.
- **Greptile down or out of credits** — merging waits. That is the rule
  working, not a fault.

## Testing a change to the gate

The script takes a pull request number and can be run locally:

```bash
WAIT_SECONDS=0 scripts/greptile-gate.sh 10          # a real 5/5 → passes
REQUIRED_SCORE=6 WAIT_SECONDS=0 scripts/greptile-gate.sh 10   # → fails
WAIT_SECONDS=0 scripts/greptile-gate.sh 5           # never reviewed → fails
GH_TOKEN=invalid WAIT_SECONDS=0 scripts/greptile-gate.sh 10   # → fails closed
```

`REQUIRED_SCORE` exists so the failure path can be proved against a real 5/5
pull request. The workflow never sets it, so CI always demands 5.
