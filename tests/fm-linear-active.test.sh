#!/usr/bin/env bash
# Behavior tests for Linear mode slice 2: the active consume-and-ship lifecycle.
# Covers the helper CLIs (issue/comment/move/link), the risk-rubric evaluator and
# repo-resolution wiring, the fm-pr-check.sh pr-feedback extension, and the Linear
# brief scaffold variant.
#
# Everything stays hermetic: the Linear GraphQL endpoint and the gh CLI are stubbed
# with fakebins so there are no ports, no servers, and deterministic CI. jq stays
# the real tool. This is the slice-2 companion to tests/fm-linear-mode.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-linear-active-tests)

# A fakebin `curl` mimicking the Linear GraphQL endpoint, identical in shape to the
# slice-1 stub: it logs each call to FAKE_CURL_LOG, writes FAKE_GQL_BODY to the -o
# file, and prints FAKE_GQL_CODE as the HTTP code. Both calls in a two-step helper
# (move) get the same body, which is built to satisfy both the query and mutation.
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

# A fakebin `gh` reproducing just `gh pr view <url> --json <field> -q <jqexpr>`:
# it reads the canned JSON for the requested field from env (GH_STATE_JSON /
# GH_REVIEWS_JSON) and applies the -q jq expression exactly as real gh would.
make_fake_gh() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
json="" q=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=$2; shift 2 ;;
    -q|--jq) q=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$json" in
  state) src="${GH_STATE_JSON:-}" ;;
  reviews) src="${GH_REVIEWS_JSON:-}" ;;
  *) src="" ;;
esac
[ -z "$src" ] && exit 0
if [ -n "$q" ]; then printf '%s' "$src" | jq -r "$q"; else printf '%s' "$src"; fi
exit 0
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$fakebin"
}

# ---------------------------------------------------------------------------
# fm-linear-link

test_link_records_issue_and_branch() {
  local home meta
  home="$TMP_ROOT/link"; mkdir -p "$home/state"
  meta="$home/state/ship-a.meta"
  printf 'window=w\nkind=ship\nmode=no-mistakes\nyolo=off\n' > "$meta"
  FM_HOME="$home" "$ROOT/bin/fm-linear-link.sh" ship-a iss-7 markswift/eng-7-x >/dev/null
  assert_grep "linear_issue=iss-7" "$meta" "link must record the issue id"
  assert_grep "linear_branch=markswift/eng-7-x" "$meta" "link must record the branch"
  assert_grep "kind=ship" "$meta" "link must preserve other meta lines"
  pass "fm-linear-link records issue+branch and preserves meta"
}

test_link_rejects_unsafe_and_missing() {
  local home rc
  home="$TMP_ROOT/link-bad"; mkdir -p "$home/state"
  FM_HOME="$home" "$ROOT/bin/fm-linear-link.sh" "../evil" iss-1 >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "unsafe task id must be rejected"
  FM_HOME="$home" "$ROOT/bin/fm-linear-link.sh" ship-x "../evil" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "unsafe issue id must be rejected"
  FM_HOME="$home" "$ROOT/bin/fm-linear-link.sh" no-such iss-1 >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a missing meta must fail"
  pass "fm-linear-link rejects unsafe ids and a missing task"
}

# ---------------------------------------------------------------------------
# fm-linear-comment

test_comment_dry_run_records_not_posts() {
  local home out rec
  home="$TMP_ROOT/comment-dry"; mkdir -p "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LINEAR_DRY_RUN=1 \
    "$ROOT/bin/fm-linear-comment.sh" iss-9 "Captain, please sharpen the acceptance criteria." 2>/dev/null); rc=$?
  expect_code 0 "$rc" "comment dry-run exit"
  [ "$out" = "iss-9" ] || fail "comment dry-run must echo the issue id (got: $out)"
  rec="$home/state/linear-outbox/iss-9.json"
  assert_present "$rec" "comment dry-run must record the would-be comment"
  [ "$(jq -r .endpoint "$rec")" = "commentCreate" ] || fail "outbox must mark the endpoint"
  [ "$(jq -r .body "$rec")" = "Captain, please sharpen the acceptance criteria." ] \
    || fail "outbox must record the body verbatim"
  pass "fm-linear-comment dry-run records the would-be comment and never posts"
}

