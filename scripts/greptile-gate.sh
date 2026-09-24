#!/usr/bin/env bash
# Refuses a pull request unless Greptile scored ITS LATEST COMMIT 5/5.
#
# The owner's rule, 24 Sep 2026: nothing merges below 5/5. Greptile's own
# "Greptile Review" check reports success at 4/5 — it means "I finished
# reading", not "this is good" — so it cannot enforce the rule, and this can.
#
#   scripts/greptile-gate.sh <pr-number>
#
# Fails closed, always. No review yet, a review of an older commit, a score
# that cannot be parsed, or Greptile being down all fail. A merge gate that
# passes when it cannot tell is worse than no gate, because it is trusted.
#
# **5/5 is required, never sufficient.** Greptile gave 5/5 to PR #6 while its
# privacy policy omitted a company the app sends student data to, and to a PR
# aimed at a dead branch. This enforces a floor, not a verdict; CI and a human
# reading the diff still decide.
set -uo pipefail

PR=${1:?usage: greptile-gate.sh <pr-number>}
REPO=${REPO:-fgutort8-droid/albus}
# Overridable so the failure path can be tested against a real 5/5 pull
# request. The workflow never sets it, so CI always demands 5.
REQUIRED=${REQUIRED_SCORE:-5}
WAIT_SECONDS=${WAIT_SECONDS:-600}
POLL_SECONDS=${POLL_SECONDS:-20}

# Identity, not just a name. A PR author can write anything in a comment,
# including a forged `greptile_confidence_score` marker — so the score is only
# ever read from a comment whose author is a GitHub App. GitHub reserves the
# `[bot]` suffix and sets `type` itself; neither can be claimed by a person.
BOT_LOGIN="greptile-apps[bot]"

fail() { printf '\n::error::%s\n' "$1"; exit 1; }

head_sha=$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null) \
  || fail "Could not read pull request #$PR from $REPO."
[ -n "$head_sha" ] || fail "Pull request #$PR has no head commit."

echo "Pull request #$PR, head ${head_sha:0:7}, requires ${REQUIRED}/5."

deadline=$(( $(date +%s) + WAIT_SECONDS ))
while :; do
  # Only this app's comments, and only ones carrying a score. Greptile edits a
  # single summary comment in place; `last` is the current one either way.
  # Fetched and filtered in two steps on purpose. `--slurp` flattens every
  # page into one array — without it the filter runs per page and a two-page
  # thread yields two answers — but gh refuses `--slurp` together with its own
  # `--jq`, and gh's `--jq` has no `--arg`. Real jq does, which keeps the bot
  # login a bound value rather than text spliced into a filter.
  comments=$(gh api "repos/$REPO/issues/$PR/comments" --paginate --slurp 2>/dev/null) \
    || comments=""
  body=$(printf '%s' "$comments" | jq -r --arg bot "$BOT_LOGIN" '
           add
           | [ .[]
               | select(.user.login == $bot and .user.type == "Bot")
               | .body
               | select(test("greptile_confidence_score:")) ]
           | last // ""' 2>/dev/null) || body=""

  if [ -n "$body" ]; then
    score=$(printf '%s' "$body" \
            | grep -oE 'greptile_confidence_score:[0-9]+' | tail -1 | cut -d: -f2)
    # Anchored to the "Last reviewed commit" label so an unrelated commit link
    # elsewhere in the summary can never be mistaken for the reviewed one.
    reviewed=$(printf '%s' "$body" \
               | grep -oE 'Last reviewed commit[^)]*/commit/[0-9a-f]{40}' \
               | tail -1 | grep -oE '[0-9a-f]{40}$')

    if [ -n "$score" ] && [ -n "$reviewed" ]; then
      if [ "$reviewed" = "$head_sha" ]; then
        if [ "$score" -ge "$REQUIRED" ]; then
          echo "Greptile scored ${score}/5 on ${head_sha:0:7}. Gate passed."
          echo "A 5/5 is the floor, not a verdict: read the diff and the findings too."
          exit 0
        fi
        fail "Greptile scored ${score}/5 on this pull request's latest commit (${head_sha:0:7}); ${REQUIRED}/5 is required.
Fix the valid findings and push. If a finding is wrong, reply on its thread with evidence and comment @greptileai to re-review, then re-run this check:
  gh run rerun --repo $REPO \$(gh run list --repo $REPO --branch <branch> --limit 1 --json databaseId --jq '.[0].databaseId')
Never change the code just to raise the score."
      fi
      echo "Greptile has reviewed ${reviewed:0:7}; head is ${head_sha:0:7}. Waiting for it to catch up."
    else
      echo "Found a Greptile summary but could not read a score and a reviewed commit from it. Waiting."
    fi
  else
    echo "No Greptile review yet. Waiting."
  fi

  now=$(date +%s)
  [ "$now" -lt "$deadline" ] || break
  remaining=$(( deadline - now ))
  sleep $(( POLL_SECONDS < remaining ? POLL_SECONDS : remaining ))
done

fail "No Greptile score for this pull request's latest commit (${head_sha:0:7}) after $((WAIT_SECONDS / 60)) minutes.
Failing closed: an unreviewed pull request is not a passing one. Comment @greptileai on the pull request to trigger a review, then re-run this check. If Greptile is down or out of monthly credits, merging waits — that is the rule working, not a fault."
