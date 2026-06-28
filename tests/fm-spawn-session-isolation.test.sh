#!/usr/bin/env bash
# Regression tests for fm-spawn.sh session ID and path resolution fixes.
#
# Tests two critical bugs:
#   Bug 1: Numeric tmux session names (e.g., "0") cause "index 0 in use" failures
#          when using bare session targets like -t "$SES". Fix: use session IDs.
#   Bug 2: Symlinked home paths cause false "not an isolated worktree" failures
#          when comparing logical paths (from pwd) with physical paths (from tmux).
#          Fix: use pwd -P to normalize paths before comparison.
#
# Because full worktree spawn is expensive and requires treehouse, these tests
# focus on the path/targeting logic at unit level: ensuring session ID retrieval
# works, and ensuring physical path resolution doesn't break path comparisons.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-session-isolation)

# --- Bug 1: numeric session names -------------------------------------------
#
# Regression: when the tmux session is named "0" (or any numeric name), a bare
# -t "$SES" is ambiguous: tmux reads it as window index 0, not session 0.
# The window targeted for creation then already exists in the default window,
# causing "create window failed: index 0 in use".
# Fix: extract the session ID (e.g., $0) instead of the session name.
#
# This test verifies that the session ID can be retrieved and is unambiguous.

test_numeric_session_names() {
  local session_name session_id

  # Create a tmux session with a purely numeric name
  session_name="0"
  tmux new-session -d -s "$session_name" -x 200 -y 50

  # Extract the session ID from display-message; it should be something like $0, $1
  session_id=$(tmux display-message -p -t "$session_name" '#{session_id}')
  [ -n "$session_id" ] || fail "failed to extract session ID from numeric session"

  # Verify the session ID starts with $ (the standard tmux format)
  case "$session_id" in
    '$'*) : ;;
    *) fail "session ID '$session_id' doesn't match expected format \$N" ;;
  esac

  # Now create a window using the session ID and verify it works
  # (this is what fm-spawn does: it targets with the ID, not the name)
  if tmux new-window -d -t "$session_id" -n test-window-numeric; then
    pass "numeric session name: can create window using session ID"
  else
    fail "failed to create window using session ID in numeric session"
  fi

  tmux kill-session -t "$session_name" 2>/dev/null || true
}

# --- Bug 2: symlinked home paths -------------------------------------------
#
# Regression: when the firstmate home is reached through a symlink (e.g.,
# /home/user/Storage is a symlink to /mnt/storage), the spawn path computation
# uses logical pwd (keeping /home/user/Storage) while tmux's pane_current_path
# reports physical paths (/mnt/storage). The wait-for-worktree loop compares
# these paths as raw strings and fails immediately.
# Fix: normalize PROJ_ABS with pwd -P to resolve symlinks.
#
# This test verifies that physical path resolution works correctly.

test_symlinked_path_normalization() {
  local physical_dir symlink_dir test_file

  physical_dir="$TMP_ROOT/physical-proj"
  symlink_dir="$TMP_ROOT/symlink-proj"
  test_file="$physical_dir/README.md"

  # Create a physical directory
  mkdir -p "$physical_dir"
  echo "test" > "$test_file"

  # Create a symlink to it
  ln -s "$physical_dir" "$symlink_dir"

  # Verify the symlink resolves to the physical path
  [ -L "$symlink_dir" ] || fail "symlink not created"
  [ -f "$test_file" ] || fail "physical file not reachable through symlink"

  # Now test that cd + pwd -P resolves the physical path correctly
  local logical_path physical_path resolved_path
  logical_path=$(cd "$symlink_dir" && pwd)
  physical_path=$(cd "$symlink_dir" && pwd -P)
  resolved_path=$(cd "$physical_dir" && pwd -P)

  # The logical path should keep the symlink
  case "$logical_path" in
    *symlink-proj*) : ;;
    *) fail "logical path lost symlink: $logical_path" ;;
  esac

  # Both physical_path and resolved_path should be identical and resolve to physical_dir
  [ "$physical_path" = "$resolved_path" ] || fail "pwd -P resolution inconsistent: '$physical_path' vs '$resolved_path'"
  [ "$physical_path" = "$physical_dir" ] || fail "pwd -P did not resolve to physical path: got '$physical_path', expected '$physical_dir'"

  pass "symlinked path: pwd -P resolves physical paths correctly"
}

# --- Integration: path comparison scenario -----------------------------------
#
# Simulate the wait-for-worktree scenario: we have a project accessed through
# a symlink, and we simulate what the pane path (physical) vs PROJ_ABS (also
# physical after the fix) comparison would see.

test_pane_path_comparison_with_symlink() {
  local physical_proj symlink_proj proj_abs pane_path

  physical_proj="$TMP_ROOT/physical-proj-2"
  symlink_proj="$TMP_ROOT/symlink-proj-2"

  mkdir -p "$physical_proj"
  ln -s "$physical_proj" "$symlink_proj"

  # Simulate what fm-spawn does: resolve PROJ_ABS with pwd -P
  # (after the fix)
  proj_abs=$(cd "$symlink_proj" && pwd -P)

  # Simulate what tmux reports (physical path)
  pane_path="$physical_proj"

  # They should match now that both are physical
  [ "$proj_abs" = "$pane_path" ] || fail "path mismatch: proj_abs='$proj_abs' vs pane_path='$pane_path'"

  pass "symlinked path: pane_path comparison works when both use physical paths"
}

test_numeric_session_names
test_symlinked_path_normalization
test_pane_path_comparison_with_symlink