test_comment_empty_body_rejected() {
  local home rc
  home="$TMP_ROOT/comment-empty"; mkdir -p "$home"
  PATH="$BASE_PATH" FM_HOME="$home" LINEAR_DRY_RUN=1 \
    "$ROOT/bin/fm-linear-comment.sh" iss-1 "   " >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "whitespace-only body must be rejected"
  pass "fm-linear-comment rejects an empty/whitespace body"
}

test_comment_live_posts_body_as_variable() {
  local home fakebin log out rc data
  home="$TMP_ROOT/comment-live"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'LINEAR_API_KEY=lin_k\n' > "$home/.env"
  # An untrusted-looking body with shell metacharacters must reach the API as a
  # JSON variable, never interpolated into the curl command.
  # shellcheck disable=SC2016  # single quotes are deliberate: the metacharacters must stay literal
  printf '%s' 'Groom note $(touch /tmp/pwned) `id` "quote"' > "$home/note.txt"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_CURL_LOG="$log" FAKE_GQL_CODE=200 \
    FAKE_GQL_BODY='{"data":{"commentCreate":{"success":true,"comment":{"id":"c1"}}}}' \
    "$ROOT/bin/fm-linear-comment.sh" iss-5 --text-file "$home/note.txt"); rc=$?
  expect_code 0 "$rc" "comment live exit"
  [ "$out" = "iss-5" ] || fail "comment must echo the issue id on success (got: $out)"
  [ ! -e /tmp/pwned ] || { rm -f /tmp/pwned; fail "comment body must never be executed"; }
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  # shellcheck disable=SC2016  # single quotes are deliberate: compare against the literal metacharacters
  [ "$(printf '%s' "$data" | jq -r '.variables.body')" = 'Groom note $(touch /tmp/pwned) `id` "quote"' ] \
    || fail "comment body must be sent as a JSON variable, verbatim"
  [ "$(printf '%s' "$data" | jq -r '.variables.issueId')" = "iss-5" ] \
    || fail "comment must send the issue id as a variable"
  assert_grep "auth=Authorization: lin_k" "$log" "comment must send the raw key (no Bearer)"
  pass "fm-linear-comment posts the body safely as a GraphQL variable"
}

# ---------------------------------------------------------------------------
# fm-linear-issue

test_issue_no_key_is_inert() {
  local home rc
  home="$TMP_ROOT/issue-nokey"; mkdir -p "$home"
  PATH="$BASE_PATH" FM_HOME="$home" LINEAR_API_KEY='' \
    "$ROOT/bin/fm-linear-issue.sh" iss-1 >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "issue without a key must not run"
  pass "fm-linear-issue is inert without a key"
}

test_issue_prints_fields() {
  local home fakebin out rc body
  home="$TMP_ROOT/issue"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'LINEAR_API_KEY=lin_k\n' > "$home/.env"
  body='{"data":{"issue":{"id":"iss-1","identifier":"ENG-12","title":"Fix the thing","description":"do it well","branchName":"markswift/eng-12-fix","url":"https://linear.app/x/ENG-12","state":{"name":"Todo","type":"unstarted"},"assignee":{"id":"bot","name":"Firstmate Bot"},"team":{"id":"t","key":"ENG","name":"Eng"},"project":{"id":"p","name":"Web"},"labels":{"nodes":[{"name":"bug"}]},"comments":{"nodes":[{"createdAt":"2024-01-01T00:00:00.000Z","user":{"name":"alice"},"body":"hello"}]}}}}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$body" "$ROOT/bin/fm-linear-issue.sh" iss-1); rc=$?
  expect_code 0 "$rc" "issue exit"
  assert_contains "$out" "identifier: ENG-12" "issue must print the identifier"
  assert_contains "$out" "branchName: markswift/eng-12-fix" "issue must print the branchName"
  assert_contains "$out" "Fix the thing" "issue must print the title"
  assert_contains "$out" "alice: hello" "issue must print recent comments"
  pass "fm-linear-issue fetches and prints the ticket fields"
}

