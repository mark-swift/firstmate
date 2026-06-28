#!/usr/bin/env bash
# Shared config resolution for the Linear-mode client (fm-linear-poll.sh, and the
# active-lifecycle helpers landing in a later slice). Linear mode is opt-in: a
# user drops a non-empty LINEAR_API_KEY into the firstmate home's .env.
# LINEAR_ENV_FILE can point direct client calls at another .env-style file, but
# bootstrap activation still checks $FM_HOME/.env. Until then polling is a hard
# no-op.
#
# This mirrors fm-x-lib.sh in structure and conventions. It is sourced, never
# executed. It defines:
#   linear_env_get <key> <file>      - read one KEY=VALUE from a .env-style file
#   linear_load_config               - resolve LINEAR_KEY, LINEAR_URL, LINEAR_BOT,
#                                      and the LINEAR_STATE_* mapping (env wins
#                                      over .env)
#   linear_state_kind <name> <type>  - classify a workflow state into
#                                      ready|backlog|canceled|other (single source
#                                      of truth, used by the poll and unit tests)
#   linear_auth_header_file          - write the Linear auth header to a 0600 temp
#                                      file (RAW key, no Bearer prefix)
#   linear_graphql <q> <vars> <out> [t] - POST a GraphQL query, body -> <out>,
#                                      prints the HTTP code
#   linear_resolve_repo <issue-json> [map] - resolve a project/team/issue to a
#                                      projects/<repo> name (layered precedence)
#   linear_meta_link_set/clear/get   - read/write linear_issue=/linear_branch= in
#                                      state/<id>.meta (atomic, preserves other lines)
# Callers must have FM_HOME set before calling linear_load_config.

# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset". (A copy of fm-x-lib.sh's reader, kept
# here so Linear mode is self-contained and never depends on the X client.)
linear_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# Resolve the Linear-mode settings. An explicit environment variable always wins
# over the .env file. The API URL defaults to Linear's production GraphQL endpoint
# so a normal user configures only the key (and bot user id). State NAMES are
# optional: a non-empty configured name is matched case-insensitively; when a
# kind's name is not configured, classification falls back to the Linear
# workflow-state TYPE (see linear_state_kind).
# shellcheck disable=SC2034 # LINEAR_KEY/URL/BOT are read by callers (the poll) after sourcing.
linear_load_config() {
  local env_file="${LINEAR_ENV_FILE:-$FM_HOME/.env}" raw

  if [ -n "${LINEAR_API_KEY+x}" ]; then
    LINEAR_KEY=${LINEAR_API_KEY-}
  else
    LINEAR_KEY=$(linear_env_get LINEAR_API_KEY "$env_file")
  fi

  if [ -n "${LINEAR_API_URL+x}" ]; then
    LINEAR_URL=${LINEAR_API_URL-}
  else
    LINEAR_URL=$(linear_env_get LINEAR_API_URL "$env_file")
  fi
  [ -n "$LINEAR_URL" ] || LINEAR_URL="https://api.linear.app/graphql"
  LINEAR_URL=${LINEAR_URL%/}

  if [ -n "${LINEAR_BOT_USER_ID+x}" ]; then
    LINEAR_BOT=${LINEAR_BOT_USER_ID-}
  else
    LINEAR_BOT=$(linear_env_get LINEAR_BOT_USER_ID "$env_file")
  fi

  # State mapping. A non-empty resolved value (from env or .env) is "configured":
  # it is matched by name and the type fallback is disabled for that kind. An
  # empty value falls back to a sensible default name AND enables the type
  # fallback. Names are stored lowercased for case-insensitive comparison. The
  # resolved result lands in DISTINCT output names (LINEAR_*_NAME/_SET) so the
  # input env vars (LINEAR_STATE_*) are never overwritten and repeated calls in
  # one process stay idempotent.
  if [ -n "${LINEAR_STATE_READY+x}" ]; then raw=${LINEAR_STATE_READY-}; else raw=$(linear_env_get LINEAR_STATE_READY "$env_file"); fi
  if [ -n "$raw" ]; then LINEAR_READY_SET=1; else LINEAR_READY_SET=0; raw=Ready; fi
  LINEAR_READY_NAME=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')

  if [ -n "${LINEAR_STATE_BACKLOG+x}" ]; then raw=${LINEAR_STATE_BACKLOG-}; else raw=$(linear_env_get LINEAR_STATE_BACKLOG "$env_file"); fi
  if [ -n "$raw" ]; then LINEAR_BACKLOG_SET=1; else LINEAR_BACKLOG_SET=0; raw=Backlog; fi
  LINEAR_BACKLOG_NAME=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')

  if [ -n "${LINEAR_STATE_CANCELED+x}" ]; then raw=${LINEAR_STATE_CANCELED-}; else raw=$(linear_env_get LINEAR_STATE_CANCELED "$env_file"); fi
  if [ -n "$raw" ]; then LINEAR_CANCELED_SET=1; else LINEAR_CANCELED_SET=0; raw=Canceled; fi
  LINEAR_CANCELED_NAME=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
}

