#!/usr/bin/env bash
# knowledge-up.sh: the hook tests for bin/knowledge-up's new subcommands --status, --migrate and
# --down, and for dump retention. --status and --migrate act on the live container db/tests/run.sh
# passes in KNOWLEDGE_CONTAINER; --down and retention use their own throwaways, removed at the end.
# Run by db/tests/run.sh (cwd=repo root, KNOWLEDGE_CONTAINER=the throwaway) or standalone with
# KNOWLEDGE_CONTAINER set to a live knowledge container.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$PWD}"
export CLAUDE_PLUGIN_ROOT="$ROOT"
BIN="$ROOT/bin/knowledge-up"
: "${KNOWLEDGE_CONTAINER:=knowledge}"
export KNOWLEDGE_CONTAINER

DOWN_CONTAINER="knowledge-kud-$$"
DOWN_VOLUME="knowledge_data_kud_$$"
MIG_DIR="$(mktemp -d)"
DUMP_DIR="$(mktemp -d)"

cleanup() {
  docker rm -f "$DOWN_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$DOWN_VOLUME" >/dev/null 2>&1 || true
  rm -rf "$MIG_DIR" "$DUMP_DIR"
}
trap cleanup EXIT INT TERM

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
master_q() { docker exec -i "$KNOWLEDGE_CONTAINER" psql -U master -d knowledge -v ON_ERROR_STOP=1 -qAt -c "$1"; }

case_status() {
  local name="status-up" out
  out="$("$BIN" --status 2>&1)" || { fail "$name" "--status exited non-zero: $out"; return; }
  if ! printf '%s' "$out" | grep -q 'status: up'; then fail "$name" "no 'status: up' line: $out"; return; fi
  if ! printf '%s' "$out" | grep -q 'scratch rows:'; then fail "$name" "no scratch-rows line"; return; fi
  if ! printf '%s' "$out" | grep -q 'schema_version:'; then fail "$name" "no schema_version line"; return; fi
  pass "$name"
}

case_migrate() {
  local name="migrate-applies-once" out
  # empty dir: nothing to apply, at version 0
  out="$(KNOWLEDGE_MIGRATIONS_DIR="$MIG_DIR" "$BIN" --migrate 2>&1)" || { fail "$name" "--migrate (empty) exited non-zero: $out"; return; }
  if ! printf '%s' "$out" | grep -q 'no migrations to apply (at version 0)'; then fail "$name" "empty dir did not report version 0: $out"; return; fi

  cat > "$MIG_DIR/001-mk.sql" <<'SQL'
create table if not exists ds.zs_migration_applied (ok boolean);
SQL
  out="$(KNOWLEDGE_MIGRATIONS_DIR="$MIG_DIR" "$BIN" --migrate 2>&1)" || { fail "$name" "--migrate (001) exited non-zero: $out"; return; }
  if ! printf '%s' "$out" | grep -q 'now at version 001'; then fail "$name" "did not report applying 001: $out"; return; fi
  if [ "$(master_q "select to_regclass('ds.zs_migration_applied') is not null")" != "t" ]; then
    fail "$name" "the migration did not create its table"; return
  fi
  if [ "$(master_q "select coalesce(knowledge.setting('*','schema_version'),'0')")" != "001" ]; then
    fail "$name" "schema_version was not recorded as 001"; return
  fi
  # rerun is a no-op
  out="$(KNOWLEDGE_MIGRATIONS_DIR="$MIG_DIR" "$BIN" --migrate 2>&1)" || { fail "$name" "--migrate (rerun) exited non-zero: $out"; return; }
  if ! printf '%s' "$out" | grep -q 'no migrations to apply (at version 001)'; then fail "$name" "rerun was not a no-op: $out"; return; fi
  master_q "drop table if exists ds.zs_migration_applied" >/dev/null 2>&1 || true
  pass "$name"
}

case_down() {
  local name="down-removes-container-keeps-volume"
  docker volume create "$DOWN_VOLUME" >/dev/null 2>&1 || { fail "$name" "could not create throwaway volume"; return; }
  docker run -d --name "$DOWN_CONTAINER" -v "$DOWN_VOLUME:/v" alpine sleep 120 >/dev/null 2>&1 \
    || { fail "$name" "could not start throwaway container"; return; }
  KNOWLEDGE_CONTAINER="$DOWN_CONTAINER" KNOWLEDGE_VOLUME="$DOWN_VOLUME" "$BIN" --down >/dev/null 2>&1 \
    || { fail "$name" "--down exited non-zero"; return; }
  if docker inspect "$DOWN_CONTAINER" >/dev/null 2>&1; then fail "$name" "container still present after --down"; return; fi
  if ! docker volume inspect "$DOWN_VOLUME" >/dev/null 2>&1; then fail "$name" "--down removed the volume (it must be kept)"; return; fi
  pass "$name"
}

# retention: assertions use only old files whose fate is independent of the wall clock -- a
# first-of-month file is kept, an old non-first-of-month file is removed, regardless of where
# today's real dump lands, because fifteen September files sit above them in the newest-14 window.
case_retention() {
  local name="dump-retention-keeps-14-and-monthly-firsts" d f
  for d in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15; do
    : > "$DUMP_DIR/knowledge-202609${d}-0900.dump"
  done
  for d in 20260101 20260115 20260131 20260201 20260214 20260301 20260302; do
    : > "$DUMP_DIR/knowledge-${d}-0900.dump"
  done
  KNOWLEDGE_DUMP_DIR="$DUMP_DIR" "$BIN" --dump >/dev/null 2>&1 || { fail "$name" "--dump exited non-zero"; return; }

  for f in 20260101 20260201 20260301; do
    if [ ! -f "$DUMP_DIR/knowledge-${f}-0900.dump" ]; then fail "$name" "first-of-month dump $f was pruned"; return; fi
  done
  for f in 20260115 20260131 20260214 20260302; do
    if [ -f "$DUMP_DIR/knowledge-${f}-0900.dump" ]; then fail "$name" "old non-first-of-month dump $f should have been pruned"; return; fi
  done
  pass "$name"
}

case_status
case_migrate
case_down
case_retention

if [ "$fails" -gt 0 ]; then
  printf 'knowledge-up.sh: %d case(s) failed\n' "$fails"
  exit 1
fi
exit 0
