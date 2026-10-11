-- 04-ds.sql: the failing tests for the ds schema and functions (tests-first).
-- Covers the ds part of the grants, register/list/describe and the ds.sql read-only pass with
-- its cap, reject and save paths.
-- Run as postgres against a fresh postgres:18 container with db/init applied; a failing assert
-- stops the file (psql -v ON_ERROR_STOP=1). Every block arranges its own rows inline under its own
-- project name (no seed file); set role / reset role prove a grant; an expected error is caught
-- with exception when ... inside the block. With no db/init/04-ds.sql these blocks fail because
-- ds.catalog and the ds functions do not exist: that is the proof the tests are not tautological.

-- Should_EnforceGrants_When_EachRoleActs (ds part)

-- break: agent cannot create a table in ds, master cannot read or update a table agent created,
-- hook can create a table in ds, or agent cannot insert into ds.catalog.
do $$
declare
  master_read_ok boolean := false;
  master_upd_ok boolean := false;
  hook_create_blocked boolean := false;
  agent_catalog_ins_ok boolean := false;
  v_val text;
begin
  set role agent;
  create table ds.t_ac2_tbl (id int, val text);
  insert into ds.t_ac2_tbl (id, val) values (1, 'one');
  begin
    insert into ds.catalog (table_name, project, summary, who) values ('t_ac2_tbl', 't2-ds', 'agent catalog insert', 'agent');
    agent_catalog_ins_ok := true;
  exception when insufficient_privilege then agent_catalog_ins_ok := false; end;
  reset role;

  set role master;
  begin
    perform 1 from ds.t_ac2_tbl where id = 1;
    master_read_ok := true;
  exception when insufficient_privilege then master_read_ok := false; end;
  begin
    update ds.t_ac2_tbl set val = 'one-updated' where id = 1;
    master_upd_ok := true;
  exception when insufficient_privilege then master_upd_ok := false; end;
  reset role;

  select val into v_val from ds.t_ac2_tbl where id = 1;

  set role hook;
  begin
    create table ds.t_ac2_hook (id int);
    hook_create_blocked := false;
  exception when insufficient_privilege then hook_create_blocked := true; end;
  reset role;

  assert master_read_ok, 'master must read a table agent created in ds';
  assert master_upd_ok, 'master must update a table agent created in ds';
  assert v_val = 'one-updated', 'the master update must take effect';
  assert hook_create_blocked, 'hook create in ds must raise insufficient_privilege';
  assert agent_catalog_ins_ok, 'agent insert into ds.catalog must work';
end $$;

-- Should_ListAndDescribe_When_TableRegistered

-- break: list omits the table or shows a stale count, describe misses a column, a type, a null
-- flag or a sample row, or register of a missing table does not raise.
do $$
declare
  v_desc text;
  v_rows bigint;
  v_missing_raised boolean := false;
  v_sample_lines int;
begin
  create table ds.t_ac12_tbl (id int not null, title text, verdict text);
  insert into ds.t_ac12_tbl (id, title, verdict) values
    (1, 'a', 'x'), (2, 'b', 'x'), (3, 'c', 'x'), (4, 'd', 'x'), (5, 'e', 'x'), (6, 'f', 'x'), (7, 'g', 'x');
  perform ds.register('t12-ds', 't_ac12_tbl', 'seven rows for the list/describe test');

  select rows into v_rows from ds.list('t12-ds') where table_name = 't_ac12_tbl';
  assert v_rows = 7, format('ds.list must show the live count; got %s', v_rows);

  insert into ds.t_ac12_tbl (id, title, verdict) values (8, 'h', 'x'), (9, 'i', 'x');
  select rows into v_rows from ds.list('t12-ds') where table_name = 't_ac12_tbl';
  assert v_rows = 9, format('ds.list must show the live count after two more inserts; got %s', v_rows);

  v_desc := ds.describe('t_ac12_tbl');
  assert position('9 rows' in v_desc) > 0, 'describe must show the live row count';
  assert position('id integer not null' in v_desc) > 0, 'describe must show a column with its type and not-null flag';
  assert position('title text null' in v_desc) > 0, 'describe must show a nullable column';
  assert position('--- sample ---' in v_desc) > 0, 'describe must have a sample section';
  select count(*) into v_sample_lines
    from regexp_split_to_table(v_desc, E'\n') as line
    where line ~ '^[0-9]+\|';
  assert v_sample_lines = 5, format('describe must show five sample rows; got %s', v_sample_lines);

  begin
    perform ds.register('t12-ds', 't_ac12_missing', 'no such table');
  exception when raise_exception then v_missing_raised := true; end;
  assert v_missing_raised, 'register of a missing table must raise';
