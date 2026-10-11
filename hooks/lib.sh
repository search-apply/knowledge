#!/usr/bin/env bash
# lib.sh: shared helpers, sourced by every hook script. Not executable on its own.

knowledge_container() { printf '%s' "${KNOWLEDGE_CONTAINER:-knowledge}"; }
knowledge_project() { printf '%s' "${KNOWLEDGE_PROJECT:-$(basename "$PWD")}"; }

# store_up: 0 when the container answers pg_isready within 2 s, 1 otherwise.
store_up() {
  docker exec "$(knowledge_container)" pg_isready -q -U postgres -d knowledge -t 2
}

# psql_as <role> [args...]: runs psql as <role> against the knowledge database in the container.
psql_as() {
  local role="$1"
  shift
  docker exec -i "$(knowledge_container)" psql -U "$role" -d knowledge -v ON_ERROR_STOP=1 -qAt "$@"
}

# newest_dump_age_hours: prints the age in whole hours of the newest *.dump file in
# KNOWLEDGE_DUMP_DIR (default $HOME/.knowledge/dumps), or 999 when the dir is missing or empty.
newest_dump_age_hours() {
  local dir="${KNOWLEDGE_DUMP_DIR:-$HOME/.knowledge/dumps}" newest=0 mtime now
  if [ -d "$dir" ]; then
    shopt -s nullglob
    for f in "$dir"/*.dump; do
      mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null || echo 0)
      [ "$mtime" -gt "$newest" ] && newest="$mtime"
    done
    shopt -u nullglob
  fi
  if [ "$newest" -eq 0 ]; then
    printf '999'
    return 0
  fi
  now=$(date +%s)
  printf '%d' $(( (now - newest) / 3600 ))
}

# knowledge_root: the plugin root -- CLAUDE_PLUGIN_ROOT when a hook set it, else lib.sh's parent.
knowledge_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$CLAUDE_PLUGIN_ROOT"
  else
    (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  fi
}

# load_env: source $HOME/.config/knowledge/env when it exists and the passwords are not already
# in the environment. An explicit `export POSTGRES_PASSWORD=...` always wins over the file.
load_env() {
  local envfile="$HOME/.config/knowledge/env"
  if [ -f "$envfile" ] && [ -z "${POSTGRES_PASSWORD:-}" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$envfile"
    set +a
  fi
}

# knowledge_gen_secret: a 48-hex-char secret from openssl, or urandom+base64 when openssl is absent.
knowledge_gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    head -c 24 /dev/urandom | base64 | tr -d '\n=/+'
  fi
}

# knowledge_ensure_env_file: on the first run, when no password is exported and no file exists,
# write $HOME/.config/knowledge/env (mode 600) with four random passwords, then source it. The file
# is the only place the passwords ever live; no config file holds them. KNOWLEDGE_PROJECT is left
# unset on purpose so the project defaults to the working directory's name.
# Several of these can run at once (the SessionStart hook and both MCP wrappers, at session start).
# A plain `[ ! -f ] then write` is check-then-act: two processes can both pass the check and both
# write, each with its own random passwords. Make the write atomic instead -- build the content in
# a temp file in the same directory, then `ln` it onto the real name; `ln` fails instead of
# clobbering when the target already exists, so only the first writer's passwords ever land, and
# every other process's generated-but-unused secrets are discarded with the temp file.
knowledge_ensure_env_file() {
  local dir="$HOME/.config/knowledge" envfile="$HOME/.config/knowledge/env"
  if [ -z "${POSTGRES_PASSWORD:-}" ] && [ ! -f "$envfile" ]; then
    (
      umask 077
      mkdir -p "$dir"
      tmp="$(mktemp "$dir/.env.XXXXXX")"
      {
        printf '# knowledge store credentials, generated %s. Mode 600; never commit this file.\n' "$(date +%Y-%m-%d)"
        printf 'POSTGRES_PASSWORD=%s\n' "$(knowledge_gen_secret)"
        printf 'KNOWLEDGE_MASTER_PASSWORD=%s\n' "$(knowledge_gen_secret)"
        printf 'KNOWLEDGE_AGENT_PASSWORD=%s\n' "$(knowledge_gen_secret)"
        printf 'KNOWLEDGE_HOOK_PASSWORD=%s\n' "$(knowledge_gen_secret)"
        printf '# KNOWLEDGE_PROJECT is intentionally left unset; the project defaults to the directory name.\n'
      } > "$tmp"
      # Atomic create-if-absent: ln fails (EEXIST) when another process already won the race;
      # either way the temp file's one use is over once the link attempt settles.
      ln "$tmp" "$envfile" 2>/dev/null
      rm -f "$tmp"
    )
  fi
  load_env
}

# _knowledge_start_background: create the network + container (via bin/knowledge-up) and pull the
# MCP image, detached, logging to $HOME/.knowledge/init.log; return at once so a SessionStart hook
# never blocks. A mkdir lock makes it single-flight: repeated PreToolUse calls in the gap before
# the container exists do not each launch a bring-up (a lock older than five minutes is reclaimed).
_knowledge_start_background() {
  local root logdir lock
  root="$(knowledge_root)"
  logdir="$HOME/.knowledge"
  lock="$logdir/.bringup.lock"
  mkdir -p "$logdir"
  if [ -d "$lock" ]; then
    if [ -z "$(find "$lock" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
      return 0
    fi
    rmdir "$lock" 2>/dev/null || true
  fi
  mkdir "$lock" 2>/dev/null || return 0
  KNOWLEDGE_BG_ROOT="$root" KNOWLEDGE_BG_LOCK="$lock" \
    nohup bash -c '
      "$KNOWLEDGE_BG_ROOT/bin/knowledge-up"
      docker pull "${KNOWLEDGE_MCP_IMAGE:-crystaldba/postgres-mcp}"
      rmdir "$KNOWLEDGE_BG_LOCK" 2>/dev/null || true
    ' >>"$logdir/init.log" 2>&1 &
  disown 2>/dev/null || true
}

# _knowledge_wait_ready: poll pg_isready up to KNOWLEDGE_WAIT_SECS seconds (default 5). Five seconds
# is chosen because a merely-stopped container -- already initialised, the common case -- accepts
# connections in one to three seconds, while a SessionStart hook still returns promptly. A first-ever
# cold start runs initdb and takes longer; that is left to the background job, ensure_up returns 1,
# and every caller tolerates "not up yet". bin/mcp raises the bound (it is about to connect).
_knowledge_wait_ready() {
  local secs="${KNOWLEDGE_WAIT_SECS:-5}" i
  for (( i = 0; i < secs; i++ )); do
    if store_up 2>/dev/null; then return 0; fi
    sleep 1
  done
  store_up 2>/dev/null
}

# ensure_up: make the knowledge store reachable, best-effort and fail-open. Returns 0 only when
# pg_isready answered within the wait window, 1 otherwise. Set KNOWLEDGE_AUTOUP=off to manage the
# store yourself (ensure_up then only loads the env and returns 1). Docker missing or its daemon
# down -> one stderr line and return 1. First run writes the env file; a missing container is
# created in the background; a stopped container is started; then a bounded wait for pg_isready.
ensure_up() {
  load_env
  if [ "${KNOWLEDGE_AUTOUP:-on}" = "off" ]; then
    return 1
  fi
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "knowledge: docker is not available; the store is skipped this session" >&2
    return 1
  fi
  knowledge_ensure_env_file
  local container
  container="$(knowledge_container)"
  if ! docker container inspect "$container" >/dev/null 2>&1; then
    _knowledge_start_background
  elif [ "$(docker container inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != "true" ]; then
    docker start "$container" >/dev/null 2>&1 || true
  fi
  _knowledge_wait_ready
}
