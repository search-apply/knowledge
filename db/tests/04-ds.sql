-- the failing tests for the ds schema (tests-first).
-- Covers the ds grants (agent can create and use its own tables) and the agent statement
-- timeout. Run as postgres against a fresh postgres:18 container with db/init applied; a failing
-- assert stops the file (psql -v ON_ERROR_STOP=1). With no grant on ds this block fails because
-- agent cannot create a table: that is the proof the test is not tautological.

-- break: agent cannot create or use its own table in ds.
do $$
declare
  v_val text;
begin
  set role agent;
  create table ds.t_ds_smoke (id int, val text);
  insert into ds.t_ds_smoke (id, val) values (1, 'one');
  select val into v_val from ds.t_ds_smoke where id = 1;
  reset role;
  assert v_val = 'one', 'agent must be able to create and use its own table in ds';
end $$;

-- break: the agent role's statement_timeout is not set to 5s.
do $$
declare
  v_set boolean;
begin
  select 'statement_timeout=5s' = any(r.rolconfig)
    into v_set
    from pg_roles r where r.rolname = 'agent';
  assert coalesce(v_set, false), 'the agent role must have a statement_timeout of 5s';
end $$;
