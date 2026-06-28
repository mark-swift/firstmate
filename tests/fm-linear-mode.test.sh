#!/usr/bin/env bash
# Behavior tests for Linear mode: the GraphQL poll client (fm-linear-poll.sh), the
# config/resolver library (fm-linear-lib.sh), and bootstrap's .env-presence
# activation.
#
# Linear mode must be INERT by default (no key -> the poll is a hard no-op and
# bootstrap writes/prints nothing) and additive when on (a check shim + a 60s
# cadence config, both idempotent). The network is stubbed with a fakebin `curl`
# so these stay hermetic: no ports, no server, deterministic in CI. jq stays the
# real tool. This is the Linear analogue of tests/fm-x-mode.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
# The client uses the real jq; make it resolvable wherever it is installed.
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
BASH=${BASH:-$(command -v bash)}
TMP_ROOT=$(fm_test_tmproot fm-linear-mode-tests)

# A fakebin `curl` mimicking the Linear GraphQL endpoint: it reads its behavior
# from env (FAKE_GQL_CODE/FAKE_GQL_BODY), records each call to FAKE_CURL_LOG,
# writes the response body to the script's -o file, and prints the HTTP code to
# stdout exactly as the real `-w '%{http_code}'` would.
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" method=GET data="" url="" auth=""
argv=$*
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -X) method=$2; shift 2 ;;
    --data) data=$2; shift 2 ;;
    -H)
      case "$2" in
        @*) while IFS= read -r header; do case "$header" in Authorization:*) auth=$header ;; esac; done < "${2#@}" ;;
        Authorization:*) auth=$2 ;;
      esac
      shift 2
      ;;
    -m|-w) shift 2 ;;
    -s) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  { echo "argv=$argv"; echo "method=$method"; echo "url=$url"; echo "auth=$auth"; echo "data=$data"; } >> "$FAKE_CURL_LOG"
fi
[ -n "$ofile" ] && printf '%s' "${FAKE_GQL_BODY:-}" > "$ofile"
printf '%s' "${FAKE_GQL_CODE:-200}"
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# Build a GraphQL response body wrapping one issue node.
issue_body() { # <node-json>
  printf '{"data":{"issues":{"nodes":[%s]}}}' "$1"
}

# ---------------------------------------------------------------------------
# Poll: inert default

test_poll_no_key_is_hard_noop() {
  local home fakebin out rc
  home="$TMP_ROOT/poll-noop"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_KEY='' \
    "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll no-key exit"
  [ -z "$out" ] || fail "poll no-key must be silent (got: $out)"
  assert_absent "$home/state/linear-inbox" "poll no-key must not create an inbox"
  assert_absent "$home/state/linear-seen" "poll no-key must not create seen markers"
  pass "fm-linear-poll is a hard no-op without a key (inert default)"
}

test_poll_empty_env_key_overrides_env_file() {
  local home fakebin log out rc
  home="$TMP_ROOT/poll-empty-env-key"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'LINEAR_API_KEY=lin_dotenv\nLINEAR_BOT_USER_ID=bot-1\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_KEY='' \
    FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll empty-env-key exit"
  [ -z "$out" ] || fail "empty env key must disable Linear mode despite .env key (got: $out)"
  [ ! -f "$log" ] || fail "empty env key must not call the API"
  pass "fm-linear-poll treats an explicitly empty env key as off"
}

test_poll_missing_bot_reports_error() {
  local home fakebin out rc
  home="$TMP_ROOT/poll-nobot"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'LINEAR_API_KEY=lin_k\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll missing-bot exit"
  [ "$out" = "linear-error missing LINEAR_BOT_USER_ID" ] \
    || fail "poll without a bot user id must emit a config error (got: $out)"
  pass "fm-linear-poll reports a missing bot user id"
}

# ---------------------------------------------------------------------------
# Poll: GraphQL request shape and auth

