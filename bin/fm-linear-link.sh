#!/usr/bin/env bash
# Link a ship task to the Linear ticket it delivers, so firstmate can drive the
# In Progress -> In Review -> merge lifecycle and the PR-feedback loop for it.
#
# Usage: fm-linear-link.sh <task-id> <issue-id> [branch]
#
# Records two lines in state/<task-id>.meta (replacing any prior link, preserving
# every other meta line; the read/write lives in fm-linear-lib.sh):
#   linear_issue=<issue-id>    the Linear issue this task delivers
#   linear_branch=<branch>     the branch/PR head the review gate attaches to
#
# <branch> is the EXACT Linear branchName the crewmate ships on, so the PR
# auto-links in Linear by branch name; it is informational firstmate bookkeeping
# (the PR-feedback wake is driven by fm-pr-check on the PR URL, not by this line).
# When omitted it is recorded empty and may be set on a later link.
#
# This is a separate step the linear-respond skill runs AFTER fm-spawn.sh, so it
# never changes fm-spawn's interface. It parallels fm-x-link.sh.
#
# All three values compose a filename or are written verbatim into meta, so they
# are guarded against path traversal even though they come from trusted callers.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-linear-lib.sh
. "$SCRIPT_DIR/fm-linear-lib.sh"

ID=${1:-}
ISSUE=${2:-}
BRANCH=${3:-}
if [ -z "$ID" ] || [ -z "$ISSUE" ]; then
  echo "usage: fm-linear-link.sh <task-id> <issue-id> [branch]" >&2
  exit 2
fi

# task-id composes a path (state/<id>.meta). Reject anything outside a safe slug.
case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "fm-linear-link: unsafe task id: $ID" >&2; exit 2 ;;
esac
# issue-id is written into meta and used elsewhere as a filename; keep it a safe slug.
case "$ISSUE" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "fm-linear-link: unsafe issue id: $ISSUE" >&2; exit 2 ;;
esac

META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  echo "fm-linear-link: no such task: state/$ID.meta" >&2
  exit 1
fi

if ! linear_meta_link_set "$META" "$ISSUE" "$BRANCH"; then
  echo "fm-linear-link: failed to record the link in state/$ID.meta" >&2
  exit 1
fi

printf 'linked %s to Linear issue %s\n' "$ID" "$ISSUE"
