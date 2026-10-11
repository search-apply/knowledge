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

cleanup() {
  if [ "$KEEP" -eq 0 ]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

docker run -d --name "$CONTAINER" \
  -e POSTGRES_DB=knowledge \
  -e POSTGRES_PASSWORD=test \
  -e KNOWLEDGE_MASTER_PASSWORD=test \
  -e KNOWLEDGE_AGENT_PASSWORD=test \
  -e KNOWLEDGE_HOOK_PASSWORD=test \
  -v "$ROOT/db/init":/docker-entrypoint-initdb.d:ro \
  postgres:18 >/dev/null

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

if docker logs "$CONTAINER" 2>&1 | grep -qE '(ERROR|FATAL)'; then
  echo "run.sh: init log holds an ERROR or FATAL line" >&2
  docker logs "$CONTAINER" 2>&1 | grep -E '(ERROR|FATAL)' >&2
  exit 1
fi

passed=0
failed=0

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
  output="$(cd "$ROOT" && KNOWLEDGE_CONTAINER="$CONTAINER" "$hook" 2>&1)"
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