test_poll_sends_raw_key_to_graphql() {
  local home fakebin log out rc data
  home="$TMP_ROOT/poll-auth"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'LINEAR_API_KEY=lin_raw\nLINEAR_BOT_USER_ID=bot-7\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_CURL_LOG="$log" FAKE_GQL_CODE=200 FAKE_GQL_BODY='{"data":{"issues":{"nodes":[]}}}' \
    "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll auth exit"
  [ -z "$out" ] || fail "poll with no events must be silent (got: $out)"
  # Linear personal keys use the RAW key, never a Bearer prefix.
  assert_grep "auth=Authorization: lin_raw" "$log" "poll must send the raw key (no Bearer)"
  grep -F "Bearer" "$log" >/dev/null 2>&1 && fail "poll must not send a Bearer prefix"
  grep '^argv=' "$log" | grep -F 'lin_raw' >/dev/null 2>&1 \
    && fail "poll must not expose the key in curl argv"
  assert_grep "url=https://linear.test/graphql" "$log" "poll must hit the configured GraphQL URL"
  assert_grep "method=POST" "$log" "poll must POST the GraphQL query"
  # The bot id must reach the query as a JSON variable.
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  [ "$(printf '%s' "$data" | jq -r '.variables.bot')" = "bot-7" ] \
    || fail "poll must pass the bot user id as a GraphQL variable"
  pass "fm-linear-poll posts the GraphQL query with the raw key and bot variable"
}

test_poll_http_error_reports_once() {
  local home fakebin out rc
  home="$TMP_ROOT/poll-401"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'LINEAR_API_KEY=lin_k\nLINEAR_BOT_USER_ID=bot-1\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=401 "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll 401 exit"
  [ "$out" = "linear-error Linear API returned HTTP 401" ] \
    || fail "poll auth error must emit one diagnostic (got: $out)"
  assert_present "$home/state/linear-poll.error" "poll error must write a dedupe marker"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=401 "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll repeated 401 exit"
  [ -z "$out" ] || fail "repeated poll error must be quiet after the first (got: $out)"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY='{"data":{"issues":{"nodes":[]}}}' \
    "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll recovery exit"
  [ -z "$out" ] || fail "poll recovery must stay silent (got: $out)"
  assert_absent "$home/state/linear-poll.error" "a clean poll must clear the diagnostic marker"
  pass "fm-linear-poll surfaces HTTP errors once and clears on recovery"
}

test_poll_graphql_errors_report_controlled_message() {
  local home fakebin out rc
  home="$TMP_ROOT/poll-gqlerr"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'LINEAR_API_KEY=lin_k\nLINEAR_BOT_USER_ID=bot-1\n' > "$home/.env"
  # A GraphQL error arrives as HTTP 200 with an .errors array; the server message
  # is untrusted and must NOT be echoed into the wake line.
  # shellcheck disable=SC2016  # single quotes are deliberate: the metacharacters must stay literal
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY='{"errors":[{"message":"$(rm -rf /) injected"}]}' \
    "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll graphql-error exit"
  [ "$out" = "linear-error Linear GraphQL error" ] \
    || fail "poll must emit a controlled GraphQL error, not the server text (got: $out)"
  pass "fm-linear-poll reports a controlled message for GraphQL errors"
}

