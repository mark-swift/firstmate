#!/usr/bin/env bash
# Transition a Linear ticket's workflow state by configured role.
#
# Usage: fm-linear-move.sh <issue-id> <state-role>
#   <state-role> is one of: in-progress | in-review
#
# These are the two transitions firstmate drives in the active lifecycle:
#   in-progress  on dispatch of a To Do ticket, and again on PR feedback
#   in-review    after the no-mistakes gate is green
# The role is resolved to the workspace's concrete workflow-state id via the lib
# (linear_match_state_id over the issue's team states): a configured-or-default
# NAME match wins, with a "started"-type fallback for in-progress only (Linear has
# no distinct review type). The transition is then applied with issueUpdate.
#
# Inert by default: with no LINEAR_API_KEY this exits non-zero with a config
# message and makes no network call.
#
# Preview / dry-run: with LINEAR_DRY_RUN set (truthy), the live states READ still
# happens (the role can only be resolved to a concrete, workspace-specific state id
# against the live states), but the issueUpdate WRITE is suppressed and recorded to
# state/linear-outbox/<issue-id>.move.json ({issue_id, role, stateId,
# endpoint:"issueUpdate"}) instead; a DRY RUN line prints to stderr and stdout
# echoes the move with exit 0. So a move dry-run still needs the key for the read,
# unlike a comment dry-run (which is fully offline) - the one asymmetry between
# them. The distinct .move.json filename keeps a move preview from clobbering a
# grooming-comment preview (<issue-id>.json) for the same issue.
#
# The issue id is passed to GraphQL as a JSON variable (never interpolated). The
# resolved state id is a Linear UUID derived from the server's own states list.
#
# Config (home .env, LINEAR_ENV_FILE, or env): LINEAR_API_KEY (required),
# LINEAR_API_URL (default https://api.linear.app/graphql), optional
# LINEAR_STATE_IN_PROGRESS / LINEAR_STATE_IN_REVIEW name overrides. Auth: the RAW
# key in the Authorization header (no Bearer prefix).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-linear-lib.sh
. "$SCRIPT_DIR/fm-linear-lib.sh"

ISSUE=${1:-}
ROLE=${2:-}
if [ -z "$ISSUE" ] || [ -z "$ROLE" ]; then
  echo "usage: fm-linear-move.sh <issue-id> <in-progress|in-review>" >&2
  exit 2
fi
case "$ROLE" in
  in-progress|in-review) ;;
  *) echo "fm-linear-move: unknown role: $ROLE (expected in-progress or in-review)" >&2; exit 2 ;;
esac
# The issue id is passed to GraphQL as a JSON variable AND (in dry-run) composes
# an outbox filename, so constrain it to a safe slug (matches the poll's guard).
case "$ISSUE" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "fm-linear-move: unsafe issue id: $ISSUE" >&2; exit 2 ;;
esac

# Truthy LINEAR_DRY_RUN (env wins over .env), mirroring fm-linear-comment.sh. In
# dry-run the live states READ still happens (the concrete state id is a
# workspace-specific UUID only Linear knows, so the role can only be resolved
# against the live states), but the issueUpdate WRITE is suppressed and recorded
# instead. So a move dry-run still needs the key for the read, unlike a comment
# dry-run; this is the one asymmetry between the two.
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

linear_load_config
if [ -z "$LINEAR_KEY" ]; then
  echo "fm-linear-move: Linear mode not configured (no LINEAR_API_KEY)" >&2
  exit 1
fi
command -v jq   >/dev/null 2>&1 || { echo "fm-linear-move: jq not found" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "fm-linear-move: curl not found" >&2; exit 1; }

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-linear-move.XXXXXX") || exit 1
trap 'rm -f "$BODY_FILE"' EXIT

