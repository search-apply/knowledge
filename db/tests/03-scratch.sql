-- 03-scratch.sql: the failing tests for the scratch schema, functions and grants (tests-first).
-- Covers the scratch part of the grants, read/grep/head/tail by range and pattern, and expire
-- deleting only the expired rows.
-- Run as postgres against a fresh postgres:18 container with db/init applied; a failing assert
-- stops the file (psql -v ON_ERROR_STOP=1). Every block arranges its own rows inline under its own
-- project name (no seed file); set role / reset role prove a grant; an expected error is caught with
-- exception when ... inside the block; only the expire block ages a row, so expire's count is this
-- block's alone. With no db/init/03-scratch.sql these blocks fail because scratch.outputs and the
-- scratch functions do not exist: that is the proof the tests are not tautological.

-- Should_EnforceGrants_When_EachRoleActs (scratch part)

-- break: a role does an action the roles table forbids. The hook insert on scratch.outputs must
-- work (the before-insert trigger fills lines and expires_at); the hook select must raise
-- (insert only, no select); the agent update must raise (select only); the master delete must
-- raise (nobody deletes but expire).
do $$
declare
  hook_ins_ok boolean := false;
  hook_sel_blocked boolean := false;
  agent_upd_blocked boolean := false;
  master_del_blocked boolean := false;
begin
  set role hook;
  begin
    insert into scratch.outputs (project, session, command, body)
      values ('t-sc-grants', 'sess-hook', 'cmd', E'a\nb\nc');
    hook_ins_ok := true;
  exception when insufficient_privilege then hook_ins_ok := false; end;
  begin
    perform 1 from scratch.outputs where project = 't-sc-grants';
  exception when insufficient_privilege then hook_sel_blocked := true; end;
  reset role;

  -- a current row for agent and master to act on
  perform scratch.put('t-sc-grants', 'sess-seed', 'cmd', E'x\ny');

  set role agent;
  begin
    update scratch.outputs set command = 'z' where project = 't-sc-grants';
  exception when insufficient_privilege then agent_upd_blocked := true; end;
  reset role;

  set role master;
  begin
    delete from scratch.outputs where project = 't-sc-grants';
  exception when insufficient_privilege then master_del_blocked := true; end;
  reset role;

  assert hook_ins_ok, 'hook insert on scratch.outputs must work';
  assert hook_sel_blocked, 'hook select on scratch.outputs must raise insufficient_privilege';
  assert agent_upd_blocked, 'agent update on scratch.outputs must raise insufficient_privilege';
  assert master_del_blocked, 'master delete on scratch.outputs must raise insufficient_privilege';
end $$;

-- Should_ReadByRangeAndPattern_When_Called

-- break: read ignores the range, grep is not applied or not case-insensitive, head/tail return
-- the wrong end or number the lines wrong, or read does not cap at scratch.read_cap (200) rows
-- for a 300-line body.
do $$
declare
  oid bigint;
  read_count int;
  read_full int;
  read_first text;
  read_last_n int;
  grep_count int;
  grep_n int;
  head_first_n int;
  head_first_line text;
  tail_last_n int;
  tail_last_line text;
begin
  oid := scratch.put('t-sc-read', 'sess-read', 'cmd',
    (select string_agg('line ' || g, E'\n' order by g) from generate_series(1, 300) g));

  -- read(10, 12): exactly lines 10, 11, 12, numbered by their line number
  select count(*) into read_count from scratch.read(oid, 10, 12);
  assert read_count = 3, 'read(10,12) must return 3 lines';
  select line into read_first from scratch.read(oid, 10, 12) order by n limit 1;
  assert read_first = 'line 10', 'read(10,12) must start at line 10';
  select max(n) into read_last_n from scratch.read(oid, 10, 12);
  assert read_last_n = 12, 'read(10,12) must end at line 12';

  -- grep: case-insensitive regex; '^LINE 150$' matches exactly the one line 150
  select count(*), min(n) into grep_count, grep_n from scratch.grep(oid, '^LINE 150$');
  assert grep_count = 1, 'grep ^LINE 150$ must match exactly one line (case-insensitive)';
  assert grep_n = 150, 'grep must number the matched line 150';

  -- head(3): the first three lines, numbered from 1
  select n, line into head_first_n, head_first_line from scratch.head(oid, 3) order by n limit 1;
  assert head_first_n = 1, 'head(3) must start at line 1';
  assert head_first_line = 'line 1', 'head(3) first line must be line 1';
  assert (select count(*) from scratch.head(oid, 3)) = 3, 'head(3) must return 3 lines';

  -- tail(3): the last three lines, numbered to 300
  select n, line into tail_last_n, tail_last_line from scratch.tail(oid, 3) order by n desc limit 1;
  assert tail_last_n = 300, 'tail(3) must end at line 300';
  assert tail_last_line = 'line 300', 'tail(3) last line must be line 300';
  assert (select count(*) from scratch.tail(oid, 3)) = 3, 'tail(3) must return 3 lines';

  -- read(1, 300): capped at scratch.read_cap (200) rows
  select count(*) into read_full from scratch.read(oid, 1, 300);
  assert read_full = 200, 'read(1,300) must be capped at scratch.read_cap (200)';
end $$;

-- Should_DeleteOnlyExpired_When_ExpireCalled

-- break: expire deletes nothing, deletes a live row too, returns the wrong count, or the hook
-- cannot call it. One expired row and one live row; expire (as hook) returns 1 and the live row
-- stays while the expired row is gone.
do $$
declare
  live_id bigint;
  exp_id bigint;
  deleted int;
  live_remains boolean;
  exp_gone boolean;
begin
  live_id := scratch.put('t-sc-expire', 'sess-live', 'cmd', E'live\nbody');
  exp_id := scratch.put('t-sc-expire', 'sess-exp', 'cmd', E'old\nbody');
  update scratch.outputs set expires_at = now() - interval '1 day' where id = exp_id;

  set role hook;
  deleted := scratch.expire();
  reset role;

  select exists (select 1 from scratch.outputs where id = live_id) into live_remains;
  select not exists (select 1 from scratch.outputs where id = exp_id) into exp_gone;

  assert deleted = 1, 'expire must return 1 (only the expired row)';
  assert live_remains, 'the live row must remain after expire';
  assert exp_gone, 'the expired row must be deleted by expire';
end $$;