# ---------------------------------------------------------------------------
# fm-linear-move

test_move_in_progress_resolves_state_id() {
  local home fakebin log out rc data
  home="$TMP_ROOT/move-prog"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'LINEAR_API_KEY=lin_k\n' > "$home/.env"
  # One body serves both calls: the states query reads .data.issue.team.states,
  # the mutation reads .data.issueUpdate.
  local body='{"data":{"issue":{"id":"iss-1","team":{"states":{"nodes":[{"id":"st-todo","name":"Todo","type":"unstarted"},{"id":"st-prog","name":"In Progress","type":"started"},{"id":"st-rev","name":"In Review","type":"started"}]}}},"issueUpdate":{"success":true,"issue":{"id":"iss-1","state":{"name":"In Progress"}}}}}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_CURL_LOG="$log" FAKE_GQL_CODE=200 FAKE_GQL_BODY="$body" \
    "$ROOT/bin/fm-linear-move.sh" iss-1 in-progress); rc=$?
  expect_code 0 "$rc" "move in-progress exit"
  assert_contains "$out" "moved iss-1 to in-progress" "move must confirm the transition"
  # The mutation (last call) must carry the resolved In Progress state id.
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  [ "$(printf '%s' "$data" | jq -r '.variables.stateId')" = "st-prog" ] \
    || fail "move in-progress must send the In Progress state id"
  pass "fm-linear-move resolves and applies the In Progress state by name"
}

test_move_in_review_resolves_state_id() {
  local home fakebin log out rc data
  home="$TMP_ROOT/move-rev"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'LINEAR_API_KEY=lin_k\n' > "$home/.env"
  local body='{"data":{"issue":{"id":"iss-2","team":{"states":{"nodes":[{"id":"st-prog","name":"In Progress","type":"started"},{"id":"st-rev","name":"In Review","type":"started"}]}}},"issueUpdate":{"success":true,"issue":{"id":"iss-2","state":{"name":"In Review"}}}}}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_CURL_LOG="$log" FAKE_GQL_CODE=200 FAKE_GQL_BODY="$body" \
    "$ROOT/bin/fm-linear-move.sh" iss-2 in-review); rc=$?
  expect_code 0 "$rc" "move in-review exit"
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  [ "$(printf '%s' "$data" | jq -r '.variables.stateId')" = "st-rev" ] \
    || fail "move in-review must send the In Review state id (name match, not type)"
  pass "fm-linear-move resolves In Review by name despite both being 'started' type"
}

test_move_type_fallback_for_custom_in_progress() {
  local home fakebin log out rc data
  home="$TMP_ROOT/move-fallback"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'LINEAR_API_KEY=lin_k\n' > "$home/.env"
  # No state literally named "In Progress"; an unconfigured in-progress role falls
  # back to the lowest-position "started"-typed state. The states are ordered so the
  # lowest-position started state ("Doing", position 2) is NOT first in the array
  # (another started state, "In Review" at position 5, precedes it), proving the
  # pick is deterministic by workflow position, not API array order.
  local body='{"data":{"issue":{"id":"iss-3","team":{"states":{"nodes":[{"id":"st-todo","name":"Todo","type":"unstarted","position":1},{"id":"st-rev","name":"In Review","type":"started","position":5},{"id":"st-doing","name":"Doing","type":"started","position":2}]}}},"issueUpdate":{"success":true,"issue":{"id":"iss-3","state":{"name":"Doing"}}}}}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_CURL_LOG="$log" FAKE_GQL_CODE=200 FAKE_GQL_BODY="$body" \
    "$ROOT/bin/fm-linear-move.sh" iss-3 in-progress); rc=$?
  expect_code 0 "$rc" "move fallback exit"
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  [ "$(printf '%s' "$data" | jq -r '.variables.stateId')" = "st-doing" ] \
    || fail "in-progress must fall back to the lowest-position started state, not array order"
  # A configured name override resolves the custom in-progress state directly.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_CURL_LOG="$log" FAKE_GQL_CODE=200 FAKE_GQL_BODY="$body" \
    LINEAR_STATE_IN_PROGRESS=Doing \
    "$ROOT/bin/fm-linear-move.sh" iss-3 in-progress); rc=$?
  expect_code 0 "$rc" "move configured-name exit"
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  [ "$(printf '%s' "$data" | jq -r '.variables.stateId')" = "st-doing" ] \
    || fail "a configured in-progress name must resolve the state"
  pass "fm-linear-move falls back to the started type and honors a configured name"
}