# linear_state_kind <state-name> <state-type> -> ready|backlog|canceled|other.
# Single source of truth for slice-1 state classification, shared by the poll and
# the unit tests. A CONFIGURED state NAME wins (case-insensitive match against the
# configured LINEAR_STATE_* name); an UNCONFIGURED role never matches by name and
# is classified solely by the Linear workflow-state TYPE (unstarted->ready,
# backlog->backlog, canceled->canceled). Requires linear_load_config to have run.
linear_state_kind() {
  local name=$1 type=$2 ln lt
  ln=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  lt=$(printf '%s' "$type" | tr '[:upper:]' '[:lower:]')
  if [ "$LINEAR_READY_SET" = 1 ] && [ "$ln" = "$LINEAR_READY_NAME" ]; then echo ready; return; fi
  if [ "$LINEAR_BACKLOG_SET" = 1 ] && [ "$ln" = "$LINEAR_BACKLOG_NAME" ]; then echo backlog; return; fi
  if [ "$LINEAR_CANCELED_SET" = 1 ] && [ "$ln" = "$LINEAR_CANCELED_NAME" ]; then echo canceled; return; fi
  if [ "$LINEAR_READY_SET" = 0 ] && [ "$lt" = unstarted ]; then echo ready; return; fi
  if [ "$LINEAR_BACKLOG_SET" = 0 ] && [ "$lt" = backlog ]; then echo backlog; return; fi
  if [ "$LINEAR_CANCELED_SET" = 0 ] && [ "$lt" = canceled ]; then echo canceled; return; fi
  echo other
}

# Write the Linear auth header to a 0600 temp file and print its path. Linear
# personal API keys authenticate with the RAW key value (no "Bearer " prefix),
# unlike the X relay's bearer token. Returns non-zero for a key with embedded
# newlines (which could smuggle extra headers) or on a filesystem error.
linear_auth_header_file() {
  local file
  case "$LINEAR_KEY" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-linear-auth.XXXXXX") || return 1
  chmod 600 "$file" 2>/dev/null || { rm -f "$file"; return 1; }
  printf 'Authorization: %s\n' "$LINEAR_KEY" > "$file" || { rm -f "$file"; return 1; }
  printf '%s\n' "$file"
}

# linear_graphql <query> <variables-json> <out-body-file> [timeout-secs]: POST a
# GraphQL request to LINEAR_URL and write the response body to <out-body-file>.
# The query and variables are assembled into the JSON body with jq, so untrusted
# text is never interpolated into the command. On success it prints the HTTP
# status code (the caller inspects it); it returns 2 on a setup error (jq/header
# build) and 1 on a transport failure (curl could not complete). Default timeout
# 10s; the poll passes a tighter bound.
linear_graphql() {
  local query=$1 vars=${2:-'{}'} outfile=$3 timeout=${4:-10} body header_file code rc
  command -v jq   >/dev/null 2>&1 || return 2
  command -v curl >/dev/null 2>&1 || return 2
  body=$(jq -cn --arg q "$query" --argjson v "$vars" '{query:$q, variables:$v}') || return 2
  header_file=$(linear_auth_header_file) || return 2
  code=$(curl -m "$timeout" -s -o "$outfile" -w '%{http_code}' \
    -X POST \
    -H "@$header_file" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    --data "$body" \
    "$LINEAR_URL" 2>/dev/null)
  rc=$?
  rm -f "$header_file" 2>/dev/null || true
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$code"
}

# linear_map_lookup <key> <map-file>: print the repo mapped to <key> in a TSV map
# (lines "<key>\t<projects/repo>"; blank lines and "#"-comments ignored; both
# fields whitespace-trimmed). Prints nothing and returns 1 when the key, file, or
# match is absent. The key is passed to awk as a -v variable, never as code.
linear_map_lookup() {
  local key=$1 file=$2
  [ -n "$key" ] || return 1
  [ -f "$file" ] || return 1
  awk -F'\t' -v k="$key" '
    /^[[:space:]]*#/ { next }
    NF < 2 { next }
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
    }
    $1 == k && $2 != "" { print $2; found = 1; exit }
    END { if (!found) exit 1 }
  ' "$file"
}

