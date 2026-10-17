-- 02-knowledge.sql: the tests for the knowledge tables, their constraints and grants. Run as
-- postgres against a fresh postgres:18 container with db/init applied; a failing assert stops
-- the file (psql -v ON_ERROR_STOP=1). Every block arranges its own rows inline under its own
-- project name (no seed file); set role / reset role prove a grant; an expected error is caught
-- with exception when ... inside the block.

-- break: the agent role can write knowledge.notes; master must still be able to.
do $$
declare
  ins_blocked boolean := false;
  ins_ok boolean := false;
begin
  insert into knowledge.projects (name) values ('t-grants') on conflict do nothing;
  set role agent;
  begin
    insert into knowledge.notes (project, kind, key, text) values ('t-grants', 'state', 'x', 'y');
  exception when insufficient_privilege then ins_blocked := true; end;
  reset role;
  set role master;
  begin
    insert into knowledge.notes (project, kind, key, text) values ('t-grants', 'state', 'x', 'y');
    ins_ok := true;
  exception when insufficient_privilege then ins_ok := false; end;
  reset role;
  assert ins_blocked, 'agent insert on knowledge.notes must raise insufficient_privilege';
  assert ins_ok, 'master insert on knowledge.notes must succeed';
end $$;

-- break: a note of more than 2000 characters is accepted.
do $$
declare raised boolean := false; n int;
begin
  insert into knowledge.projects (name) values ('t-len') on conflict do nothing;
  begin
    insert into knowledge.notes (project, kind, key, text) values ('t-len', 'state', 'k', repeat('a', 2001));
  exception when check_violation then raised := true; end;
  assert raised, 'a note with text over 2000 characters must be refused';
  select count(*) into n from knowledge.notes where project = 't-len';
  assert n = 0, 'a rejected note must change nothing';
end $$;

-- break: the same key twice does not show the newest in current, or loses the old row from
-- notes.
do $$
declare cur_text text; n int;
begin
  insert into knowledge.projects (name) values ('t-cur') on conflict do nothing;
  insert into knowledge.notes (project, kind, key, text) values ('t-cur', 'state', 'k', 'first');
  insert into knowledge.notes (project, kind, key, text) values ('t-cur', 'state', 'k', 'second');
  select text into cur_text from knowledge.current where project = 't-cur' and kind = 'state' and key = 'k';
  assert cur_text = 'second', 'current must show the newest text for the same key';
  select count(*) into n from knowledge.notes where project = 't-cur' and kind = 'state' and key = 'k';
  assert n = 2, 'notes must keep both rows under the same key as history';
end $$;

-- break: a note with a ref that names no task fails on the FK instead of stubbing one.
do $$
declare n int; stub_title text; stub_status text;
begin
  insert into knowledge.projects (name) values ('t-ref') on conflict do nothing;
  insert into knowledge.notes (project, kind, key, text, ref) values ('t-ref', 'state', 'k', 'v', '#999');
  select count(*) into n from knowledge.notes where project = 't-ref' and ref = '#999';
  assert n = 1, 'a note with an unknown ref must still be inserted';
  select title, status into stub_title, stub_status from knowledge.tasks where project = 't-ref' and ref = '#999';
  assert stub_title = '#999', 'the before-insert trigger must stub a tasks row titled with the ref';
  assert stub_status = 'open', 'the stub tasks row must be open';
end $$;

-- break: tasks.project_item_id is missing, not nullable, or not filled by a later update.
do $$
declare stored text;
begin
  insert into knowledge.projects (name) values ('t-pvti') on conflict do nothing;
  insert into knowledge.tasks (project, ref, title) values ('t-pvti', '#1', 'x');
  update knowledge.tasks set project_item_id = 'PVTI_abc' where project = 't-pvti' and ref = '#1';
  select project_item_id into stored from knowledge.tasks where project = 't-pvti' and ref = '#1';
  assert stored = 'PVTI_abc', 'tasks.project_item_id must store the ProjectV2 item id';
end $$;

-- break: the gin index misses a word in a note's key or text.
do $$
declare found boolean;
begin
  insert into knowledge.projects (name) values ('t-fts') on conflict do nothing;
  insert into knowledge.notes (project, kind, key, text) values ('t-fts', 'state', 'k', 'flamingo stands tall');
  select exists (
    select 1 from knowledge.notes
    where project = 't-fts'
      and to_tsvector('simple', key || ' ' || text) @@ websearch_to_tsquery('simple', 'flamingo')
  ) into found;
  assert found, 'the gin-backed tsvector query must find a note by a word in its text';
end $$;

-- break: a table agent makes in the schema is unreadable by master, or vice versa.
do $$
declare v_val text;
begin
  set role agent;
  create table knowledge.t_agent_made (id int, val text);
  insert into knowledge.t_agent_made (id, val) values (1, 'from-agent');
  reset role;
  set role master;
  select val into v_val from knowledge.t_agent_made where id = 1;
  reset role;
  assert v_val = 'from-agent', 'master must be able to read a table agent made';
end $$;

-- break: the agent role cannot register or deregister its own table in knowledge.datasets.
do $$
declare n int;
begin
  insert into knowledge.projects (name) values ('t-datasets') on conflict do nothing;
  set role agent;
  insert into knowledge.datasets (table_name, project, what) values ('t_agent_made', 't-datasets', 'test table');
  delete from knowledge.datasets where table_name = 't_agent_made';
  reset role;
  select count(*) into n from knowledge.datasets where table_name = 't_agent_made';
  assert n = 0, 'agent must be able to insert and delete its own datasets row';
end $$;

do $$
declare v_val text;
begin
  set role master;
  create table knowledge.t_master_made (id int, val text);
  insert into knowledge.t_master_made (id, val) values (1, 'from-master');
  reset role;
  set role agent;
  select val into v_val from knowledge.t_master_made where id = 1;
  reset role;
  assert v_val = 'from-master', 'agent must be able to read a table master made';
end $$;

-- break: the agent role's statement_timeout is not set to 5s.
do $$
declare v_set boolean;
begin
  select 'statement_timeout=5s' = any(r.rolconfig)
    into v_set
    from pg_roles r where r.rolname = 'agent';
  assert coalesce(v_set, false), 'the agent role must have a statement_timeout of 5s';
end $$;
