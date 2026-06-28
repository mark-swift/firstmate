#!/usr/bin/env bash
# One short-poll of the Linear GraphQL API for tickets assigned to the firstmate
# bot user, surfaced as watcher wakes.
#
# Inert by default: a HARD no-op (exit 0, no output) unless Linear mode is
# configured via a non-empty LINEAR_API_KEY (from the home's .env or the
# environment). This is the body of the watcher check shim
# state/linear-watch.check.sh, where the contract is "output => wake firstmate,
# silence => keep sleeping", so the no-op keeps the watcher behaving exactly as
# today until a user opts in.
#
# Assignment to the bot user is the single ownership signal: firstmate only ever
# watches bot-assigned tickets. For each such ticket this poll emits, at most one
# per genuine transition (deduped via per-issue seen-markers under state/):
#   ready state            -> "linear-ready <issue-id>"     (the go-work signal)
#   newly moved to canceled-> "linear-canceled <issue-id>"  (drop a watched ticket)
#   new non-bot comment on
#     a backlog item       -> "linear-groom <issue-id>"     (grooming candidate)
# Auth/config/HTTP/GraphQL errors emit one rate-limited "linear-error <msg>".
# The full issue node (plus an "event" field) is stashed atomically to
# state/linear-inbox/<issue-id>.json for the responder skill (a later slice) to
# drain. Untrusted ticket/comment text is never interpolated into a command:
# classification reads JSON via jq, only the validated issue id and the safe event
# enum reach the shell, and nodes are stashed straight from jq.
#
# First-sighting semantics: a ready ticket fires on first sight (assignment IS the
# event); a canceled or commented ticket records its marker silently on first
# sight and fires only on a transition witnessed thereafter, so a fresh home does
# not flood on pre-existing history.
#
# Config (home .env, LINEAR_ENV_FILE, or env): LINEAR_API_KEY (required),
# LINEAR_API_URL (default https://api.linear.app/graphql), LINEAR_BOT_USER_ID
# (required to poll), optional LINEAR_STATE_* mapping. Auth: the RAW key in the
# Authorization header (no Bearer prefix).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-linear-lib.sh
. "$SCRIPT_DIR/fm-linear-lib.sh"

linear_load_config
# Hard no-op when Linear mode is off: this is what keeps the check shim inert.
[ -n "$LINEAR_KEY" ] || exit 0

ERROR_FILE="$STATE/linear-poll.error"

emit_error_once() {
  local msg=$1
  mkdir -p "$STATE" 2>/dev/null || true
  if [ -f "$ERROR_FILE" ] && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" > "$ERROR_FILE" 2>/dev/null || true
  printf 'linear-error %s\n' "$msg"
}

clear_error() {
  rm -f "$ERROR_FILE" 2>/dev/null || true
}

command -v curl >/dev/null 2>&1 || { emit_error_once "missing curl"; exit 0; }
command -v jq   >/dev/null 2>&1 || { emit_error_once "missing jq"; exit 0; }

# Without a bot user id we cannot scope the poll to bot-assigned tickets.
[ -n "$LINEAR_BOT" ] || { emit_error_once "missing LINEAR_BOT_USER_ID"; exit 0; }

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-linear-poll.XXXXXX") || exit 0
trap 'rm -f "$BODY_FILE"' EXIT

# issues(first: 50) is an intentional slice-1 bound; a fleet with >50 bot-assigned
# tickets would miss the overflow. comments are fetched newest-first so a busy
# ticket's latest comment is always within the page that grooming keys off.
read -r -d '' QUERY <<'GQL' || true
query FmLinearPoll($bot: ID) {
  issues(first: 50, filter: { assignee: { id: { eq: $bot } } }) {
    nodes {
      id
      identifier
      title
      state { name type }
      team { id key name }
      project { id name }
      labels { nodes { name } }
      comments(first: 50, orderBy: { createdAt: DESC }) { nodes { id createdAt user { id } } }
    }
  }
}
GQL

VARS=$(jq -cn --arg bot "$LINEAR_BOT" '{bot: $bot}') || exit 0

# Short, bounded poll: a failure or timeout simply means "no wake this cycle".
code=$(linear_graphql "$QUERY" "$VARS" "$BODY_FILE" 5)
rc=$?
if [ "$rc" -eq 2 ]; then emit_error_once "invalid LINEAR_API_KEY"; exit 0; fi
if [ "$rc" -ne 0 ]; then exit 0; fi   # transport failure: silent, retry next cycle

case "$code" in
  200) ;;
  400|401|403|404|429) emit_error_once "Linear API returned HTTP $code"; exit 0 ;;
  *) exit 0 ;;
esac

