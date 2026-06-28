#!/usr/bin/env bash
# Evaluate the Linear-mode risk rubric for a To Do + bot-assigned ticket and print
# a GO or HOLD verdict with reasons. This is the deterministic core of the gate the
# linear-respond skill applies before dispatching a ship crewmate: the skill reads
# the ticket and the fleet, judges the semantic dimensions (which only a reader can
# decide - is this security-sensitive? ambiguous? large blast radius?), and passes
# them in as flags; this script enforces the COMBINATION rule so the verdict is
# consistent and testable.
#
# The rule (AGENTS.md "Linear mode"): ANY hard-stop forces HOLD, and GO requires
# ALL of the positive preconditions; uncertainty defaults to HOLD. A GO-eligible
# ticket still HOLDs (waits) when its repo is at the in-flight cap.
#
# Usage: fm-linear-risk.sh [flags]
#   Structural / fleet facts (the skill computes these):
#     --repo <name>          resolved projects/<repo> (omitted/empty => unresolved)
#     --inflight-count <n>   in-flight ship tasks already running for this repo (default 0)
#     --cap <n>              in-flight cap per repo (default LINEAR_INFLIGHT_CAP or 1)
#     --overlaps-inflight    overlaps files/subsystem of an in-flight task
#     --depends-unmerged     depends on an unmerged PR or in-flight ticket
#   Semantic hard-stops (the skill judges these from the ticket; any one => HOLD):
#     --security             security / auth / secrets / permissions / crypto
#     --migration            schema or data migration / destructive op
#     --public-api           public API or breaking change
#     --cicd                 CI/CD, deploy, or release pipeline
#     --large-blast-radius   core abstractions / many modules
#     --ambiguous            no clear acceptance criteria / multiple readings
#   GO preconditions (the skill asserts these only when genuinely true):
#     --localized            bounded files / one subsystem
#     --clear-criteria       clear, testable acceptance criteria
#
# Output: line 1 is "GO" or "HOLD"; the remaining lines are the reasons (for HOLD)
# or a single "all clear" note (for GO). Exit 0 for GO, 1 for HOLD, 2 for a usage
# error - so a caller can branch on the exit code and still surface the reasons.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-linear-lib.sh
. "$SCRIPT_DIR/fm-linear-lib.sh"

REPO=""
INFLIGHT=0
CAP=""
OVERLAPS=0
DEPENDS=0
SECURITY=0
MIGRATION=0
PUBLIC_API=0
CICD=0
BLAST=0
AMBIGUOUS=0
LOCALIZED=0
CLEAR=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO=${2:-}; shift 2 ;;
    --repo=*) REPO=${1#*=}; shift ;;
    --inflight-count) INFLIGHT=${2:-0}; shift 2 ;;
    --inflight-count=*) INFLIGHT=${1#*=}; shift ;;
    --cap) CAP=${2:-}; shift 2 ;;
    --cap=*) CAP=${1#*=}; shift ;;
    --overlaps-inflight) OVERLAPS=1; shift ;;
    --depends-unmerged) DEPENDS=1; shift ;;
    --security) SECURITY=1; shift ;;
    --migration) MIGRATION=1; shift ;;
    --public-api) PUBLIC_API=1; shift ;;
    --cicd) CICD=1; shift ;;
    --large-blast-radius) BLAST=1; shift ;;
    --ambiguous) AMBIGUOUS=1; shift ;;
    --localized) LOCALIZED=1; shift ;;
    --clear-criteria) CLEAR=1; shift ;;
    *) echo "fm-linear-risk: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# In-flight cap: explicit --cap wins, else LINEAR_INFLIGHT_CAP (env or .env), else 1.
if [ -z "$CAP" ]; then
  if [ -n "${LINEAR_INFLIGHT_CAP+x}" ]; then
    CAP=${LINEAR_INFLIGHT_CAP-}
  else
    CAP=$(linear_env_get LINEAR_INFLIGHT_CAP "${LINEAR_ENV_FILE:-$FM_HOME/.env}")
  fi
fi
case "$CAP" in ''|*[!0-9]*) CAP=1 ;; esac
case "$INFLIGHT" in ''|*[!0-9]*) INFLIGHT=0 ;; esac

REASONS=()

# Hard-stops: any one forces HOLD.
[ -z "$REPO" ]        && REASONS+=("repo unresolved or cross-repo - cannot dispatch")
[ "$SECURITY" = 1 ]   && REASONS+=("hard-stop: security / auth / secrets / permissions / crypto")
[ "$MIGRATION" = 1 ]  && REASONS+=("hard-stop: schema or data migration / destructive op")
[ "$PUBLIC_API" = 1 ] && REASONS+=("hard-stop: public API or breaking change")
[ "$CICD" = 1 ]       && REASONS+=("hard-stop: CI/CD, deploy, or release pipeline")
[ "$BLAST" = 1 ]      && REASONS+=("hard-stop: large blast radius (core abstractions / many modules)")
[ "$AMBIGUOUS" = 1 ]  && REASONS+=("hard-stop: ambiguous (no clear acceptance criteria / multiple readings)")
[ "$OVERLAPS" = 1 ]   && REASONS+=("hard-stop: overlaps files/subsystem of an in-flight task")
[ "$DEPENDS" = 1 ]    && REASONS+=("hard-stop: depends on an unmerged PR or in-flight ticket")

# GO preconditions: each missing one defaults to HOLD (uncertainty => HOLD).
[ "$LOCALIZED" = 1 ] || REASONS+=("not confirmed localized (bounded files / one subsystem)")
[ "$CLEAR" = 1 ]     || REASONS+=("no confirmed clear, testable acceptance criteria")

# Cap: a GO-eligible ticket still waits when the repo is already at its in-flight cap.
if [ "$INFLIGHT" -ge "$CAP" ]; then
  REASONS+=("repo at in-flight cap ($INFLIGHT/$CAP) - wait and re-evaluate when a slot frees")
fi

if [ "${#REASONS[@]}" -eq 0 ]; then
  echo "GO"
  echo "all clear: localized, clear criteria, no hard-stop, repo resolves, slot available"
  exit 0
fi

echo "HOLD"
for r in "${REASONS[@]}"; do
  printf -- '- %s\n' "$r"
done
exit 1
