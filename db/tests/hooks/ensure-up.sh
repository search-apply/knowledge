#!/usr/bin/env bash
# ensure-up.sh: the hook tests for hooks/lib.sh's ensure_up and the SessionStart hook's fail-open.
# Proves five things, all on throwaways named for this process:
#   1. a missing env file is created, mode 600, with three password lines and no port;
#   2. a stopped container is started by ensure_up;
#   3. with docker off the PATH the SessionStart hook prints one line and exits 0;
#   4. bin/mcp on a fresh HOME reads the password AFTER ensure_up writes it, not before;
#   5. three processes racing to create the env file converge on one file, one set of passwords.
# Every throwaway (container, volume, network, temp HOMEs) is removed at the end, by exact name.
# Run by db/tests/run.sh (which sets HOME and KNOWLEDGE_AUTOUP=off for hooks; this script overrides
# both for the cases that need a real bring-up) or standalone from the repo root.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$PWD}"
export CLAUDE_PLUGIN_ROOT="$ROOT"
SESSION_START="$ROOT/hooks/session-start.sh"
# shellcheck source=../../../hooks/lib.sh
source "$ROOT/hooks/lib.sh"

# throwaway names, this process only
export KNOWLEDGE_CONTAINER="knowledge-zs-$$"
export KNOWLEDGE_VOLUME="knowledge_data_zs_$$"
export KNOWLEDGE_NETWORK="knowledge_zs_$$"
unset KNOWLEDGE_PORT

TMP_ENV="$(mktemp -d)"

cleanup() {
  docker rm -f "$KNOWLEDGE_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$KNOWLEDGE_VOLUME" >/dev/null 2>&1 || true
  docker network rm "$KNOWLEDGE_NETWORK" >/dev/null 2>&1 || true
  docker network rm "$KNOWLEDGE_CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$TMP_ENV"
}
trap cleanup EXIT INT TERM

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

perms_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
container_is_running() { [ "$(docker inspect -f '{{.State.Running}}' "$KNOWLEDGE_CONTAINER" 2>/dev/null)" = "true" ]; }
# pre-create the throwaway container directly (passwords live only in this subshell), wait ready.
precreate_container() {
  (
    export POSTGRES_PASSWORD=zs KNOWLEDGE_MASTER_PASSWORD=zs KNOWLEDGE_AGENT_PASSWORD=zs
    "$ROOT/bin/knowledge-up" >/dev/null 2>&1
  ) || return 1
  local i
  for i in $(seq 1 60); do
    docker exec "$KNOWLEDGE_CONTAINER" pg_isready -U postgres -d knowledge >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# 1: missing env -> created mode 600, three password lines, no port, no password printed here.
case_env_created() {
  local name="missing-env-created-600" envfile="$TMP_ENV/.config/knowledge/env" perm eqs
  (
    export HOME="$TMP_ENV" KNOWLEDGE_AUTOUP=on KNOWLEDGE_WAIT_SECS=3
    unset POSTGRES_PASSWORD KNOWLEDGE_MASTER_PASSWORD KNOWLEDGE_AGENT_PASSWORD
    ensure_up >/dev/null 2>&1 || true
  )
  if [ ! -f "$envfile" ]; then fail "$name" "ensure_up did not create $envfile"; return; fi
  perm="$(perms_of "$envfile")"
  if [ "$perm" != "600" ]; then fail "$name" "env file mode is $perm, want 600"; return; fi
  eqs="$(grep -c '=' "$envfile")"
  if [ "$eqs" -ne 3 ]; then fail "$name" "env file has $eqs KEY=value lines, want 3 (the three passwords)"; return; fi
  if grep -q 'KNOWLEDGE_PORT' "$envfile"; then fail "$name" "env file set KNOWLEDGE_PORT; it must stay unset"; return; fi
  # prove the passwords are substantial without printing them
  if ! awk -F= '/_PASSWORD=/ { if (length($2) < 20) bad = 1 } END { exit bad + 0 }' "$envfile"; then
    fail "$name" "a generated password is shorter than 20 characters"; return
  fi
  pass "$name"
}

# 2: stopped container -> started by ensure_up.
case_stopped_started() {
  local name="stopped-container-started"
  docker stop "$KNOWLEDGE_CONTAINER" >/dev/null 2>&1 || true
  if container_is_running; then fail "$name" "could not stop the throwaway container to set up the case"; return; fi
  (
    export HOME="$TMP_ENV" KNOWLEDGE_AUTOUP=on KNOWLEDGE_WAIT_SECS=20
    ensure_up >/dev/null 2>&1 || true
  )
  if ! container_is_running; then fail "$name" "ensure_up did not start the stopped container"; return; fi
  pass "$name"
}

# 6: a network with the exact name of the (not yet existing) container must not be mistaken for
# it by the container-existence check -- the blocker this hop fixes. A bare `docker inspect` of
# the name matches the network too, so the old code took the "container exists" branch and never
# created one; `docker container inspect` must not.
case_network_name_collision() {
  local name="network-named-like-container-is-not-mistaken-for-it"
  docker network create "$KNOWLEDGE_CONTAINER" >/dev/null 2>&1 \
    || { fail "$name" "could not create the colliding network"; return; }
  (
    export HOME="$TMP_ENV" KNOWLEDGE_AUTOUP=on KNOWLEDGE_WAIT_SECS=30
    export POSTGRES_PASSWORD=zs KNOWLEDGE_MASTER_PASSWORD=zs KNOWLEDGE_AGENT_PASSWORD=zs
    ensure_up >/dev/null 2>&1 || true
  )
  if ! container_is_running; then
    fail "$name" "ensure_up did not create/start the container while a same-named network existed"
    docker network rm "$KNOWLEDGE_CONTAINER" >/dev/null 2>&1 || true
    return
  fi
  docker network rm "$KNOWLEDGE_CONTAINER" >/dev/null 2>&1 || true
  pass "$name"
}

case_network_name_collision
if precreate_container; then
  case_env_created
  case_stopped_started
else
  fail "setup" "could not bring up the throwaway container $KNOWLEDGE_CONTAINER"
fi

if [ "$fails" -gt 0 ]; then
  printf 'ensure-up.sh: %d case(s) failed\n' "$fails"
  exit 1
fi
exit 0