test_move_rejects_unknown_role() {
  local home rc
  home="$TMP_ROOT/move-badrole"; mkdir -p "$home"
  PATH="$BASE_PATH" FM_HOME="$home" LINEAR_API_KEY=k \
    "$ROOT/bin/fm-linear-move.sh" iss-1 bogus >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "an unknown role must be a usage error"
  pass "fm-linear-move rejects an unknown role"
}

test_move_no_matching_state_holds() {
  local home fakebin rc
  home="$TMP_ROOT/move-nomatch"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'LINEAR_API_KEY=lin_k\n' > "$home/.env"
  # in-review has no type fallback; with no "In Review" state it must fail cleanly.
  local body='{"data":{"issue":{"id":"iss-4","team":{"states":{"nodes":[{"id":"st-todo","name":"Todo","type":"unstarted"}]}}}}}'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    FAKE_GQL_CODE=200 FAKE_GQL_BODY="$body" \
    "$ROOT/bin/fm-linear-move.sh" iss-4 in-review >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "an unresolvable in-review must fail, not guess"
  pass "fm-linear-move fails cleanly when no state matches the role"
}

test_move_dry_run_resolves_but_suppresses_write() {
  local home fakebin log out rc body posts
  home="$TMP_ROOT/move-dry"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'LINEAR_API_KEY=lin_k\n' > "$home/.env"
  # In Review is returned BEFORE In Progress and has a lower-precedence position;
  # the position sort must still pick In Progress (st-prog, position 1).
  body='{"data":{"issue":{"id":"iss-d","team":{"states":{"nodes":[{"id":"st-rev","name":"In Review","type":"started","position":2},{"id":"st-prog","name":"In Progress","type":"started","position":1}]}}},"issueUpdate":{"success":true,"issue":{"id":"iss-d","state":{"name":"In Progress"}}}}}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LINEAR_API_URL="https://linear.test/graphql" \
    LINEAR_DRY_RUN=1 FAKE_CURL_LOG="$log" FAKE_GQL_CODE=200 FAKE_GQL_BODY="$body" \
    "$ROOT/bin/fm-linear-move.sh" iss-d in-progress); rc=$?
  expect_code 0 "$rc" "move dry-run exit"
  assert_contains "$out" "moved iss-d to in-progress (dry-run)" "dry-run must echo the would-be move"
  # The resolved transition is recorded under a DISTINCT .move.json key.
  assert_present "$home/state/linear-outbox/iss-d.move.json" "move dry-run must record the would-be transition"
  assert_absent "$home/state/linear-outbox/iss-d.json" "move preview must not collide with a comment preview key"
  [ "$(jq -r .stateId "$home/state/linear-outbox/iss-d.move.json")" = "st-prog" ] \
    || fail "dry-run must record the resolved In Progress state id (position-sorted)"
  [ "$(jq -r .endpoint "$home/state/linear-outbox/iss-d.move.json")" = "issueUpdate" ] \
    || fail "dry-run record must mark the endpoint"
  # The READ happened (resolution needs it) but the WRITE did not: exactly one POST,
  # and the log never carries the issueUpdate mutation.
  posts=$(grep -c '^method=POST' "$log" 2>/dev/null || echo 0)
  [ "$posts" = "1" ] || fail "move dry-run must do exactly one call (the states read), got $posts"
  grep -F 'issueUpdate' "$log" >/dev/null 2>&1 && fail "move dry-run must not send the issueUpdate mutation"
  pass "fm-linear-move dry-run resolves the state via the read but suppresses the write"
}