end $$;

-- Should_CapRejectAndSave_When_SqlCalled

-- break: ds.sql returns more than the cap inline, fails to save an over-cap result, lets a write
-- through, or does not cancel a slow statement.
-- Postgres arms statement_timeout once per top-level statement; a SET LOCAL made inside a
-- function body cannot bound a query nested inside that same call, so the session-level timeout
-- below stands in for a caller that sets it before invoking ds.sql (e.g. docker exec psql -c 'set
-- statement_timeout = ...; select * from ds.sql(...)'); ds.sql's own set local still runs per the
-- Design, and still governs a call made after an even shorter outer timeout.
set statement_timeout = 5000;

do $$
declare
  rec record;
  v_before bigint;
  v_after bigint;
  v_elapsed interval;
  v_t0 timestamptz;
  v_timed_out boolean := false;
  v_write_failed boolean := false;
  v_register_failed boolean := false;
begin
  -- under the cap: 10 rows returned whole
  select * into rec from ds.sql('select g from generate_series(1,10) g');
  assert rec.rows_total = 10, format('under the cap, rows_total must be 10; got %s', rec.rows_total);
  assert jsonb_array_length(rec.result) = 10, 'under the cap, result must hold all 10 rows';
  assert rec.saved_table is null, 'under the cap, saved_table must be null';

  -- over the cap: 120 rows saved as ds.result_<n> and registered
  select * into rec from ds.sql('select g from generate_series(1,120) g');
  assert rec.rows_total = 120, format('over the cap, rows_total must be 120; got %s', rec.rows_total);
  assert rec.saved_table like 'result_%', format('over the cap, saved_table must be a result_<n> name; got %s', rec.saved_table);
  execute format('select count(*) from ds.%I', rec.saved_table) into v_after;
  assert v_after = 120, format('the saved table must hold 120 rows; got %s', v_after);
  assert exists (select 1 from ds.catalog where table_name = rec.saved_table), 'the saved table must be registered in ds.catalog';

  -- a select calling a writer inside the statement fails read-only, nothing changes
  select count(*) into v_before from knowledge.rows where project = 't13-ds';
  begin
    perform ds.sql($q$select knowledge.put('t13-ds','state','k','v','{"value":"v"}'::jsonb)$q$);
    v_register_failed := false;
  exception when read_only_sql_transaction then v_register_failed := true; end;
  select count(*) into v_after from knowledge.rows where project = 't13-ds';
  assert v_register_failed, 'a select calling a writer inside ds.sql must fail with the read-only error';
  assert v_after = v_before, 'a failed write inside ds.sql must leave knowledge.rows unchanged';

  -- insert as the statement fails
  begin
    perform ds.sql('insert into ds.catalog (table_name, project, summary) values (''t13-x'', ''t13-ds'', ''x'')');
    v_write_failed := false;
  exception when others then v_write_failed := true; end;
  assert v_write_failed, 'insert as the statement must fail';

  -- a slow statement is cancelled within 6s
  v_t0 := clock_timestamp();
  begin
    perform ds.sql('select pg_sleep(6)');
    v_timed_out := false;
  exception when query_canceled then v_timed_out := true; end;
  v_elapsed := clock_timestamp() - v_t0;
  assert v_timed_out, 'a slow statement must raise query_canceled';
  assert v_elapsed < interval '6 seconds', format('the timeout must cancel before 6s; took %s', v_elapsed);
end $$;