# linear_resolve_repo <issue-json> [map-file]: resolve which projects/<repo> a
# Linear issue maps to, with layered precedence:
#   1. per-issue explicit override - a "repo:<name>" label, else a "Repository"
#      custom field value (.repositoryField)
#   2. Linear Project -> repo (.project.id then .project.name) via the map
#   3. Team -> repo (.team.id then .team.key then .team.name) via the map
#   4. else unresolved -> empty output
# The map defaults to $FM_HOME/config/linear-projects.tsv (overridable via
# LINEAR_PROJECTS_MAP or the second argument). Always succeeds; an unresolved
# issue yields empty output. Consumed by the active lifecycle in a later slice;
# built and unit-tested now.
linear_resolve_repo() {
  local issue=$1 map=${2:-${LINEAR_PROJECTS_MAP:-$FM_HOME/config/linear-projects.tsv}}
  local label_repo repo_field pid pname tid tkey tname repo

  # 1. Explicit per-issue override. Accept both label shapes: a plain string
  # array (.labels[] strings) and Linear's native object (.labels.nodes[].name,
  # which is what the poll stashes into the inbox node).
  label_repo=$(printf '%s' "$issue" | jq -r '
    [ (.labels // {}) as $l
      | if ($l | type) == "array" then $l[] else ($l.nodes // [])[] end
      | if type == "string" then . else (.name // empty) end ]
    | map(select(type == "string" and test("^repo:")))
    | (.[0] // "") | sub("^repo:"; "") | gsub("^\\s+|\\s+$"; "")' 2>/dev/null) || label_repo=
  if [ -n "$label_repo" ]; then printf '%s' "$label_repo"; return 0; fi
  repo_field=$(printf '%s' "$issue" | jq -r '((.repositoryField // "") | tostring | gsub("^\\s+|\\s+$"; ""))' 2>/dev/null) || repo_field=
  if [ -n "$repo_field" ]; then printf '%s' "$repo_field"; return 0; fi

  # 2. Project -> repo.
  pid=$(printf '%s' "$issue" | jq -r '.project.id // ""' 2>/dev/null) || pid=
  pname=$(printf '%s' "$issue" | jq -r '.project.name // ""' 2>/dev/null) || pname=
  repo=$(linear_map_lookup "$pid" "$map") || repo=$(linear_map_lookup "$pname" "$map") || repo=
  if [ -n "$repo" ]; then printf '%s' "$repo"; return 0; fi

  # 3. Team -> repo.
  tid=$(printf '%s' "$issue" | jq -r '.team.id // ""' 2>/dev/null) || tid=
  tkey=$(printf '%s' "$issue" | jq -r '.team.key // ""' 2>/dev/null) || tkey=
  tname=$(printf '%s' "$issue" | jq -r '.team.name // ""' 2>/dev/null) || tname=
  repo=$(linear_map_lookup "$tid" "$map") || repo=$(linear_map_lookup "$tkey" "$map") || repo=$(linear_map_lookup "$tname" "$map") || repo=
  if [ -n "$repo" ]; then printf '%s' "$repo"; return 0; fi

  # 4. Unresolved.
  return 0
}

# --- task <-> Linear-issue link (state/<id>.meta backed) --------------------
#
# When firstmate ships a Linear-assigned ticket, the task is linked to its issue
# by two lines in state/<id>.meta:
#   linear_issue=<issue-id>      the Linear issue this task delivers
#   linear_branch=<branch>       the branch/PR head the review gate attaches to
# These helpers own the read/write/clear so callers never hand-edit meta and the
# rewrite stays atomic and preserves every other meta line. (Mirrors fm-x-lib.sh's
# x_request meta link.) Consumed by the active lifecycle in a later slice.

# linear_meta_get <meta> <key>: print the value of the last "key=value" line in
# <meta>, or nothing (and succeed) when the file or key is absent.
linear_meta_get() {
  local meta=$1 key=$2 line
  [ -f "$meta" ] || return 0
  line=$(grep -E "^${key}=" "$meta" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  printf '%s' "${line#*=}"
}

linear_meta_tmp() {
  local meta=$1 dir base
  dir=${meta%/*}
  base=${meta##*/}
  [ "$dir" != "$meta" ] || dir=.
  [ -d "$dir" ] || return 1
  mktemp "$dir/.${base}.fm-linear.XXXXXX"
}

# linear_meta_link_set <meta> <issue-id> <branch>: atomically (re)write the
# linear_issue/linear_branch lines, dropping any prior link and preserving every
# other meta line. Returns non-zero if <meta> is missing or the rewrite fails.
linear_meta_link_set() {
  local meta=$1 issue=$2 branch=$3 tmp
  [ -f "$meta" ] || return 1
  tmp=$(linear_meta_tmp "$meta") || return 1
  if ! { grep -vE '^linear_issue=|^linear_branch=' "$meta" || true; } > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  printf 'linear_issue=%s\n' "$issue" >> "$tmp" || { rm -f "$tmp"; return 1; }
  printf 'linear_branch=%s\n' "$branch" >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}

# linear_meta_link_clear <meta>: atomically remove the linear_issue/linear_branch
# lines while preserving every other meta line. Idempotent and a no-op when <meta>
# is missing.
linear_meta_link_clear() {
  local meta=$1 tmp
  [ -f "$meta" ] || return 0
  tmp=$(linear_meta_tmp "$meta") || return 1
  if ! { grep -vE '^linear_issue=|^linear_branch=' "$meta" || true; } > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}
