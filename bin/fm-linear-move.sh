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
case "$ISSUE" in
  *$'\n'*|*$'\r'*) echo "fm-linear-move: invalid issue id" >&2; exit 2 ;;
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
