#!/usr/bin/env bash
# Post a comment on a Linear ticket. BACKLOG GROOMING ONLY: firstmate comments on
# Linear solely to groom a backlog candidate (ask the captain to sharpen a ticket,
# note a clarification). In-progress questions and decisions go through firstmate,
# NEVER through a Linear comment - see AGENTS.md "Linear mode".
#
# Usage: fm-linear-comment.sh <issue-id> <text>
#        fm-linear-comment.sh <issue-id> --text-file <path>   # read body from a file
#        fm-linear-comment.sh <issue-id> -                    # read body from stdin
#
# The --text-file / stdin forms exist so a caller never has to inline comment text
# (which may quote untrusted ticket content) into a shell command. The body is
# passed to GraphQL as a JSON variable via jq, so it is never interpolated.
#
# Inert by default: with no LINEAR_API_KEY this exits non-zero with a config
# message and makes no network call.
#
# Preview / dry-run: with LINEAR_DRY_RUN set (truthy), nothing is posted. The
# would-be comment is recorded to state/linear-outbox/<issue-id>.json
# ({issue_id, body, endpoint:"commentCreate"}), a DRY RUN line is printed to
# stderr, and stdout echoes the issue id with exit 0. Truthy means anything except
# unset, empty, 0, false, no, or off; an explicit env value wins over .env. Like
# the other Linear helpers it mirrors the X-mode dry-run contract.
#
# Config (home .env, LINEAR_ENV_FILE, or env): LINEAR_API_KEY (required for a live
# post), LINEAR_API_URL (default https://api.linear.app/graphql). Auth: the RAW
# key in the Authorization header (no Bearer prefix).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-linear-lib.sh
. "$SCRIPT_DIR/fm-linear-lib.sh"

usage() {
  echo "usage: fm-linear-comment.sh <issue-id> <text> | <issue-id> --text-file <path> | <issue-id> -" >&2
}

ISSUE=${1:-}
if [ -z "$ISSUE" ]; then usage; exit 2; fi
shift
if [ "$#" -lt 1 ]; then usage; exit 2; fi

case "$1" in
  --text-file)
    if [ "$#" -lt 2 ]; then usage; exit 2; fi
    BODY=$(cat -- "$2") || { echo "fm-linear-comment: cannot read text file: $2" >&2; exit 1; }
    ;;
  -)
    BODY=$(cat)
    ;;
  *)
    BODY=$1
    ;;
esac
# An empty or whitespace-only body is almost certainly a mistake; refuse it.
BODY_TRIMMED=${BODY//[$' \t\r\n']/}
if [ -z "$BODY_TRIMMED" ]; then echo "fm-linear-comment: empty comment body" >&2; exit 2; fi

# The issue id becomes a filename (dry-run outbox record), so never trust it into
# a path even though it comes from a trusted caller / stashed inbox node.
case "$ISSUE" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "fm-linear-comment: unsafe issue id: $ISSUE" >&2; exit 2 ;;
esac

# Truthy LINEAR_DRY_RUN (env wins over .env), mirroring the X-mode dry-run switch.
DRY=${LINEAR_DRY_RUN+x}
if [ -n "$DRY" ]; then
  DRYVAL=${LINEAR_DRY_RUN-}
else
  DRYVAL=$(linear_env_get LINEAR_DRY_RUN "${LINEAR_ENV_FILE:-$FM_HOME/.env}")
fi
case "$DRYVAL" in
  ''|0|false|no|off) DRY= ;;
  *) DRY=1 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-linear-comment: jq not found" >&2; exit 1; }

# Build the GraphQL body now so it is identical for the dry-run record and a live
# post; the comment text is a jq --arg variable, never interpolated.
read -r -d '' MUTATION <<'GQL' || true
mutation FmLinearComment($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) {
    success
    comment { id }
  }
}
GQL
VARS=$(jq -cn --arg id "$ISSUE" --arg body "$BODY" '{issueId: $id, body: $body}') \
  || { echo "fm-linear-comment: failed to build request" >&2; exit 1; }

# Preview / dry-run: record what we WOULD post and stop, without auth or network.
if [ -n "$DRY" ]; then
  outbox_dir="$STATE/linear-outbox"
  outbox_file="$outbox_dir/$ISSUE.json"
  mkdir -p "$outbox_dir" 2>/dev/null || { echo "fm-linear-comment: cannot create dry-run outbox: $outbox_dir" >&2; exit 1; }
  jq -cn --arg id "$ISSUE" --arg body "$BODY" \
    '{issue_id: $id, body: $body, endpoint: "commentCreate"}' > "$outbox_file" 2>/dev/null \
    || { echo "fm-linear-comment: cannot write dry-run outbox: $outbox_file" >&2; exit 1; }
  printf 'fm-linear-comment: DRY RUN - would comment on %s (recorded: state/linear-outbox/%s.json)\n' "$ISSUE" "$ISSUE" >&2
  printf '%s\n' "$ISSUE"
  exit 0
fi

linear_load_config
if [ -z "$LINEAR_KEY" ]; then
  echo "fm-linear-comment: Linear mode not configured (no LINEAR_API_KEY)" >&2
  exit 1
fi
command -v curl >/dev/null 2>&1 || { echo "fm-linear-comment: curl not found" >&2; exit 1; }

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-linear-comment.XXXXXX") || exit 1
trap 'rm -f "$BODY_FILE"' EXIT

code=$(linear_graphql "$MUTATION" "$VARS" "$BODY_FILE" 10)
rc=$?
if [ "$rc" -eq 2 ]; then echo "fm-linear-comment: invalid LINEAR_API_KEY or missing dependency" >&2; exit 1; fi
if [ "$rc" -ne 0 ]; then echo "fm-linear-comment: request to Linear failed" >&2; exit 1; fi
case "$code" in
  200) ;;
  *) echo "fm-linear-comment: Linear API returned HTTP $code" >&2; exit 1 ;;
esac
if jq -e '(.errors // []) | length > 0' "$BODY_FILE" >/dev/null 2>&1; then
  echo "fm-linear-comment: Linear GraphQL error" >&2
  exit 1
fi
if [ "$(jq -r '.data.commentCreate.success // false' "$BODY_FILE" 2>/dev/null)" != "true" ]; then
  echo "fm-linear-comment: Linear did not confirm the comment" >&2
  exit 1
fi

printf '%s\n' "$ISSUE"