test_move_dry_run_needs_key_for_read() {
  local home rc
  home="$TMP_ROOT/move-dry-nokey"; mkdir -p "$home"
  # Unlike a comment dry-run (fully offline), a move dry-run still needs the key for
  # the states read; with no key it must refuse rather than pretend to resolve.
  PATH="$BASE_PATH" FM_HOME="$home" LINEAR_API_KEY='' LINEAR_DRY_RUN=1 \
    "$ROOT/bin/fm-linear-move.sh" iss-x in-progress >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "move dry-run without a key must fail (the read needs it)"
  assert_absent "$home/state/linear-outbox/iss-x.move.json" "no key -> no dry-run record"
  pass "fm-linear-move dry-run still requires the key for the states read"
}

# ---------------------------------------------------------------------------
# Risk rubric (fm-linear-risk)

test_risk_go_when_all_clear() {
  local out rc
  out=$(FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-linear-risk.sh" \
    --repo projects/web --localized --clear-criteria --inflight-count 0 --cap 1); rc=$?
  expect_code 0 "$rc" "a fully clear ticket must be GO"
  assert_contains "$out" "GO" "verdict must be GO"
  pass "fm-linear-risk returns GO when every condition is satisfied"
}

test_risk_each_hard_stop_holds() {
  local flag out rc
  for flag in --security --migration --public-api --cicd --large-blast-radius \
              --ambiguous --overlaps-inflight --depends-unmerged; do
    out=$(FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-linear-risk.sh" \
      --repo projects/web --localized --clear-criteria "$flag"); rc=$?
    expect_code 1 "$rc" "hard-stop $flag must HOLD"
    case "$out" in HOLD*) : ;; *) fail "verdict for $flag must be HOLD (got: $out)" ;; esac
  done
  pass "fm-linear-risk HOLDs on every hard-stop class"
}

