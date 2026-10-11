#!/usr/bin/env bash
# ensure-up.sh: the hook tests for hooks/lib.sh's ensure_up and the SessionStart hook's fail-open.
# Proves five things, all on throwaways named for this process:
#   1. a missing env file is created, mode 600, with four password lines and no port;
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
TMP_ABSENT="$(mktemp -d)"
TMP_MCP="$(mktemp -d)"
TMP_RACE="$(mktemp -d)"

cleanup() {
  docker rm -f "$KNOWLEDGE_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$KNOWLEDGE_VOLUME" >/dev/null 2>&1 || true
  docker network rm "$KNOWLEDGE_NETWORK" >/dev/null 2>&1 || true
  rm -rf "$TMP_ENV" "$TMP_ABSENT" "$TMP_MCP" "$TMP_RACE"
}
trap cleanup EXIT INT TERM

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

perms_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
container_is_running() { [ "$(docker inspect -f '{{.State.Running}}' "$KNOWLEDGE_CONTAINER" 2>/dev/null)" = "true" ]; }
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# 3: docker absent -> one line, exit 0 (run first; needs no docker).
case_docker_absent() {
  local name="docker-absent-one-line-exit-0" out rc n
  out="$(PATH="/usr/bin:/bin" HOME="$TMP_ABSENT" KNOWLEDGE_AUTOUP=on "$SESSION_START" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then fail "$name" "session-start exited $rc with docker off PATH, want 0"; return; fi
  n="$(printf '%s\n' "$out" | grep -c .)"
  if [ "$n" -ne 1 ]; then fail "$name" "stdout had $n non-empty lines, want 1: <$out>"; return; fi
  if printf '%s' "$out" | grep -qi 'recall'; then fail "$name" "recall text leaked while docker was absent"; return; fi
  pass "$name"
}

# pre-create the throwaway container directly (passwords live only in this subshell), wait ready.
precreate_container() {
  (
    export POSTGRES_PASSWORD=zs KNOWLEDGE_MASTER_PASSWORD=zs KNOWLEDGE_AGENT_PASSWORD=zs KNOWLEDGE_HOOK_PASSWORD=zs
    "$ROOT/bin/knowledge-up" >/dev/null 2>&1
  ) || return 1
  local i
  for i in $(seq 1 60); do
    docker exec "$KNOWLEDGE_CONTAINER" pg_isready -U postgres -d knowledge >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# 1: missing env -> created mode 600, four password lines, no port, no password printed here.
case_env_created() {
  local name="missing-env-created-600" envfile="$TMP_ENV/.config/knowledge/env" perm eqs
  (
    export HOME="$TMP_ENV" KNOWLEDGE_AUTOUP=on KNOWLEDGE_WAIT_SECS=3
    unset POSTGRES_PASSWORD KNOWLEDGE_MASTER_PASSWORD KNOWLEDGE_AGENT_PASSWORD KNOWLEDGE_HOOK_PASSWORD
    ensure_up >/dev/null 2>&1 || true
  )
  if [ ! -f "$envfile" ]; then fail "$name" "ensure_up did not create $envfile"; return; fi
  perm="$(perms_of "$envfile")"
  if [ "$perm" != "600" ]; then fail "$name" "env file mode is $perm, want 600"; return; fi
  eqs="$(grep -c '=' "$envfile")"
  if [ "$eqs" -ne 4 ]; then fail "$name" "env file has $eqs KEY=value lines, want 4 (the four passwords)"; return; fi
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

# 4: bin/mcp on a fresh HOME with no env file -- the password for the URI must be the one
# ensure_up just generated, read AFTER ensure_up returns, not the (empty) value read before it
# wrote the file. Dry-run so the test never execs the MCP server's own docker run.
case_mcp_password_order() {
  local name="mcp-dry-run-password-set-after-cold-start" out envfile="$TMP_MCP/.config/knowledge/env" pwval
  out="$(
    export HOME="$TMP_MCP" KNOWLEDGE_AUTOUP=on KNOWLEDGE_WAIT_SECS=2 KNOWLEDGE_MCP_DRY_RUN=1
    unset POSTGRES_PASSWORD KNOWLEDGE_MASTER_PASSWORD KNOWLEDGE_AGENT_PASSWORD KNOWLEDGE_HOOK_PASSWORD
    "$ROOT/bin/mcp" master 2>/dev/null
  )"
  if [ ! -f "$envfile" ]; then fail "$name" "bin/mcp did not create $envfile on first cold start"; return; fi
  if ! printf '%s' "$out" | grep -q 'password set: yes'; then
    fail "$name" "dry-run line did not report password set: yes: <$out>"; return
  fi
  pwval="$(awk -F= '/^KNOWLEDGE_MASTER_PASSWORD=/ { print $2 }' "$envfile")"
  if [ -z "$pwval" ]; then fail "$name" "could not read back the generated master password to check for a leak"; return; fi
  if printf '%s' "$out" | grep -qF "$pwval"; then fail "$name" "dry-run line printed the password value"; return; fi
  pass "$name"
}

# 5: three processes calling knowledge_ensure_env_file on the same fresh HOME at once must
# converge on one file and agree on its passwords -- a plain "check, then write" lets two or
# three winners each write their own, last writer wins, and a reader caught mid-write can load
# a mix. Each process prints a sha256 of what it loaded; never the content itself.
case_env_file_race() {
  local name="env-file-race-three-writers-agree" envfile="$TMP_RACE/.config/knowledge/env"
  local nfiles perm eqs hash1 hash2 hash3
  (
    export HOME="$TMP_RACE"
    for i in 1 2 3; do
      (
        unset POSTGRES_PASSWORD KNOWLEDGE_MASTER_PASSWORD KNOWLEDGE_AGENT_PASSWORD KNOWLEDGE_HOOK_PASSWORD
        knowledge_ensure_env_file
        printf '%s' "$POSTGRES_PASSWORD$KNOWLEDGE_MASTER_PASSWORD$KNOWLEDGE_AGENT_PASSWORD$KNOWLEDGE_HOOK_PASSWORD" \
          | sha256_of > "$TMP_RACE/hash.$i"
      ) &
    done
    wait
  )
  nfiles="$(find "$TMP_RACE/.config/knowledge" -maxdepth 1 -type f -name 'env' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$nfiles" != "1" ]; then fail "$name" "found $nfiles env files, want exactly 1"; return; fi
  perm="$(perms_of "$envfile")"
  if [ "$perm" != "600" ]; then fail "$name" "env file mode is $perm, want 600"; return; fi
  eqs="$(grep -c '=' "$envfile")"
  if [ "$eqs" -ne 4 ]; then fail "$name" "env file has $eqs KEY=value lines, want 4"; return; fi
  hash1="$(cat "$TMP_RACE/hash.1" 2>/dev/null)"
  hash2="$(cat "$TMP_RACE/hash.2" 2>/dev/null)"
  hash3="$(cat "$TMP_RACE/hash.3" 2>/dev/null)"
  if [ -z "$hash1" ] || [ "$hash1" != "$hash2" ] || [ "$hash1" != "$hash3" ]; then
    fail "$name" "the three processes disagree on the passwords they loaded"; return
  fi
  pass "$name"
}

case_docker_absent
if precreate_container; then
  case_env_created
  case_stopped_started
  case_mcp_password_order
else
  fail "setup" "could not bring up the throwaway container $KNOWLEDGE_CONTAINER"
fi
case_env_file_race

if [ "$fails" -gt 0 ]; then
  printf 'ensure-up.sh: %d case(s) failed\n' "$fails"
  exit 1
fi
exit 0