graphql_or_die() { # <query> <vars> <what>
  local q=$1 v=$2 what=$3 code rc
  code=$(linear_graphql "$q" "$v" "$BODY_FILE" 10); rc=$?
  if [ "$rc" -eq 2 ]; then echo "fm-linear-move: invalid LINEAR_API_KEY or missing dependency" >&2; exit 1; fi
  if [ "$rc" -ne 0 ]; then echo "fm-linear-move: request to Linear failed ($what)" >&2; exit 1; fi
  case "$code" in
    200) ;;
    *) echo "fm-linear-move: Linear API returned HTTP $code ($what)" >&2; exit 1 ;;
  esac
  if jq -e '(.errors // []) | length > 0' "$BODY_FILE" >/dev/null 2>&1; then
    echo "fm-linear-move: Linear GraphQL error ($what)" >&2
    exit 1
  fi
}

# 1. Fetch the issue's team workflow states.
read -r -d '' STATES_Q <<'GQL' || true
query FmLinearStates($id: String!) {
  issue(id: $id) {
    id
    team { states { nodes { id name type position } } }
  }
}
GQL
VARS=$(jq -cn --arg id "$ISSUE" '{id: $id}') || { echo "fm-linear-move: failed to build query" >&2; exit 1; }
graphql_or_die "$STATES_Q" "$VARS" "fetch states"

STATES=$(jq -c '.data.issue.team.states.nodes // []' "$BODY_FILE" 2>/dev/null) || STATES=
if [ -z "$STATES" ] || [ "$STATES" = "null" ]; then
  echo "fm-linear-move: could not read workflow states for $ISSUE" >&2
  exit 1
fi

STATE_ID=$(linear_match_state_id "$ROLE" "$STATES") || STATE_ID=
if [ -z "$STATE_ID" ]; then
  echo "fm-linear-move: no workflow state matches role '$ROLE' in this workspace (configure LINEAR_STATE_IN_PROGRESS / LINEAR_STATE_IN_REVIEW)" >&2
  exit 1
fi

# Preview / dry-run: the role is resolved (above, via the live read), so record the
# would-be transition with its concrete state id and stop, without the write. The
# outbox filename is keyed distinctly (<issue-id>.move.json) so a move preview never
# collides with a grooming-comment preview (<issue-id>.json) for the same issue.
if [ -n "$DRY" ]; then
  outbox_dir="$STATE/linear-outbox"
  outbox_file="$outbox_dir/$ISSUE.move.json"
  mkdir -p "$outbox_dir" 2>/dev/null || { echo "fm-linear-move: cannot create dry-run outbox: $outbox_dir" >&2; exit 1; }
  jq -cn --arg id "$ISSUE" --arg role "$ROLE" --arg sid "$STATE_ID" \
    '{issue_id: $id, role: $role, stateId: $sid, endpoint: "issueUpdate"}' > "$outbox_file" 2>/dev/null \
    || { echo "fm-linear-move: cannot write dry-run outbox: $outbox_file" >&2; exit 1; }
  printf 'fm-linear-move: DRY RUN - would move %s to %s (state %s) (recorded: state/linear-outbox/%s.move.json)\n' \
    "$ISSUE" "$ROLE" "$STATE_ID" "$ISSUE" >&2
  printf 'moved %s to %s (dry-run)\n' "$ISSUE" "$ROLE"
  exit 0
fi

# 2. Apply the transition.
read -r -d '' UPDATE_M <<'GQL' || true
mutation FmLinearMove($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue { id state { name } }
  }
}
GQL
VARS=$(jq -cn --arg id "$ISSUE" --arg sid "$STATE_ID" '{id: $id, stateId: $sid}') \
  || { echo "fm-linear-move: failed to build mutation" >&2; exit 1; }
graphql_or_die "$UPDATE_M" "$VARS" "apply transition"

if [ "$(jq -r '.data.issueUpdate.success // false' "$BODY_FILE" 2>/dev/null)" != "true" ]; then
  echo "fm-linear-move: Linear did not confirm the transition" >&2
  exit 1
fi

NEW_STATE=$(jq -r '.data.issueUpdate.issue.state.name // ""' "$BODY_FILE" 2>/dev/null) || NEW_STATE=
printf 'moved %s to %s%s\n' "$ISSUE" "$ROLE" "${NEW_STATE:+ ($NEW_STATE)}"