test_risk_unresolved_repo_holds() {
  local out rc
  out=$(FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-linear-risk.sh" --localized --clear-criteria); rc=$?
  expect_code 1 "$rc" "an unresolved repo must HOLD"
  assert_contains "$out" "repo unresolved" "HOLD reason must name the unresolved repo"
  pass "fm-linear-risk HOLDs when the repo is unresolved"
}

test_risk_uncertainty_defaults_to_hold() {
  local out rc
  # Missing --localized / --clear-criteria => uncertainty => HOLD.
  out=$(FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-linear-risk.sh" --repo projects/web); rc=$?
  expect_code 1 "$rc" "uncertainty must default to HOLD"
  assert_contains "$out" "not confirmed localized" "HOLD must cite missing localization"
  assert_contains "$out" "no confirmed clear" "HOLD must cite missing acceptance criteria"
  pass "fm-linear-risk defaults to HOLD under uncertainty"
}

test_risk_at_cap_holds_even_when_clear() {
  local out rc
  out=$(FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-linear-risk.sh" \
    --repo projects/web --localized --clear-criteria --inflight-count 1 --cap 1); rc=$?
  expect_code 1 "$rc" "a GO-eligible ticket at cap must wait (HOLD)"
  assert_contains "$out" "in-flight cap" "HOLD must cite the in-flight cap"
  pass "fm-linear-risk HOLDs a clear ticket when the repo is at its in-flight cap"
}

test_risk_cap_from_env() {
  local out rc
  # A configurable cap of 2 lets a second ticket through.
  out=$(FM_HOME="$TMP_ROOT" LINEAR_INFLIGHT_CAP=2 "$ROOT/bin/fm-linear-risk.sh" \
    --repo projects/web --localized --clear-criteria --inflight-count 1); rc=$?
  expect_code 0 "$rc" "a higher configured cap must allow a second in-flight task"
  pass "fm-linear-risk honors a configurable in-flight cap"
}

# ---------------------------------------------------------------------------
# Repo resolution wired into the dispatch decision

test_resolve_repo_feeds_risk_gate() {
  local home map resolved out rc
  home="$TMP_ROOT/dispatch"; mkdir -p "$home/config"
  map="$home/config/linear-projects.tsv"
  printf 'Web App\tprojects/web\n' > "$map"
  # A resolvable ticket -> repo populated -> GO (other conditions clear).
  resolved=$(FM_HOME="$home" bash -c '
    . "'"$ROOT"'/bin/fm-linear-lib.sh"
    linear_resolve_repo "$1"' _ '{"project":{"name":"Web App"}}')
  [ "$resolved" = "projects/web" ] || fail "resolver must map the project (got: $resolved)"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-linear-risk.sh" \
    --repo "$resolved" --localized --clear-criteria); rc=$?
  expect_code 0 "$rc" "a resolved repo must let a clear ticket GO"
  # An unresolvable ticket -> empty repo -> HOLD at the gate.
  resolved=$(FM_HOME="$home" bash -c '
    . "'"$ROOT"'/bin/fm-linear-lib.sh"
    linear_resolve_repo "$1"' _ '{"project":{"name":"Unknown"},"team":{"name":"Unknown"}}')
  [ -z "$resolved" ] || fail "resolver must return empty for an unmapped ticket (got: $resolved)"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-linear-risk.sh" \
    --repo "$resolved" --localized --clear-criteria); rc=$?
  expect_code 1 "$rc" "an unresolved repo must HOLD at the gate"
  pass "repo resolution feeds the risk gate: resolved -> GO, unresolved -> HOLD"
}

# ---------------------------------------------------------------------------
# fm-pr-check: pr-feedback wake (additive to merge detection)

test_pr_check_feedback_wakes_once_then_dedupes() {
  local home fakebin shim out
  home="$TMP_ROOT/prfb"; mkdir -p "$home/state"
  # A Linear-linked task (meta has linear_issue=) arms the feedback path.
  printf 'linear_issue=iss-x\n' > "$home/state/prfb.meta"
  fakebin=$(make_fake_gh "$home")
  # Arm with no reviews yet: the cursor baselines to empty.
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    GH_REVIEWS_JSON='{"reviews":[]}' \
    "$ROOT/bin/fm-pr-check.sh" prfb https://github.com/o/r/pull/1 >/dev/null 2>&1
  shim="$home/state/prfb.check.sh"
  assert_present "$shim" "fm-pr-check must arm the check shim"
  # No reviews -> silence.
  out=$(PATH="$fakebin:$BASE_PATH" GH_STATE_JSON='{"state":"OPEN"}' GH_REVIEWS_JSON='{"reviews":[]}' bash "$shim")
  [ -z "$out" ] || fail "no reviews must be silent (got: $out)"
  # A changes-requested review -> wakes once.
  out=$(PATH="$fakebin:$BASE_PATH" GH_STATE_JSON='{"state":"OPEN"}' \
    GH_REVIEWS_JSON='{"reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2024-02-02T00:00:00Z"}]}' bash "$shim")
  [ "$out" = "pr-feedback prfb" ] || fail "a new changes-requested review must wake (got: $out)"
  # Same review again -> deduped, silent.
  out=$(PATH="$fakebin:$BASE_PATH" GH_STATE_JSON='{"state":"OPEN"}' \
    GH_REVIEWS_JSON='{"reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2024-02-02T00:00:00Z"}]}' bash "$shim")
  [ -z "$out" ] || fail "the same review must not re-wake (got: $out)"
  # A newer review comment -> wakes again.
  out=$(PATH="$fakebin:$BASE_PATH" GH_STATE_JSON='{"state":"OPEN"}' \
    GH_REVIEWS_JSON='{"reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2024-02-02T00:00:00Z"},{"state":"COMMENTED","submittedAt":"2024-03-03T00:00:00Z"}]}' bash "$shim")
  [ "$out" = "pr-feedback prfb" ] || fail "a newer review must wake again (got: $out)"
  pass "fm-pr-check surfaces a new review once and dedupes thereafter"
}

test_pr_check_merge_not_regressed() {
  local home fakebin shim out
  home="$TMP_ROOT/prmerge"; mkdir -p "$home/state"
  printf 'linear_issue=iss-x\n' > "$home/state/prmerge.meta"
  fakebin=$(make_fake_gh "$home")
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    GH_REVIEWS_JSON='{"reviews":[]}' \
    "$ROOT/bin/fm-pr-check.sh" prmerge https://github.com/o/r/pull/2 >/dev/null 2>&1
  shim="$home/state/prmerge.check.sh"
  # A merged PR still wakes "merged" and does NOT also emit feedback.
  out=$(PATH="$fakebin:$BASE_PATH" GH_STATE_JSON='{"state":"MERGED"}' \
    GH_REVIEWS_JSON='{"reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2024-02-02T00:00:00Z"}]}' bash "$shim")
  [ "$out" = "merged" ] || fail "a merged PR must wake 'merged' only (got: $out)"
  pass "fm-pr-check merge detection is not regressed by the feedback path"
}

test_pr_check_baseline_silences_preexisting_review() {
  local home fakebin shim out
  home="$TMP_ROOT/prbase"; mkdir -p "$home/state"
  printf 'linear_issue=iss-x\n' > "$home/state/prbase.meta"
  fakebin=$(make_fake_gh "$home")
  # Arm while a review already exists: the cursor baselines to it, so it is silent.
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    GH_REVIEWS_JSON='{"reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2024-01-01T00:00:00Z"}]}' \
    "$ROOT/bin/fm-pr-check.sh" prbase https://github.com/o/r/pull/3 >/dev/null 2>&1
  shim="$home/state/prbase.check.sh"
  out=$(PATH="$fakebin:$BASE_PATH" GH_STATE_JSON='{"state":"OPEN"}' \
    GH_REVIEWS_JSON='{"reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2024-01-01T00:00:00Z"}]}' bash "$shim")
  [ -z "$out" ] || fail "a review predating arming must be baselined silent (got: $out)"
  # A genuinely newer review still wakes.
  out=$(PATH="$fakebin:$BASE_PATH" GH_STATE_JSON='{"state":"OPEN"}' \
    GH_REVIEWS_JSON='{"reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2024-01-01T00:00:00Z"},{"state":"CHANGES_REQUESTED","submittedAt":"2024-05-05T00:00:00Z"}]}' bash "$shim")
  [ "$out" = "pr-feedback prbase" ] || fail "a newer review after baselining must wake (got: $out)"
  pass "fm-pr-check baselines pre-existing reviews so only new feedback wakes"
}

test_pr_check_non_linear_arms_merge_only() {
  local home fakebin shim out
  home="$TMP_ROOT/prnonlin"; mkdir -p "$home/state"
  # No linear_issue= meta: a non-Linear task must arm the merge-only shim.
  printf 'kind=ship\nmode=no-mistakes\n' > "$home/state/prnonlin.meta"
  fakebin=$(make_fake_gh "$home")
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    GH_REVIEWS_JSON='{"reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2024-01-01T00:00:00Z"}]}' \
    "$ROOT/bin/fm-pr-check.sh" prnonlin https://github.com/o/r/pull/4 >/dev/null 2>&1
  shim="$home/state/prnonlin.check.sh"
  assert_present "$shim" "fm-pr-check must arm a check shim for a non-Linear task"
  assert_absent "$home/state/prnonlin.pr-feedback-seen" "a non-Linear task must create no feedback cursor"
  assert_no_grep "pr-feedback" "$shim" "the non-Linear shim must not contain the feedback path"
  # A new review must NEVER wake pr-feedback for a non-Linear task.
  out=$(PATH="$fakebin:$BASE_PATH" GH_STATE_JSON='{"state":"OPEN"}' \
    GH_REVIEWS_JSON='{"reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2024-02-02T00:00:00Z"}]}' bash "$shim")
  [ -z "$out" ] || fail "a non-Linear task must never wake on review feedback (got: $out)"
  # Merge detection still works.
  out=$(PATH="$fakebin:$BASE_PATH" GH_STATE_JSON='{"state":"MERGED"}' \
    GH_REVIEWS_JSON='{"reviews":[]}' bash "$shim")
  [ "$out" = "merged" ] || fail "a non-Linear merged PR must still wake 'merged' (got: $out)"
  pass "fm-pr-check arms a merge-only shim for a non-Linear task"
}

# ---------------------------------------------------------------------------
# Brief scaffold: Linear variant vs default

test_brief_linear_variant() {
  local home brief
  home="$TMP_ROOT/brief-lin"; mkdir -p "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ship-l myrepo --linear-branch markswift/eng-22-do >/dev/null
  brief="$home/data/ship-l/brief.md"
  assert_grep "git checkout -b markswift/eng-22-do" "$brief" "Linear brief must branch on the exact branchName"
  assert_no_grep "git checkout -b fm/ship-l" "$brief" "Linear brief must not use the fm/<id> branch"
  assert_grep "Linear ship contract" "$brief" "Linear brief must carry the Linear ship contract"
  assert_grep "WIP-on-blocker" "$brief" "Linear brief must include the WIP-on-blocker clause"
  assert_grep "NEVER through Linear comments" "$brief" "Linear brief must route decisions through firstmate"
  # Still the no-mistakes ship contract underneath.
  assert_grep "/no-mistakes" "$brief" "Linear brief must keep the no-mistakes ship contract"
  pass "fm-brief --linear-branch emits the Linear ship contract on the branchName"
}

test_brief_default_unchanged() {
  local home brief
  home="$TMP_ROOT/brief-def"; mkdir -p "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ship-d myrepo >/dev/null
  brief="$home/data/ship-d/brief.md"
  assert_grep "git checkout -b fm/ship-d" "$brief" "default brief must keep the fm/<id> branch"
  assert_no_grep "Linear ship contract" "$brief" "default brief must not carry the Linear contract"
  assert_no_grep "WIP-on-blocker" "$brief" "default brief must not carry the WIP clause"
  pass "fm-brief default (non-Linear) contract is unchanged"
}

# ---------------------------------------------------------------------------

test_link_records_issue_and_branch
test_link_rejects_unsafe_and_missing
test_comment_dry_run_records_not_posts
test_comment_empty_body_rejected
test_comment_live_posts_body_as_variable
test_issue_no_key_is_inert
test_issue_prints_fields
test_move_in_progress_resolves_state_id
test_move_in_review_resolves_state_id
test_move_type_fallback_for_custom_in_progress
test_move_rejects_unknown_role
test_move_no_matching_state_holds
test_move_dry_run_resolves_but_suppresses_write
test_move_dry_run_needs_key_for_read
test_risk_go_when_all_clear
test_risk_each_hard_stop_holds
test_risk_unresolved_repo_holds
test_risk_uncertainty_defaults_to_hold
test_risk_at_cap_holds_even_when_clear
test_risk_cap_from_env
test_resolve_repo_feeds_risk_gate
test_pr_check_feedback_wakes_once_then_dedupes
test_pr_check_merge_not_regressed
test_pr_check_baseline_silences_preexisting_review
test_pr_check_non_linear_arms_merge_only
test_brief_linear_variant
test_brief_default_unchanged