# GraphQL returns 200 even for query errors. Do not echo the server's (untrusted)
# message into the wake line; report a controlled diagnostic instead.
if jq -e '(.errors // []) | length > 0' "$BODY_FILE" >/dev/null 2>&1; then
  emit_error_once "Linear GraphQL error"
  exit 0
fi

# Extract one compact JSON object per bot-assigned issue: id, current state
# name/type, and the newest non-bot comment timestamp. jq does all parsing so no
# untrusted ticket text crosses into the shell.
NODES=$(jq -c --arg bot "$LINEAR_BOT" '
  (.data.issues.nodes // [])[]
  | {
      id: (.id // ""),
      name: (.state.name // ""),
      type: (.state.type // ""),
      cts: ([ (.comments.nodes // [])[] | select(.user.id != $bot) | .createdAt ] | max // "")
    }
' "$BODY_FILE" 2>/dev/null) || { clear_error; exit 0; }

SEEN="$STATE/linear-seen"
INBOX="$STATE/linear-inbox"

# Advance the per-issue seen markers from the current loop iteration's $iid/$kind/
# $cts. For an issue with NO event this is the silent baseline; for an EVENT issue
# it is called only after a successful inbox stash, so a transient stash failure
# leaves the markers unadvanced and the wake re-fires on a later poll once the
# cause is repaired (at-least-once delivery).
advance_markers() {
  printf '%s' "$kind" > "$SEEN/$iid.state" 2>/dev/null || true
  if [ "$kind" = backlog ] && [ -n "$cts" ]; then
    printf '%s' "$cts" > "$SEEN/$iid.comment" 2>/dev/null || true
  fi
}

while IFS= read -r obj; do
  [ -n "$obj" ] || continue
  iid=$(printf '%s' "$obj" | jq -r '.id // ""' 2>/dev/null) || continue
  # The issue id becomes a marker/inbox filename; never trust it into a path.
  case "$iid" in
    ''|.*|*[!A-Za-z0-9._-]*) continue ;;
  esac
  sname=$(printf '%s' "$obj" | jq -r '.name // ""' 2>/dev/null) || sname=
  stype=$(printf '%s' "$obj" | jq -r '.type // ""' 2>/dev/null) || stype=
  cts=$(printf '%s' "$obj" | jq -r '.cts // ""' 2>/dev/null) || cts=
  # Constrain the timestamp to an ISO-ish shape; it is only ever string-compared
  # and written to a marker file, but stay defensive.
  case "$cts" in *[!0-9TtZz:.+-]*) cts= ;; esac

  kind=$(linear_state_kind "$sname" "$stype")

  mkdir -p "$SEEN" 2>/dev/null || true
  prevstate=$(cat "$SEEN/$iid.state" 2>/dev/null || true)
  event=

  case "$kind" in
    ready)
      # Fires on first sight (no marker) or on a fresh ready transition.
      [ "$prevstate" != ready ] && event=linear-ready
      ;;
    canceled)
      # Only a witnessed move TO canceled (a marker exists and was not canceled).
      [ -n "$prevstate" ] && [ "$prevstate" != canceled ] && event=linear-canceled
      ;;
    backlog)
      prevc=$(cat "$SEEN/$iid.comment" 2>/dev/null || true)
      if [ -n "$cts" ]; then
        # Groom only on a ticket we have witnessed before (prevstate non-empty),
        # so first sight records the marker silently and pre-existing comment
        # history never floods a fresh home. A witnessed ticket grooms when there
        # is a non-bot comment that is new: no marker recorded yet, or newer than it.
        if [ -n "$prevstate" ] && { [ -z "$prevc" ] || [[ "$cts" > "$prevc" ]]; }; then
          event=linear-groom
        fi
      fi
      ;;
  esac

  if [ -z "$event" ]; then
    advance_markers
    continue
  fi

  mkdir -p "$INBOX" 2>/dev/null || { emit_error_once "cannot create inbox"; exit 0; }
  if jq -c --arg id "$iid" --arg ev "$event" \
      '(.data.issues.nodes[]? | select(.id == $id)) + {event: $ev}' \
      "$BODY_FILE" > "$INBOX/$iid.json.tmp" 2>/dev/null; then
    if mv -f "$INBOX/$iid.json.tmp" "$INBOX/$iid.json" 2>/dev/null; then
      advance_markers
      printf '%s %s\n' "$event" "$iid"
    else
      rm -f "$INBOX/$iid.json.tmp"
      emit_error_once "cannot write inbox"
      exit 0
    fi
  else
    rm -f "$INBOX/$iid.json.tmp"
    emit_error_once "cannot write inbox"
    exit 0
  fi
done <<EOF
$NODES
EOF

clear_error
exit 0
