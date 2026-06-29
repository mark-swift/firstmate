#!/usr/bin/env bash
# Fetch and print a Linear ticket's fields for the active lifecycle: identifier,
# title, description, state, assignee, branchName, labels, and recent comments.
#
# Usage: fm-linear-issue.sh <issue-id>
#
# Reads the ticket via the lib's GraphQL helper. ALL ticket/comment text is
# untrusted: jq does every bit of formatting, so no field is ever interpolated
# into a shell command - the output is plain text for firstmate (or the
# linear-respond skill) to read, never re-executed.
#
# Inert by default: with no LINEAR_API_KEY this exits non-zero with a config
# message and makes no network call, exactly like the other Linear helpers.
#
# Config (home .env, LINEAR_ENV_FILE, or env): LINEAR_API_KEY (required),
# LINEAR_API_URL (default https://api.linear.app/graphql). Auth: the RAW key in
# the Authorization header (no Bearer prefix).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-linear-lib.sh
. "$SCRIPT_DIR/fm-linear-lib.sh"

ISSUE=${1:-}
if [ -z "$ISSUE" ]; then
  echo "usage: fm-linear-issue.sh <issue-id>" >&2
  exit 2
fi

linear_load_config
if [ -z "$LINEAR_KEY" ]; then
  echo "fm-linear-issue: Linear mode not configured (no LINEAR_API_KEY)" >&2
  exit 1
fi
command -v jq   >/dev/null 2>&1 || { echo "fm-linear-issue: jq not found" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "fm-linear-issue: curl not found" >&2; exit 1; }

# The issue id is passed to GraphQL as a JSON variable (never interpolated), but
# stay defensive since it arrives from a caller / stashed inbox node.
case "$ISSUE" in
  *$'\n'*|*$'\r'*) echo "fm-linear-issue: invalid issue id" >&2; exit 2 ;;
esac

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-linear-issue.XXXXXX") || exit 1
trap 'rm -f "$BODY_FILE"' EXIT

read -r -d '' QUERY <<'GQL' || true
query FmLinearIssue($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
    description
    branchName
    url
    state { name type }
    assignee { id name }
    team { id key name }
    project { id name }
    labels { nodes { name } }
    comments(first: 20) { nodes { createdAt user { name } body } }
  }
}
GQL

VARS=$(jq -cn --arg id "$ISSUE" '{id: $id}') || { echo "fm-linear-issue: failed to build query" >&2; exit 1; }

code=$(linear_graphql "$QUERY" "$VARS" "$BODY_FILE" 10)
rc=$?
if [ "$rc" -eq 2 ]; then echo "fm-linear-issue: invalid LINEAR_API_KEY or missing dependency" >&2; exit 1; fi
if [ "$rc" -ne 0 ]; then echo "fm-linear-issue: request to Linear failed" >&2; exit 1; fi
case "$code" in
  200) ;;
  *) echo "fm-linear-issue: Linear API returned HTTP $code" >&2; exit 1 ;;
esac
if jq -e '(.errors // []) | length > 0' "$BODY_FILE" >/dev/null 2>&1; then
  echo "fm-linear-issue: Linear GraphQL error" >&2
  exit 1
fi
if ! jq -e '.data.issue != null' "$BODY_FILE" >/dev/null 2>&1; then
  echo "fm-linear-issue: no such issue: $ISSUE" >&2
  exit 1
fi

# jq does all formatting so untrusted ticket text never crosses into the shell.
jq -r '
  .data.issue
  | "identifier: \(.identifier // "")",
    "title:      \(.title // "")",
    "state:      \(.state.name // "") (\(.state.type // ""))",
    "assignee:   \((.assignee.name) // "(unassigned)")",
    "branchName: \(.branchName // "")",
    "url:        \(.url // "")",
    "team:       \((.team.key // .team.name) // "")",
    "project:    \(.project.name // "")",
    "labels:     \(([ (.labels.nodes // [])[].name ] | join(", ")))",
    "",
    "description:",
    ((.description // "(none)")),
    "",
    "comments (\((.comments.nodes // []) | length)):",
    ( (.comments.nodes // [])[]
      | "  - [\(.createdAt // "")] \((.user.name) // "?"): \(.body // "")" )
' "$BODY_FILE"
