#!/usr/bin/env bash
# Regression tests for fm-worktree-lib.sh isolated-worktree resolution.
#
# Bug (observed 2026-06-29): fm-spawn captured the worktree path from the first
# pane cwd that differed from the project checkout. The fresh treehouse worktree
# subshell runs the captain's shell init, which can cd into ~/.oh-my-zsh
# mid-init - itself a git repo - before settling at the worktree root. Sampling
# that transient cwd recorded worktree=~/.oh-my-zsh into state/<id>.meta, and the
# old isolation guard waved it through because that path is its own git repo
# whose toplevel == itself. fm-teardown/fm-guard then trust that wrong path.
#
# Fix: a candidate is a genuine isolated worktree only when it shares the project
# checkout's git object store (same --git-common-dir -> same repo, treehouse-
# pooled) AND is a real worktree root distinct from the primary checkout. A stray
# repo like ~/.oh-my-zsh has a different common-dir and is rejected. These tests
# exercise that predicate directly with real git repos.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-worktree-lib.sh
. "$ROOT/bin/fm-worktree-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worktree-isolation)
fm_git_identity

# Build a primary checkout, a real treehouse-style worktree of it, and a stray
# repo standing in for ~/.oh-my-zsh.
PRIMARY="$TMP_ROOT/primary"
WORKTREE="$TMP_ROOT/wt"
STRAY="$TMP_ROOT/oh-my-zsh"
fm_git_init_commit "$PRIMARY"
git -C "$PRIMARY" worktree add --quiet -b feat "$WORKTREE"
fm_git_init_commit "$STRAY"
mkdir -p "$WORKTREE/sub"

PROJ_REAL=$(cd "$PRIMARY" && pwd -P)
PROJ_COMMON=$(fm_git_common_dir_abs "$PRIMARY")
WT_REAL=$(cd "$WORKTREE" && pwd -P)

# --- the common-dir invariant the fix relies on -----------------------------

test_common_dir_shared_by_worktree() {
  local wt_common stray_common
  [ -n "$PROJ_COMMON" ] || fail "project common-dir did not resolve"
  wt_common=$(fm_git_common_dir_abs "$WORKTREE")
  stray_common=$(fm_git_common_dir_abs "$STRAY")
  [ "$wt_common" = "$PROJ_COMMON" ] || fail "worktree common-dir should match primary: '$wt_common' vs '$PROJ_COMMON'"
  [ "$stray_common" != "$PROJ_COMMON" ] || fail "stray repo common-dir must NOT match primary (the whole discriminator)"
  pass "common-dir: shared by the real worktree, distinct for a stray repo"
}

# --- a genuine isolated worktree is accepted and canonicalized ---------------

test_real_worktree_accepted() {
  local got
  got=$(fm_worktree_root_if_isolated "$WORKTREE" "$PROJ_COMMON" "$PROJ_REAL") \
    || fail "genuine isolated worktree was rejected"
  [ "$got" = "$WT_REAL" ] || fail "worktree root not canonicalized: got '$got' want '$WT_REAL'"
  pass "real worktree: accepted and resolved to its canonical root"
}

test_worktree_subdir_canonicalizes_to_root() {
  local got
  # The pane may transiently sit in a subdir of the worktree; the recorded value
  # must still be the worktree ROOT, not the subdir.
  got=$(fm_worktree_root_if_isolated "$WORKTREE/sub" "$PROJ_COMMON" "$PROJ_REAL") \
    || fail "worktree subdir was rejected"
  [ "$got" = "$WT_REAL" ] || fail "subdir did not canonicalize to worktree root: got '$got'"
  pass "worktree subdir: resolves to the worktree root, not the subdir"
}

# --- the bug: a stray repo (~/.oh-my-zsh) must be rejected -------------------

test_stray_repo_rejected() {
  if fm_worktree_root_if_isolated "$STRAY" "$PROJ_COMMON" "$PROJ_REAL" >/dev/null 2>&1; then
    fail "stray repo (~/.oh-my-zsh stand-in) was accepted as an isolated worktree (the bug)"
  fi
  pass "stray repo: rejected (different object store)"
}

# --- the primary checkout itself is not isolated ----------------------------

test_primary_checkout_rejected() {
  if fm_worktree_root_if_isolated "$PRIMARY" "$PROJ_COMMON" "$PROJ_REAL" >/dev/null 2>&1; then
    fail "the primary checkout was accepted as an isolated worktree"
  fi
  pass "primary checkout: rejected (not distinct from itself)"
}

# --- non-git and empty inputs are rejected ----------------------------------

test_non_git_path_rejected() {
  local plain="$TMP_ROOT/plain"
  mkdir -p "$plain"
  if fm_worktree_root_if_isolated "$plain" "$PROJ_COMMON" "$PROJ_REAL" >/dev/null 2>&1; then
    fail "a non-git directory was accepted as an isolated worktree"
  fi
  if fm_worktree_root_if_isolated "" "$PROJ_COMMON" "$PROJ_REAL" >/dev/null 2>&1; then
    fail "an empty candidate was accepted"
  fi
  pass "non-git and empty candidates: rejected"
}

test_common_dir_shared_by_worktree
test_real_worktree_accepted
test_worktree_subdir_canonicalizes_to_root
test_stray_repo_rejected
test_primary_checkout_rejected
test_non_git_path_rejected
