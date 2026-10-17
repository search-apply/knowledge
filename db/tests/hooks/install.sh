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

# Should_PrintNothingAndExitZero_When_SessionStartsAndStoreUp
case_session_start_prints_nothing_when_up() {
  local name="session-start-prints-nothing-when-up" out rc
  if [ ! -x "$SESSION_START" ]; then fail "$name" "hooks/session-start.sh not found or not executable"; return; fi
  out=$(KNOWLEDGE_DUMP_DIR="$(mktemp -d)" "$SESSION_START" 2>&1 < /dev/null); rc=$?
  if [ -n "$out" ]; then fail "$name" "expected no output when the store is up, got: $out"; return; fi
  if [ "$rc" -ne 0 ]; then fail "$name" "exit $rc, want 0"; return; fi
  pass "$name"
}

# (store down): exactly the one "still coming up" line, or nothing, and exit 0.
case_store_down_one_line() {
  local name="store-down-one-line" out rc
  if [ ! -x "$SESSION_START" ]; then fail "$name" "hooks/session-start.sh not found or not executable"; return; fi
  out=$(KNOWLEDGE_CONTAINER=knowledge-missing "$SESSION_START" 2>&1 < /dev/null); rc=$?
  if [ -n "$out" ] && [ "$(printf '%s' "$out" | wc -l)" -gt 0 ] && [ "$out" != "knowledge: store is still coming up; it will be used from the next command on" ]; then
    fail "$name" "unexpected output: $out"; return
  fi
  if [ "$rc" -ne 0 ]; then fail "$name" "exit $rc, want 0"; return; fi
  pass "$name"
}

