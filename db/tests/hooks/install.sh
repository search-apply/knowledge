#!/usr/bin/env bash
# install.sh: the failing hook tests for session-start.sh, volume-guard.sh and
# newest_dump_age_hours, tests-first.
# Run by db/tests/run.sh (cwd=repo root, KNOWLEDGE_CONTAINER=the throwaway container) or
# standalone with KNOWLEDGE_CONTAINER set to a live knowledge container.
# Each case prints PASS <name> or FAIL <name>: <reason>; the script exits 1 on any FAIL.
set -euo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$PWD}"
export CLAUDE_PLUGIN_ROOT="$ROOT"
SESSION_START="$ROOT/hooks/session-start.sh"
VOLUME_GUARD="$ROOT/hooks/volume-guard.sh"
: "${KNOWLEDGE_CONTAINER:=knowledge}"
export KNOWLEDGE_CONTAINER

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

master_q() { docker exec -i "$KNOWLEDGE_CONTAINER" psql -U master -d knowledge -v ON_ERROR_STOP=1 -qAt -c "$1"; }

# AC-3 Should_RecallExpireAndDump_When_SessionStarts
case_recall_and_expire() {
  local name="recall-and-expire" out sess="t6-exp-$$" remaining
  if [ ! -x "$SESSION_START" ]; then fail "$name" "hooks/session-start.sh not found or not executable"; return; fi
  # seed an already-expired scratch row so a real expire() call removes it: a negative
  # per-project retention makes scratch.put's own expires_at land in the past.
  master_q "insert into knowledge.config (project, name, value) values ('installtest','scratch.retention_days','-36500')" >/dev/null
  master_q "select scratch.put('installtest','$sess','noop','x')" >/dev/null

  out=$(KNOWLEDGE_DUMP_DIR="$(mktemp -d)" "$SESSION_START" 2>&1 || true)
  if ! printf '%s' "$out" | grep -q 'recall'; then fail "$name" "no recall text in session-start output"; return; fi

  remaining=$(master_q "select count(*) from scratch.outputs where session = '$sess'" || true)
  if [ "$remaining" != "0" ]; then fail "$name" "expired row for session $sess still present after session-start (count=$remaining)"; return; fi
  pass "$name"
}

# AC-3 (store down): no recall text leaks when the store is unreachable.
case_store_down_no_recall() {
  local name="store-down-no-recall" out
  if [ ! -x "$SESSION_START" ]; then fail "$name" "hooks/session-start.sh not found or not executable"; return; fi
  out=$(KNOWLEDGE_CONTAINER=knowledge-missing "$SESSION_START" 2>&1 || true)
  if printf '%s' "$out" | grep -qi 'recall'; then fail "$name" "recall text appeared while the store was unreachable"; return; fi
  pass "$name"
}

# AC-4 Should_BlockVolumeRemoval_When_NameMatches: through the hook JSON on stdin.
ptu() { jq -cn --arg c "$1" '{tool_input:{command:$c}}'; }

case_guard() {
  local name="$1" cmd="$2" want_rc="$3" rc
  if [ ! -x "$VOLUME_GUARD" ]; then fail "$name" "hooks/volume-guard.sh not found or not executable"; return; fi
  if ptu "$cmd" | "$VOLUME_GUARD" >/dev/null 2>/tmp/vg-err-$$; then rc=0; else rc=$?; fi
  if [ "$rc" -ne "$want_rc" ]; then fail "$name" "exit $rc, want $want_rc for: $cmd"; rm -f /tmp/vg-err-$$; return; fi
  if [ "$want_rc" -eq 2 ] && ! grep -q 'volume' /tmp/vg-err-$$; then
    fail "$name" "no volume-naming message on stderr for: $cmd"; rm -f /tmp/vg-err-$$; return
  fi
  rm -f /tmp/vg-err-$$
  pass "$name"
}

case_volume_rm() { case_guard "guard-volume-rm" "docker volume rm knowledge_data" 2; }
case_rm_dash_v() { case_guard "guard-rm-dash-v" "docker rm -v knowledge" 2; }
case_volume_prune() { case_guard "guard-volume-prune" "docker volume prune" 2; }
case_system_prune_volumes() { case_guard "guard-system-prune-volumes" "docker system prune --volumes" 2; }
case_docker_ps_allowed() { case_guard "guard-docker-ps-allowed" "docker ps" 0; }

# AC-5 newest_dump_age_hours
case_dump_age_no_dump() {
  local name="dump-age-no-dump" dir out
  dir=$(mktemp -d)
  out=$(KNOWLEDGE_DUMP_DIR="$dir" bash -c "source '$ROOT/hooks/lib.sh'; newest_dump_age_hours")
  rmdir "$dir"
  if [ "$out" != "999" ]; then fail "$name" "got '$out', want 999 with no dump present"; return; fi
  pass "$name"
}

case_dump_age_with_dump() {
  local name="dump-age-with-dump" dir out touch_time
  dir=$(mktemp -d)
  : > "$dir/knowledge-20200101-0000.dump"
  touch_time=$(( $(date +%s) - 7200 ))
  touch -t "$(date -r "$touch_time" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$touch_time" +%Y%m%d%H%M.%S)" "$dir/knowledge-20200101-0000.dump" 2>/dev/null || true
  out=$(KNOWLEDGE_DUMP_DIR="$dir" bash -c "source '$ROOT/hooks/lib.sh'; newest_dump_age_hours")
  rm -rf "$dir"
  if [ "$out" != "999" ] && [ "$out" -lt 1 ]; then fail "$name" "got '$out', want roughly 2 (hours) with a two-hour-old dump"; return; fi
  if [ "$out" = "999" ]; then fail "$name" "got 999 with a dump file present"; return; fi
  pass "$name"
}

case_recall_and_expire
case_store_down_no_recall
case_volume_rm
case_rm_dash_v
case_volume_prune
case_system_prune_volumes
case_docker_ps_allowed
case_dump_age_no_dump
case_dump_age_with_dump

if [ "$fails" -gt 0 ]; then
  printf 'install.sh: %d case(s) failed\n' "$fails"
  exit 1
fi
exit 0
