# shellcheck shell=bash
# Shared isolated-worktree resolution for fm-spawn.
# Usage: . bin/fm-worktree-lib.sh
#
# When fm-spawn launches a ship/scout crewmate it runs `treehouse get` in the
# pane and must capture the resulting isolated worktree path - the value it
# records as worktree= in state/<id>.meta and that fm-teardown/fm-guard later
# trust. The naive capture (first pane cwd that differs from the project
# checkout) is racy: the fresh worktree subshell runs the captain's shell init,
# which can cd elsewhere mid-init (observed: ~/.oh-my-zsh, the oh-my-zsh install
# dir, itself a git repo) before settling at the worktree root. Sampling that
# transient cwd recorded worktree=~/.oh-my-zsh, and because that path is its own
# git repo whose toplevel == itself, an isolation guard that only checked "some
# git repo distinct from the project checkout" waved it through.
#
# fm_worktree_root_if_isolated proves a candidate path is a genuine, ISOLATED
# worktree of the SAME repo as the project checkout: it shares the project's git
# object store (same --git-common-dir -> same repo, treehouse-pooled), it is a
# real worktree root, and that root is distinct from the project's primary
# checkout. A stray repo like ~/.oh-my-zsh has a different common-dir and is
# rejected; the primary checkout itself is rejected as not isolated. On success
# it prints the candidate's canonical worktree root (pwd -P), the single value
# fm-spawn reuses for the isolation assertion, the turn-end hook, the launch, and
# the meta write, so the launched path and the recorded path are provably the
# same. The shared common-dir invariant holds for every project, not just the
# firstmate-on-itself case, because treehouse pools are linked git worktrees.

# fm_git_common_dir_abs <dir>: echo the absolute --git-common-dir of the git repo
# at <dir>, or return 1. Normalizes git's sometimes-relative output to absolute so
# common-dirs compare as plain strings.
fm_git_common_dir_abs() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case "$common" in
    /*) printf '%s\n' "$common" ;;
    *) (cd "$dir" && cd "$common" && pwd -P) || return 1 ;;
  esac
}

# fm_worktree_root_if_isolated <candidate> <proj_common> <proj_real>:
#   <candidate>   path to test (e.g. the pane cwd after `treehouse get`)
#   <proj_common> the project checkout's absolute git-common-dir
#                 (fm_git_common_dir_abs of the project)
#   <proj_real>   the project checkout's canonical root (cd; pwd -P)
# Echo the candidate's canonical isolated-worktree root on success, else return 1.
# Success requires all of: candidate is inside a git worktree, that worktree
# shares the project's object store (same common-dir -> same repo), and its root
# is distinct from the project's primary checkout.
fm_worktree_root_if_isolated() {
  local candidate=$1 proj_common=$2 proj_real=$3 top top_real common
  [ -n "$candidate" ] || return 1
  [ -n "$proj_common" ] || return 1
  top=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  top_real=$(cd "$top" 2>/dev/null && pwd -P) || return 1
  common=$(fm_git_common_dir_abs "$candidate") || return 1
  [ "$common" = "$proj_common" ] || return 1
  [ "$top_real" != "$proj_real" ] || return 1
  printf '%s\n' "$top_real"
}