# Should_RecordSessionAndPrintOneLine_When_SessionIdOnStdin
case_session_start_records_session() {
  local name="session-start-records-session" out rc want
  if [ ! -x "$SESSION_START" ]; then fail "$name" "hooks/session-start.sh not found or not executable"; return; fi
  want="knowledge: session test-session-1, project hooktest.
knowledge: no handoff yet"
  out=$(printf '%s' '{"session_id":"test-session-1","source":"startup"}' | KNOWLEDGE_PROJECT=hooktest "$SESSION_START" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then fail "$name" "exit $rc, want 0"; return; fi
  if [ "$out" != "$want" ]; then fail "$name" "got: $out"; return; fi
  if [ "$(docker exec "$KNOWLEDGE_CONTAINER" psql -U postgres -d knowledge -qAt -c "select count(*) from knowledge.sessions where id = 'test-session-1' and project = 'hooktest'")" != "1" ]; then
    fail "$name" "no sessions row for test-session-1/hooktest"; return
  fi
  pass "$name"
}

# Should_PrintTaskReportsAndData_When_HandoffNamesATaskRef
case_session_start_prints_restore_map() {
  local name="session-start-prints-restore-map" out rc
  if [ ! -x "$SESSION_START" ]; then fail "$name" "hooks/session-start.sh not found or not executable"; return; fi
  docker exec -i "$KNOWLEDGE_CONTAINER" psql -U postgres -d knowledge -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null 2>&1
insert into knowledge.projects (name) values ('hooktest2') on conflict do nothing;
insert into knowledge.tasks (project, ref, title, url, branch, hop, status)
  values ('hooktest2', 'jobs#46', 'Add retry count', 'https://github.com/x/jobs/issues/46', 'feature/add-retry', 'tests+code', 'open')
  on conflict (project, ref) do update set title = excluded.title, url = excluded.url, branch = excluded.branch, hop = excluded.hop, status = excluded.status;
create table if not exists knowledge.t_hook_rep (id int);
delete from knowledge.t_hook_rep;
insert into knowledge.t_hook_rep values (1), (2), (3);
create table if not exists knowledge.t_hook_extra (id int);
delete from knowledge.t_hook_extra;
insert into knowledge.t_hook_extra values (1);
grant select on knowledge.t_hook_rep, knowledge.t_hook_extra to master;
delete from knowledge.datasets where project = 'hooktest2';
insert into knowledge.datasets (table_name, project, ref, what) values
  ('t_hook_rep', 'hooktest2', 'jobs#46', 'three rows the report already lists'),
  ('t_hook_extra', 'hooktest2', 'jobs#46', 'one extra row not covered by a report');
delete from knowledge.reports where project = 'hooktest2';
insert into knowledge.reports (project, slug, question, verdict, body, tables, ref)
  values ('hooktest2', 'hook-report', 'does it work?', 'yes it does', 'body text', array['t_hook_rep'], 'jobs#46');
insert into knowledge.sessions (id, project) values ('test-session-2', 'hooktest2') on conflict do nothing;
delete from knowledge.handoffs where project = 'hooktest2';
insert into knowledge.handoffs (project, session, text, task_ref, repos)
  values ('hooktest2', 'test-session-2', 'Live: testing the hook.', 'jobs#46', array['jobs']);
SQL
  if [ $? -ne 0 ]; then fail "$name" "fixture setup failed"; return; fi

  out=$(printf '%s' '{"session_id":"test-session-2","source":"startup"}' | KNOWLEDGE_PROJECT=hooktest2 "$SESSION_START" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then fail "$name" "exit $rc, want 0"; return; fi
  if ! printf '%s\n' "$out" | grep -qF "knowledge: task jobs#46 | Add retry count | https://github.com/x/jobs/issues/46 | jobs feature/add-retry | hop tests+code | open"; then
    fail "$name" "missing task line, got: $out"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF "knowledge: report hook-report | yes it does | tables: t_hook_rep(3)"; then
    fail "$name" "missing report line, got: $out"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF "knowledge: data t_hook_extra | one extra row not covered by a report"; then
    fail "$name" "missing data line for the uncovered dataset, got: $out"; return
  fi
  if printf '%s\n' "$out" | grep -qF "knowledge: data t_hook_rep"; then
    fail "$name" "the dataset already listed by a report must not get its own data line"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF "knowledge: read its notes: select n.id, n.kind, n.key, n.text from knowledge.notes n where n.id = any((select notes from knowledge.handoffs where id ="; then
    fail "$name" "missing the updated read-its-notes line, got: $out"; return
  fi
  if printf '%s\n' "$out" | grep -qF "or n.session = h.session"; then
    fail "$name" "the read-its-notes line must drop the or n.session = h.session clause"; return
  fi
  pass "$name"
}

# Should_KeepLaterFieldsAligned_When_ABranchIsNull (regression: IFS=$'\t' alone is still "IFS
# whitespace" to bash's read, so an empty field between two tabs collapses with its neighbour and
# shifts every later field left; the fix coalesces each nullable column to '-' in the SQL).
case_session_start_task_line_null_branch() {
  local name="session-start-task-line-survives-null-branch" out rc
  if [ ! -x "$SESSION_START" ]; then fail "$name" "hooks/session-start.sh not found or not executable"; return; fi
  docker exec -i "$KNOWLEDGE_CONTAINER" psql -U postgres -d knowledge -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null 2>&1
insert into knowledge.projects (name) values ('hooktest3') on conflict do nothing;
insert into knowledge.tasks (project, ref, title, url, branch, hop, status)
  values ('hooktest3', 'playbook#240', 'Discuss the brief', 'https://github.com/x/playbook/issues/240', null, 'discuss', 'open')
  on conflict (project, ref) do update set title = excluded.title, url = excluded.url, branch = excluded.branch, hop = excluded.hop, status = excluded.status;
insert into knowledge.sessions (id, project) values ('test-session-3', 'hooktest3') on conflict do nothing;
delete from knowledge.handoffs where project = 'hooktest3';
insert into knowledge.handoffs (project, session, text, task_ref, repos)
  values ('hooktest3', 'test-session-3', 'Live: discussing #240.', 'playbook#240', array['playbook']);
SQL
  if [ $? -ne 0 ]; then fail "$name" "fixture setup failed"; return; fi

  out=$(printf '%s' '{"session_id":"test-session-3","source":"startup"}' | KNOWLEDGE_PROJECT=hooktest3 "$SESSION_START" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then fail "$name" "exit $rc, want 0"; return; fi
  if ! printf '%s\n' "$out" | grep -qF "knowledge: task playbook#240 | Discuss the brief | https://github.com/x/playbook/issues/240 | playbook - | hop discuss | open"; then
    fail "$name" "a null branch must not shift later fields, got: $out"; return
  fi

  # the stub trigger (001-notes-ref-stub.sql) makes a tasks row with url null and a ref that is
  # just "#<n>" (no repo prefix), so repo also stays null; both must still coalesce to '-'.
  docker exec -i "$KNOWLEDGE_CONTAINER" psql -U postgres -d knowledge -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null 2>&1
insert into knowledge.tasks (project, ref, title, url, branch, hop, status)
  values ('hooktest3', '#240', 'Stubbed by a note', null, null, 'discuss', 'open')
  on conflict (project, ref) do update set title = excluded.title, url = excluded.url, branch = excluded.branch, hop = excluded.hop, status = excluded.status;
insert into knowledge.sessions (id, project) values ('test-session-3b', 'hooktest3') on conflict do nothing;
insert into knowledge.handoffs (project, session, text, task_ref, repos)
  values ('hooktest3', 'test-session-3b', 'Live: a stub row.', '#240', array[]::text[]);
SQL
  if [ $? -ne 0 ]; then fail "$name" "stub-row fixture setup failed"; return; fi

  out=$(printf '%s' '{"session_id":"test-session-3b","source":"startup"}' | KNOWLEDGE_PROJECT=hooktest3 "$SESSION_START" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then fail "$name" "exit $rc, want 0 for the stub row"; return; fi
  if ! printf '%s\n' "$out" | grep -qF "knowledge: task #240 | Stubbed by a note | - | - - | hop discuss | open"; then
    fail "$name" "a null url and a null repo (non-matching ref) must not shift later fields, got: $out"; return
  fi
  pass "$name"
}

# (empty stdin): prints nothing and exits 0.
case_empty_stdin_prints_nothing() {
  local name="empty-stdin-prints-nothing" out rc
  if [ ! -x "$SESSION_START" ]; then fail "$name" "hooks/session-start.sh not found or not executable"; return; fi
  out=$("$SESSION_START" 2>&1 < /dev/null); rc=$?
  if [ -n "$out" ]; then fail "$name" "expected no output on empty stdin, got: $out"; return; fi
  if [ "$rc" -ne 0 ]; then fail "$name" "exit $rc, want 0"; return; fi
  pass "$name"
}

# Should_BlockVolumeRemoval_When_NameMatches: through the hook JSON on stdin.
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

# newest_dump_age_hours
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

case_session_start_prints_nothing_when_up
case_store_down_one_line
case_session_start_records_session
case_session_start_prints_restore_map
case_session_start_task_line_null_branch
case_empty_stdin_prints_nothing
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
