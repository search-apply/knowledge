#!/usr/bin/env bash
# ds-load.sh: the failing hook test for loading a csv into ds through docker exec psql
# (tests-first). Creates ds.load_test as agent, loads a 500-row csv through hooks/lib.sh's
# psql_as agent \copy, and asserts the row count. Run by db/tests/run.sh (it runs this with
# cwd=repo root and KNOWLEDGE_CONTAINER=the throwaway container) or standalone with
# KNOWLEDGE_CONTAINER set to a live knowledge container.
set -euo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$PWD}"
export CLAUDE_PLUGIN_ROOT="$ROOT"
# shellcheck source=/dev/null
source "$ROOT/hooks/lib.sh"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

# Should_LoadFile_When_CopyThroughDockerExec
case_load_through_copy() {
  local name="load-through-copy" csv count
  csv="$(mktemp)"
  { printf 'id,title,verdict\n'; for i in $(seq 1 500); do printf '%s,title %s,x\n' "$i" "$i"; done; } > "$csv"

  if ! psql_as agent -c 'create table if not exists ds.load_test (id int, title text, verdict text)' >/dev/null; then
    fail "$name" "could not create ds.load_test as agent"; rm -f "$csv"; return
  fi
  if ! psql_as agent -c '\copy ds.load_test from stdin csv header' < "$csv" >/dev/null; then
    fail "$name" "the copy through psql_as agent failed"; rm -f "$csv"; return
  fi
  rm -f "$csv"
  count="$(psql_as agent -c 'select count(*) from ds.load_test')"
  if [ "$count" != "500" ]; then fail "$name" "count=$count, want 500"; return; fi
  pass "$name"
}

case_load_through_copy

if [ "$fails" -gt 0 ]; then
  printf 'ds-load.sh: %d case(s) failed\n' "$fails"
  exit 1
fi
exit 0
