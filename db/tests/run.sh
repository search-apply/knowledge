#!/usr/bin/env bash
# run.sh [--keep]: starts a throwaway postgres:18 container, applies db/init, runs every
# db/tests/*.sql test file and every db/tests/hooks/*.sh hook, then removes the container
# unless --keep is given. Exit 1 on any failure.
set -uo pipefail

KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTAINER="knowledge-test-$$"
# A throwaway HOME for the hook runs: ensure_up (now called from the hooks) must never write the
# real $HOME/.config/knowledge/env or $HOME/.knowledge during the suite.
HOOK_HOME="$(mktemp -d)"

cleanup() {
  if [ "$KEEP" -eq 0 ]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
  rm -rf "$HOOK_HOME"
}
trap cleanup EXIT INT TERM PIPE

docker run -d --name "$CONTAINER" \
  -e POSTGRES_DB=knowledge \
  -e POSTGRES_PASSWORD=test \
  -e KNOWLEDGE_MASTER_PASSWORD=test \
  -e KNOWLEDGE_AGENT_PASSWORD=test \
  -e KNOWLEDGE_HOOK_PASSWORD=test \
  -v "$ROOT/db/init":/docker-entrypoint-initdb.d:ro \
  postgres:18 >/dev/null

initdone=0
for i in $(seq 1 60); do
  if docker logs "$CONTAINER" 2>&1 | grep -qF 'PostgreSQL init process complete'; then
    initdone=1
    break
  fi
  sleep 1
done

if [ "$initdone" -ne 1 ]; then
  echo "run.sh: init scripts did not complete within 60s" >&2
  exit 1
fi

ready=0
for i in $(seq 1 60); do
  if docker exec "$CONTAINER" pg_isready -U postgres -d knowledge >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if [ "$ready" -ne 1 ]; then
  echo "run.sh: container did not become ready within 60s" >&2
  exit 1
fi

initlog="$(docker logs "$CONTAINER" 2>&1 | awk '/PostgreSQL init process complete/{f=1} f')"
if echo "$initlog" | grep -qE '(ERROR|FATAL)'; then
  echo "run.sh: init log holds an ERROR or FATAL line" >&2
  echo "$initlog" | grep -E '(ERROR|FATAL)' >&2
  exit 1
fi

passed=0
failed=0

# universality: no file under db, hooks, skills or bin may name the house or its product.
# The pattern is built from fragments so the forbidden strings never appear in this file itself.
h="search"
unipattern="${h}napply|${h}\\.apply"
unitargets=()
for d in db hooks skills bin; do
  [ -d "$ROOT/$d" ] && unitargets+=("$ROOT/$d")
done
if grep -rniE "$unipattern" "${unitargets[@]}" >/dev/null 2>&1; then
  echo "FAIL universality"
  grep -rniE "$unipattern" "${unitargets[@]}" 2>/dev/null
  failed=$((failed + 1))
else
  echo "PASS universality"
  passed=$((passed + 1))
fi

shopt -s nullglob
for file in "$ROOT"/db/tests/*.sql; do
  output="$(docker exec -i "$CONTAINER" psql -U postgres -d knowledge -v ON_ERROR_STOP=1 -q < "$file" 2>&1)"
  if [ $? -eq 0 ]; then
    echo "PASS $file"
    passed=$((passed + 1))
  else
    echo "FAIL $file"
    echo "$output"
    failed=$((failed + 1))
  fi
done

for hook in "$ROOT"/db/tests/hooks/*.sh; do
  [ -e "$hook" ] || continue
  [ -x "$hook" ] || continue
  # KNOWLEDGE_AUTOUP=off keeps a hook's ensure_up from creating containers or the env file during
  # the suite; ensure-up.sh and knowledge-up.sh re-enable and sandbox exactly what they exercise.
  output="$(cd "$ROOT" && HOME="$HOOK_HOME" KNOWLEDGE_AUTOUP=off KNOWLEDGE_CONTAINER="$CONTAINER" "$hook" 2>&1)"
  if [ $? -eq 0 ]; then
    echo "PASS $hook"
    passed=$((passed + 1))
  else
    echo "FAIL $hook"
    echo "$output"
    failed=$((failed + 1))
  fi
done
shopt -u nullglob

echo "tests: $passed passed, $failed failed"

if [ "$failed" -gt 0 ]; then
  exit 1
fi
exit 0