test_poll_missing_dep_reports_error() {
  local home fakebin out rc tool tool_path
  home="$TMP_ROOT/poll-nojq"; mkdir -p "$home"
  fakebin=$(fm_fakebin "$home")
  # An isolated PATH with everything the env reader needs EXCEPT jq, plus a curl
  # stub that should never be reached. jq is genuinely absent from this PATH so
  # `command -v jq` fails the way it would on a host without jq.
  fm_fake_exit0 "$fakebin" curl
  for tool in dirname grep tail tr cat mktemp rm mkdir; do
    tool_path=$(command -v "$tool") || fail "test host must provide $tool"
    ln -s "$tool_path" "$fakebin/$tool"
  done
  printf 'LINEAR_API_KEY=lin_k\nLINEAR_BOT_USER_ID=bot-1\n' > "$home/.env"
  out=$(PATH="$fakebin" FM_HOME="$home" \
    "$BASH" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll missing-jq exit"
  [ "$out" = "linear-error missing jq" ] \
    || fail "poll without jq must emit one error and not block (got: $out)"
  pass "fm-linear-poll reports a missing dependency without blocking the watcher"
}

# ---------------------------------------------------------------------------
# Poll: the three wake types, dedupe, and sanitisation

test_poll_ready_wakes_and_dedupes() {
  local home fakebin out rc body
  home="$TMP_ROOT/poll-ready"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'LINEAR_API_KEY=lin_k\nLINEAR_BOT_USER_ID=bot-1\n' > "$home/.env"
  body=$(issue_body '{"id":"iss-r","identifier":"ENG-1","title":"do it","state":{"name":"Ready","type":"unstarted"},"team":{"id":"t","key":"ENG","name":"Eng"},"project":{"id":"p","name":"Web"},"labels":{"nodes":[]},"comments":{"nodes":[]}}')
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$body" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll ready exit"
  [ "$out" = "linear-ready iss-r" ] || fail "a ready bot-assigned ticket must wake (got: $out)"
  assert_present "$home/state/linear-inbox/iss-r.json" "poll must stash the ready issue"
  [ "$(jq -r .event "$home/state/linear-inbox/iss-r.json")" = "linear-ready" ] \
    || fail "stashed inbox must carry the event type"
  [ "$(jq -r .identifier "$home/state/linear-inbox/iss-r.json")" = "ENG-1" ] \
    || fail "stashed inbox must preserve the full issue node"
  # Re-poll with the same state -> deduped, silent.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$body" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll ready re-poll exit"
  [ -z "$out" ] || fail "an already-ready ticket must not re-wake (got: $out)"
  pass "fm-linear-poll wakes on a ready ticket once and dedupes thereafter"
}

test_poll_groom_requires_new_nonbot_comment() {
  local home fakebin out rc b1 b2 b3
  home="$TMP_ROOT/poll-groom"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'LINEAR_API_KEY=lin_k\nLINEAR_BOT_USER_ID=bot-1\n' > "$home/.env"
  # First sight of a backlog item with an existing comment: record marker, no wake.
  b1=$(issue_body '{"id":"iss-g","identifier":"ENG-2","title":"groom","state":{"name":"Backlog","type":"backlog"},"team":{"id":"t","key":"E","name":"E"},"project":{"id":"p","name":"W"},"labels":{"nodes":[]},"comments":{"nodes":[{"id":"c1","createdAt":"2024-01-01T00:00:00.000Z","user":{"id":"alice"}}]}}')
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$b1" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll groom first-sight exit"
  [ -z "$out" ] || fail "first sight of a backlog item must not groom (got: $out)"
  # A newer non-bot comment -> groom.
  b2=$(issue_body '{"id":"iss-g","identifier":"ENG-2","title":"groom","state":{"name":"Backlog","type":"backlog"},"team":{"id":"t","key":"E","name":"E"},"project":{"id":"p","name":"W"},"labels":{"nodes":[]},"comments":{"nodes":[{"id":"c1","createdAt":"2024-01-01T00:00:00.000Z","user":{"id":"alice"}},{"id":"c2","createdAt":"2024-02-02T00:00:00.000Z","user":{"id":"alice"}}]}}')
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$b2" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll groom exit"
  [ "$out" = "linear-groom iss-g" ] || fail "a new non-bot comment must groom (got: $out)"
  [ "$(jq -r .event "$home/state/linear-inbox/iss-g.json")" = "linear-groom" ] \
    || fail "stashed groom inbox must carry the event type"
  # A newer comment authored by the BOT must not groom.
  rm -f "$home/state/linear-inbox/iss-g.json"
  b3=$(issue_body '{"id":"iss-g","identifier":"ENG-2","title":"groom","state":{"name":"Backlog","type":"backlog"},"team":{"id":"t","key":"E","name":"E"},"project":{"id":"p","name":"W"},"labels":{"nodes":[]},"comments":{"nodes":[{"id":"c3","createdAt":"2024-03-03T00:00:00.000Z","user":{"id":"bot-1"}}]}}')
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$b3" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll groom bot-comment exit"
  [ -z "$out" ] || fail "a bot-authored comment must not groom (got: $out)"
  assert_absent "$home/state/linear-inbox/iss-g.json" "a bot-only comment must not stash a groom"
  pass "fm-linear-poll grooms on a new non-bot comment, never on a bot comment"
}

test_poll_groom_after_first_sight_without_comments() {
  local home fakebin out rc b0 b1
  home="$TMP_ROOT/poll-groom-empty"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'LINEAR_API_KEY=lin_k\nLINEAR_BOT_USER_ID=bot-1\n' > "$home/.env"
  # First sight of a backlog item with NO comments: witnessed, but silent.
  b0=$(issue_body '{"id":"iss-ge","identifier":"ENG-9","title":"groom","state":{"name":"Backlog","type":"backlog"},"team":{"id":"t","key":"E","name":"E"},"project":{"id":"p","name":"W"},"labels":{"nodes":[]},"comments":{"nodes":[]}}')
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$b0" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll groom empty first-sight exit"
  [ -z "$out" ] || fail "first sight of a comment-less backlog item must be silent (got: $out)"
  # Its FIRST non-bot comment after watching began must groom (no swallowed comment).
  b1=$(issue_body '{"id":"iss-ge","identifier":"ENG-9","title":"groom","state":{"name":"Backlog","type":"backlog"},"team":{"id":"t","key":"E","name":"E"},"project":{"id":"p","name":"W"},"labels":{"nodes":[]},"comments":{"nodes":[{"id":"c1","createdAt":"2024-05-05T00:00:00.000Z","user":{"id":"alice"}}]}}')
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$b1" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll groom empty exit"
  [ "$out" = "linear-groom iss-ge" ] \
    || fail "the first comment on a witnessed comment-less backlog item must groom (got: $out)"
  [ "$(jq -r .event "$home/state/linear-inbox/iss-ge.json")" = "linear-groom" ] \
    || fail "stashed groom inbox must carry the event type"
  pass "fm-linear-poll grooms the first comment on a witnessed comment-less backlog item"
}

test_poll_groom_no_spurious_wake_on_ready_to_backlog() {
  local home fakebin out rc ready backlog newer
  home="$TMP_ROOT/poll-groom-r2b"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'LINEAR_API_KEY=lin_k\nLINEAR_BOT_USER_ID=bot-1\n' > "$home/.env"
  # First sight in READY state carrying a pre-existing non-bot comment: the comment
  # baseline must be recorded even though the ticket is not in backlog.
  ready=$(issue_body '{"id":"iss-rb","identifier":"ENG-11","title":"x","state":{"name":"Ready","type":"unstarted"},"team":{"id":"t","key":"E","name":"E"},"project":{"id":"p","name":"W"},"labels":{"nodes":[]},"comments":{"nodes":[{"id":"c1","createdAt":"2024-01-01T00:00:00.000Z","user":{"id":"alice"}}]}}')
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$ready" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll groom r2b ready exit"
  [ "$out" = "linear-ready iss-rb" ] || fail "first sight of a ready ticket must wake ready (got: $out)"
  rm -f "$home/state/linear-inbox/iss-rb.json"
  # Moved to BACKLOG carrying that SAME old comment: must NOT groom (no spurious wake).
  backlog=$(issue_body '{"id":"iss-rb","identifier":"ENG-11","title":"x","state":{"name":"Backlog","type":"backlog"},"team":{"id":"t","key":"E","name":"E"},"project":{"id":"p","name":"W"},"labels":{"nodes":[]},"comments":{"nodes":[{"id":"c1","createdAt":"2024-01-01T00:00:00.000Z","user":{"id":"alice"}}]}}')
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$backlog" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll groom r2b backlog exit"
  [ -z "$out" ] || fail "a ready->backlog move with only pre-existing comments must not groom (got: $out)"
  assert_absent "$home/state/linear-inbox/iss-rb.json" "a spurious groom must not stash an inbox"
  # A genuinely newer non-bot comment still grooms.
  newer=$(issue_body '{"id":"iss-rb","identifier":"ENG-11","title":"x","state":{"name":"Backlog","type":"backlog"},"team":{"id":"t","key":"E","name":"E"},"project":{"id":"p","name":"W"},"labels":{"nodes":[]},"comments":{"nodes":[{"id":"c1","createdAt":"2024-01-01T00:00:00.000Z","user":{"id":"alice"}},{"id":"c2","createdAt":"2024-06-06T00:00:00.000Z","user":{"id":"alice"}}]}}')
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$newer" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll groom r2b newer exit"
  [ "$out" = "linear-groom iss-rb" ] || fail "a genuinely newer non-bot comment must groom (got: $out)"
  [ "$(jq -r .event "$home/state/linear-inbox/iss-rb.json")" = "linear-groom" ] \
    || fail "stashed groom inbox must carry the event type"
  pass "fm-linear-poll does not spuriously groom on ready->backlog with pre-existing comments"
}

test_poll_canceled_requires_witnessed_transition() {
  local home fakebin out rc backlog canceled
  home="$TMP_ROOT/poll-cancel"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'LINEAR_API_KEY=lin_k\nLINEAR_BOT_USER_ID=bot-1\n' > "$home/.env"
  backlog=$(issue_body '{"id":"iss-c","identifier":"ENG-3","title":"x","state":{"name":"Backlog","type":"backlog"},"team":{"id":"t","key":"E","name":"E"},"project":{"id":"p","name":"W"},"labels":{"nodes":[]},"comments":{"nodes":[]}}')
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$backlog" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll cancel setup exit"
  [ -z "$out" ] || fail "a backlog item with no comment must be silent (got: $out)"
  # Now moved to canceled -> wake.
  canceled=$(issue_body '{"id":"iss-c","identifier":"ENG-3","title":"x","state":{"name":"Canceled","type":"canceled"},"team":{"id":"t","key":"E","name":"E"},"project":{"id":"p","name":"W"},"labels":{"nodes":[]},"comments":{"nodes":[]}}')
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$canceled" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll cancel exit"
  [ "$out" = "linear-canceled iss-c" ] || fail "a witnessed move to canceled must wake (got: $out)"
  [ "$(jq -r .event "$home/state/linear-inbox/iss-c.json")" = "linear-canceled" ] \
    || fail "stashed canceled inbox must carry the event type"
  pass "fm-linear-poll wakes on a witnessed move to canceled"
}

test_poll_first_sight_canceled_is_silent() {
  local home fakebin out rc canceled
  home="$TMP_ROOT/poll-cancel-fresh"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'LINEAR_API_KEY=lin_k\nLINEAR_BOT_USER_ID=bot-1\n' > "$home/.env"
  canceled=$(issue_body '{"id":"iss-cf","identifier":"ENG-4","title":"x","state":{"name":"Canceled","type":"canceled"},"team":{"id":"t","key":"E","name":"E"},"project":{"id":"p","name":"W"},"labels":{"nodes":[]},"comments":{"nodes":[]}}')
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$canceled" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll fresh-cancel exit"
  [ -z "$out" ] || fail "first sight of an already-canceled ticket must be silent (got: $out)"
  assert_absent "$home/state/linear-inbox/iss-cf.json" "first-sight canceled must not stash"
  pass "fm-linear-poll stays silent on a never-watched canceled ticket"
}

test_poll_rejects_unsafe_issue_id() {
  local home fakebin out rc body
  home="$TMP_ROOT/poll-evil"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'LINEAR_API_KEY=lin_k\nLINEAR_BOT_USER_ID=bot-1\n' > "$home/.env"
  body=$(issue_body '{"id":"../../etc/x","state":{"name":"Ready","type":"unstarted"},"comments":{"nodes":[]}}')
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$body" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll unsafe id exit"
  [ -z "$out" ] || fail "poll must not wake for an unsafe issue id (got: $out)"
  assert_absent "$home/state/linear-inbox/../../etc/x.json" "poll must not write outside the inbox"
  pass "fm-linear-poll rejects an unsafe issue id (path-traversal guard)"
}

test_poll_stash_failure_keeps_at_least_once() {
  local home fakebin out rc body
  home="$TMP_ROOT/poll-stash-fail"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  # A failing mv stub makes the inbox commit fail; the seen marker must not advance.
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/mv"
  printf 'LINEAR_API_KEY=lin_k\nLINEAR_BOT_USER_ID=bot-1\n' > "$home/.env"
  body=$(issue_body '{"id":"iss-sf","identifier":"ENG-7","title":"do it","state":{"name":"Ready","type":"unstarted"},"team":{"id":"t","key":"E","name":"E"},"project":{"id":"p","name":"W"},"labels":{"nodes":[]},"comments":{"nodes":[]}}')
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$body" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll stash failure exit"
  [ "$out" = "linear-error cannot write inbox" ] \
    || fail "a failed inbox stash must emit an error, not a wake (got: $out)"
  assert_absent "$home/state/linear-inbox/iss-sf.json" "a failed stash must not leave an inbox file"
  assert_absent "$home/state/linear-seen/iss-sf.state" "a failed stash must not advance the seen marker"
  # With mv restored, the same ready ticket must re-emit (at-least-once delivery).
  rm -f "$fakebin/mv"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$body" "$ROOT/bin/fm-linear-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll stash recovery exit"
  [ "$out" = "linear-ready iss-sf" ] \
    || fail "a ready ticket whose stash transiently failed must re-emit (got: $out)"
  assert_present "$home/state/linear-seen/iss-sf.state" "a successful stash must advance the seen marker"
  pass "fm-linear-poll re-emits a ready wake after a transient inbox stash failure"
}

# ---------------------------------------------------------------------------
# Library: config, auth header, state classification, resolver, meta links

test_lib_env_over_dotenv_precedence() {
  local home key url
  home="$TMP_ROOT/lib-prec"; mkdir -p "$home"
  printf 'LINEAR_API_KEY=dotenv-key\nLINEAR_API_URL=https://dotenv.test/graphql\n' > "$home/.env"
  read -r key url < <(
    FM_HOME="$home" LINEAR_API_KEY="env-key" bash -c '
      . "'"$ROOT"'/bin/fm-linear-lib.sh"
      linear_load_config
      printf "%s %s\n" "$LINEAR_KEY" "$LINEAR_URL"
    '
  )
  [ "$key" = "env-key" ] || fail "env LINEAR_API_KEY must win over .env (got: $key)"
  [ "$url" = "https://dotenv.test/graphql" ] || fail ".env URL must be used when env is unset (got: $url)"
  # Default URL when neither is set.
  url=$(FM_HOME="$home" LINEAR_API_KEY="k" LINEAR_API_URL="" bash -c '
    . "'"$ROOT"'/bin/fm-linear-lib.sh"; linear_load_config; printf "%s" "$LINEAR_URL"')
  [ "$url" = "https://api.linear.app/graphql" ] || fail "empty URL must default to Linear's endpoint (got: $url)"
  pass "linear_load_config resolves key/url with env-over-.env precedence and a sane default"
}

test_lib_auth_header_raw_key_0600() {
  local home file perms content
  home="$TMP_ROOT/lib-auth"; mkdir -p "$home"
  file=$(FM_HOME="$home" LINEAR_API_KEY="lin_secret" bash -c '
    . "'"$ROOT"'/bin/fm-linear-lib.sh"; linear_load_config; linear_auth_header_file')
  assert_present "$file" "auth header file must be created"
  perms=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null)
  [ "$perms" = "600" ] || fail "auth header file must be mode 600 (got: $perms)"
  content=$(cat "$file")
  [ "$content" = "Authorization: lin_secret" ] \
    || fail "auth header must be the raw key with no Bearer prefix (got: $content)"
  rm -f "$file"
  pass "linear_auth_header_file writes a 0600 raw-key header (no Bearer)"
}

test_lib_state_name_then_type_fallback() {
  local out
  # No configured names: classification falls back to the workflow-state TYPE.
  out=$(FM_HOME="$TMP_ROOT" bash -c '
    . "'"$ROOT"'/bin/fm-linear-lib.sh"; linear_load_config
    printf "%s %s %s %s\n" \
      "$(linear_state_kind Todo unstarted)" \
      "$(linear_state_kind Backlog backlog)" \
      "$(linear_state_kind Canceled canceled)" \
      "$(linear_state_kind "In Progress" started)"')
  [ "$out" = "ready backlog canceled other" ] \
    || fail "type fallback must map unstarted/backlog/canceled (got: $out)"
  # An unconfigured role never matches by name: a state literally named "Backlog"
  # but typed "unstarted" classifies as ready via TYPE, not backlog via name.
  out=$(FM_HOME="$TMP_ROOT" bash -c '
    . "'"$ROOT"'/bin/fm-linear-lib.sh"; linear_load_config
    linear_state_kind Backlog unstarted')
  [ "$out" = "ready" ] \
    || fail "unconfigured role must classify by type, not default name (got: $out)"
  # A configured READY name matches by name and disables the type fallback.
  out=$(FM_HOME="$TMP_ROOT" LINEAR_STATE_READY=Groomed bash -c '
    . "'"$ROOT"'/bin/fm-linear-lib.sh"; linear_load_config
    printf "%s %s %s\n" \
      "$(linear_state_kind Groomed unstarted)" \
      "$(linear_state_kind Ready unstarted)" \
      "$(linear_state_kind Todo unstarted)"')
  [ "$out" = "ready other other" ] \
    || fail "a configured name must match by name and turn off type fallback (got: $out)"
  pass "linear_state_kind matches configured names first, falls back to type otherwise"
}

test_lib_load_config_idempotent() {
  local out
  # Two calls in one process must not disable the type fallback: the resolver
  # writes its result into distinct output vars, never back over the input env.
  out=$(FM_HOME="$TMP_ROOT" bash -c '
    . "'"$ROOT"'/bin/fm-linear-lib.sh"
    linear_load_config
    linear_load_config
    printf "%s %s %s\n" \
      "$(linear_state_kind Todo unstarted)" \
      "$(linear_state_kind Backlog backlog)" \
      "$(linear_state_kind Canceled canceled)"')
  [ "$out" = "ready backlog canceled" ] \
    || fail "repeated linear_load_config must keep the type fallback (got: $out)"
  pass "linear_load_config is idempotent across repeated calls in one process"
}

test_lib_resolve_repo_layers() {
  local home map
  home="$TMP_ROOT/lib-resolve"; mkdir -p "$home/config"
  map="$home/config/linear-projects.tsv"
  printf '# comment\nWeb App\tprojects/web\np-uuid-1\tprojects/byid\nENG\tprojects/eng-team\n' > "$map"
  run() {
    FM_HOME="$home" bash -c '
      . "'"$ROOT"'/bin/fm-linear-lib.sh"
      linear_resolve_repo "$1"' _ "$1"
  }
  [ "$(run '{"labels":["bug","repo:override"],"project":{"name":"Web App"}}')" = "override" ] \
    || fail "a repo: label must override the project map"
  [ "$(run '{"labels":{"nodes":[{"name":"bug"},{"name":"repo:nativeoverride"}]},"project":{"name":"Web App"}}')" = "nativeoverride" ] \
    || fail "a repo: label in Linear's native nodes[].name shape must override the project map"
  [ "$(run '{"repositoryField":"field-repo","project":{"name":"Web App"}}')" = "field-repo" ] \
    || fail "a Repository field must override the project map"
  [ "$(run '{"project":{"id":"x","name":"Web App"}}')" = "projects/web" ] \
    || fail "a project name must resolve via the map"
  [ "$(run '{"project":{"id":"p-uuid-1","name":"Nope"}}')" = "projects/byid" ] \
    || fail "a project id must resolve via the map"
  [ "$(run '{"project":{"name":"Nope"},"team":{"key":"ENG","name":"Engineering"}}')" = "projects/eng-team" ] \
    || fail "a team key must resolve via the map when the project misses"
  [ -z "$(run '{"project":{"name":"Nope"},"team":{"name":"Nope"}}')" ] \
    || fail "an unmatched issue must resolve to empty (unresolved)"
  pass "linear_resolve_repo applies label/field, project, then team precedence"
}

test_lib_meta_link_set_get_clear() {
  local home meta
  home="$TMP_ROOT/lib-meta"; mkdir -p "$home/state"
  meta="$home/state/ship-1.meta"
  printf 'window=w\nkind=ship\nmode=no-mistakes\nyolo=off\n' > "$meta"
  FM_HOME="$home" bash -c '
    . "'"$ROOT"'/bin/fm-linear-lib.sh"
    linear_meta_link_set "'"$meta"'" iss-99 fm/ship-1'
  assert_grep "linear_issue=iss-99" "$meta" "link must record the issue id"
  assert_grep "linear_branch=fm/ship-1" "$meta" "link must record the branch"
  assert_grep "kind=ship" "$meta" "link must preserve other meta lines"
  # Re-linking replaces rather than duplicates.
  FM_HOME="$home" bash -c '
    . "'"$ROOT"'/bin/fm-linear-lib.sh"
    linear_meta_link_set "'"$meta"'" iss-100 fm/ship-1b'
  [ "$(grep -c '^linear_issue=' "$meta")" = "1" ] || fail "re-link must not duplicate linear_issue"
  assert_grep "linear_issue=iss-100" "$meta" "re-link must replace the issue id"
  # get returns the current value.
  local got
  got=$(FM_HOME="$home" bash -c '
    . "'"$ROOT"'/bin/fm-linear-lib.sh"
    linear_meta_get "'"$meta"'" linear_issue')
  [ "$got" = "iss-100" ] || fail "linear_meta_get must read the linked issue (got: $got)"
  # clear removes the link, preserving other lines.
  FM_HOME="$home" bash -c '
    . "'"$ROOT"'/bin/fm-linear-lib.sh"
    linear_meta_link_clear "'"$meta"'"'
  assert_no_grep "linear_issue=" "$meta" "clear must remove the link"
  assert_grep "kind=ship" "$meta" "clear must preserve other meta lines"
  pass "linear_meta_link_set/get/clear round-trip without disturbing meta"
}

# ---------------------------------------------------------------------------
# Bootstrap: .env-presence activation

test_bootstrap_activates_on_env_key() {
  local home out sum1 sum2 n inherited
  home="$TMP_ROOT/boot-on"; mkdir -p "$home"
  printf 'LINEAR_API_KEY=lin_boot\n' > "$home/.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "LINEARMODE: Linear mode on" "bootstrap must announce Linear mode"
  assert_present "$home/state/linear-watch.check.sh" "bootstrap must drop the check shim"
  [ -x "$home/state/linear-watch.check.sh" ] || fail "the check shim must be executable"
  assert_grep "fm-linear-poll.sh" "$home/state/linear-watch.check.sh" "the shim must exec the poll script"
  assert_present "$home/config/linear.env" "bootstrap must drop the cadence config"
  assert_grep "export FM_CHECK_INTERVAL=60" "$home/config/linear.env" "cadence must be 60s"
  # shellcheck source=/dev/null
  inherited=$( . "$home/config/linear.env" && bash -c 'echo "${FM_CHECK_INTERVAL:-300}"' )
  [ "$inherited" = "60" ] || fail "sourcing the cadence config must export FM_CHECK_INTERVAL=60"
  # Idempotent.
  sum1=$(cat "$home/state/linear-watch.check.sh" "$home/config/linear.env" | shasum)
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  sum2=$(cat "$home/state/linear-watch.check.sh" "$home/config/linear.env" | shasum)
  [ "$sum1" = "$sum2" ] || fail "bootstrap Linear-mode setup must be idempotent"
  n=$(find "$home/state" -maxdepth 1 -name 'linear-watch*' | wc -l | tr -d ' ')
  [ "$n" = "1" ] || fail "bootstrap must not duplicate the shim (found $n)"
  pass "bootstrap activates Linear mode from an .env key, idempotently"
}

test_bootstrap_inert_without_key() {
  local home out
  home="$TMP_ROOT/boot-off"; mkdir -p "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "LINEARMODE" "bootstrap must say nothing about Linear without a key"
  assert_absent "$home/state/linear-watch.check.sh" "no key -> no check shim"
  assert_absent "$home/config/linear.env" "no key -> no cadence config"
  # .env present but key empty -> still off.
  home="$TMP_ROOT/boot-empty"; mkdir -p "$home"
  printf 'LINEAR_API_KEY=\n' > "$home/.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "LINEARMODE" "an empty key must be treated as off"
  assert_absent "$home/state/linear-watch.check.sh" "empty key -> no check shim"
  pass "bootstrap is inert without a non-empty .env key (non-Linear users unaffected)"
}

test_bootstrap_opt_out_cleanup() {
  local home out
  home="$TMP_ROOT/boot-optout"; mkdir -p "$home"
  printf 'LINEAR_API_KEY=lin_out\n' > "$home/.env"
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_present "$home/state/linear-watch.check.sh" "opt-in must create the shim"
  assert_present "$home/config/linear.env" "opt-in must create the cadence config"
  printf 'LINEAR_API_KEY=\n' > "$home/.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "LINEARMODE: Linear mode off" "opt-out must announce Linear mode off"
  assert_absent "$home/state/linear-watch.check.sh" "opt-out must remove the shim"
  assert_absent "$home/config/linear.env" "opt-out must remove the cadence config"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "LINEARMODE" "steady-state off must be silent"
  pass "bootstrap cleans up Linear artifacts on opt-out and is silent once off"
}

test_bootstrap_reports_missing_dependency() {
  local home fakebin out tool tool_path
  home="$TMP_ROOT/boot-missing"; mkdir -p "$home"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux node no-mistakes gh-axi chrome-devtools-axi lavish-axi curl
  for tool in dirname grep tail; do
    tool_path=$(command -v "$tool") || fail "test host must provide $tool"
    ln -s "$tool_path" "$fakebin/$tool"
  done
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf 'LINEAR_API_KEY=lin_missing\n' > "$home/.env"
  out=$(PATH="$fakebin" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    "$BASH" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "MISSING: jq" "bootstrap must report missing jq when Linear mode is opted in"
  assert_contains "$out" "LINEARMODE: Linear mode off" "bootstrap must not arm Linear mode with a missing dep"
  assert_not_contains "$out" "LINEARMODE: Linear mode on" "bootstrap must not announce Linear mode on with a missing dep"
  assert_absent "$home/state/linear-watch.check.sh" "missing jq must not arm the check shim"
  assert_absent "$home/config/linear.env" "missing jq must not write the cadence config"
  pass "bootstrap reports a missing Linear dependency before arming"
}

test_poll_no_key_is_hard_noop
test_poll_empty_env_key_overrides_env_file
test_poll_missing_bot_reports_error
test_poll_sends_raw_key_to_graphql
test_poll_http_error_reports_once
test_poll_graphql_errors_report_controlled_message
test_poll_missing_dep_reports_error
test_poll_ready_wakes_and_dedupes
test_poll_groom_requires_new_nonbot_comment
test_poll_groom_after_first_sight_without_comments
test_poll_groom_no_spurious_wake_on_ready_to_backlog
test_poll_canceled_requires_witnessed_transition
test_poll_first_sight_canceled_is_silent
test_poll_rejects_unsafe_issue_id
test_poll_stash_failure_keeps_at_least_once
test_lib_env_over_dotenv_precedence
test_lib_auth_header_raw_key_0600
test_lib_state_name_then_type_fallback
test_lib_load_config_idempotent
test_lib_resolve_repo_layers
test_lib_meta_link_set_get_clear
test_bootstrap_activates_on_env_key
test_bootstrap_inert_without_key
test_bootstrap_opt_out_cleanup
test_bootstrap_reports_missing_dependency
