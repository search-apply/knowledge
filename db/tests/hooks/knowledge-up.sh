#!/usr/bin/env bash
# knowledge-up.sh: the hook tests for bin/knowledge-up's --down and dump retention. --down and
# retention use their own throwaways, removed at the end.
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
DUMP_DIR="$(mktemp -d)"

cleanup() {
  docker rm -f "$DOWN_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$DOWN_VOLUME" >/dev/null 2>&1 || true
  rm -rf "$DUMP_DIR"
}
trap cleanup EXIT INT TERM

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

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

case_down
case_retention

if [ "$fails" -gt 0 ]; then
  printf 'knowledge-up.sh: %d case(s) failed\n' "$fails"
  exit 1
fi
exit 0
