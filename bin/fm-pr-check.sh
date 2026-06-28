#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and a verified pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
#
# The check shim also surfaces PR REVIEW FEEDBACK as a distinct wake: a new
# changes-requested or review-comment review (since the last seen one) prints
# "pr-feedback <id>", tracked with a per-task seen-cursor (state/<id>.pr-feedback-seen)
# so it wakes once per new review and never re-fires on the same one. This is
# strictly additive to merge detection - a merged PR still wakes "merged" and the
# feedback path is skipped - and it drives the Linear In Review -> In Progress
# feedback loop (AGENTS.md "Linear mode"). To avoid a spurious wake on review
# activity that predates arming, the cursor is baselined to the current newest
# interesting review at arm time (only when no cursor exists yet).
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

# The jq selector for "interesting" reviews (changes-requested or a review
# comment), shared by the arm-time baseline and the generated shim so they stay
# in lockstep. APPROVED reviews are intentionally excluded: an approval is not
# feedback that needs another iteration.
FM_PR_FEEDBACK_JQ='[.reviews[]? | select(.state=="CHANGES_REQUESTED" or .state=="COMMENTED") | .submittedAt] | max // ""'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  LOCAL_HEAD=
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    LOCAL_HEAD=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null || true)
    if [ -n "$LOCAL_HEAD" ] && command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        if [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ]; then
          PR_HEAD=$LOCAL_HEAD
        fi
      fi
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

SEEN="$STATE/$ID.pr-feedback-seen"
# Baseline the feedback cursor once, so review activity that predates arming does
# not wake firstmate. Only when no cursor exists yet (preserve it across re-arms).
if [ ! -f "$SEEN" ]; then
  mkdir -p "$STATE" 2>/dev/null || true
  base=""
  if command -v gh >/dev/null 2>&1; then
    base=$(gh pr view "$URL" --json reviews -q "$FM_PR_FEEDBACK_JQ" 2>/dev/null || true)
  fi
  printf '%s' "$base" > "$SEEN" 2>/dev/null || true
fi

cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
if [ "\$state" = "MERGED" ]; then
  echo "merged"
else
  # PR review feedback: wake once per new changes-requested / review-comment.
  prev=\$(cat "$SEEN" 2>/dev/null || true)
  latest=\$(gh pr view "$URL" --json reviews -q '$FM_PR_FEEDBACK_JQ' 2>/dev/null || true)
  if [ -n "\$latest" ] && [ "\$latest" != "\$prev" ]; then
    printf '%s' "\$latest" > "$SEEN" 2>/dev/null || true
    echo "pr-feedback $ID"
  fi
fi
EOF
echo "armed: state/$ID.check.sh polls $URL"
