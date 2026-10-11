-- 02-knowledge.sql: the failing tests for the knowledge schema and functions (tests-first).
-- Covers the grants, put with its field and three-line checks, supersession through current,
-- and search.
-- Run as postgres against a fresh postgres:18 container with db/init applied; a failing assert
-- stops the file (psql -v ON_ERROR_STOP=1). Every block arranges its own rows inline under its
-- own project name (no seed file); set role / reset role prove a grant; an expected error is
-- caught with exception when ... inside the block. With no db/init/02-knowledge.sql these blocks
-- fail because knowledge.rows and the functions do not exist: that is the proof the tests are
-- not tautological.

-- Should_EnforceGrants_When_EachRoleActs (knowledge part)

-- break: the agent role can write knowledge.rows; every write (insert, update, delete) must be
-- refused with insufficient_privilege and select must still work.
do $$
declare
  ins_blocked boolean := false;
  upd_blocked boolean := false;
  del_blocked boolean := false;
  sel_ok boolean := false;
begin
  perform knowledge.put('t2-agent', 'state', 'seed', 'v', '{"value":"v"}'::jsonb);
  set role agent;
  begin
    insert into knowledge.rows (project, kind, key, text) values ('t2-agent', 'state', 'x', 'y');
  exception when insufficient_privilege then ins_blocked := true; end;
  begin
    update knowledge.rows set text = 'z' where project = 't2-agent';
  exception when insufficient_privilege then upd_blocked := true; end;
  begin
    delete from knowledge.rows where project = 't2-agent';
  exception when insufficient_privilege then del_blocked := true; end;
  begin
    perform 1 from knowledge.rows where project = 't2-agent';
    sel_ok := true;
  exception when insufficient_privilege then sel_ok := false; end;
  reset role;
  assert ins_blocked, 'agent insert on knowledge.rows must raise insufficient_privilege';
  assert upd_blocked, 'agent update on knowledge.rows must raise insufficient_privilege';
  assert del_blocked, 'agent delete on knowledge.rows must raise insufficient_privilege';
  assert sel_ok, 'agent select on knowledge.rows must work';
end $$;

-- break: master cannot put and search its own rows.
do $$
declare
  id_a bigint;
begin
  set role master;
  id_a := knowledge.put('t2-master', 'state', 'a', 'state value', '{"value":"v"}'::jsonb);
  assert id_a is not null, 'master put must return an id';
  assert (select count(*) from knowledge.search('t2-master', 'state')) >= 1, 'master search must find the row';
  reset role;
end $$;

-- Should_SupersedeCurrentRow_When_SameKeyPut

-- break: a put of the same project, kind and key leaves two current rows, or the old row still
-- current.
do $$
declare
  id1 bigint;
  id2 bigint;
  cur_count int;
begin
  id1 := knowledge.put('t3-sup', 'decision', 'k', 'first', '{"why":"w","options":"o","who_ruled":"master"}'::jsonb);
  id2 := knowledge.put('t3-sup', 'decision', 'k', 'second', '{"why":"w2","options":"o2","who_ruled":"master"}'::jsonb);
  assert (select superseded_by from knowledge.rows where id = id1) = id2, 'put must set the old row''s superseded_by to the new id';
  assert (select superseded_by from knowledge.rows where id = id2) is null, 'the new row must be current';
  select count(*) into cur_count from knowledge.current where project = 't3-sup' and kind = 'decision' and key = 'k';
  assert cur_count = 1, 'only one current row per project, kind, key after a supersede';
end $$;

-- Should_RejectPut_When_RuleBroken (four rejected puts, each changing nothing)

-- break: put accepts text of more than three lines.
do $$
declare raised boolean := false; n int;
begin
  begin
    perform knowledge.put('t4-lines', 'state', 'k', E'l1\nl2\nl3\nl4', '{"value":"v"}'::jsonb);
  exception when raise_exception or check_violation then raised := true; end;
  assert raised, 'put must reject text of more than three lines';
  select count(*) into n from knowledge.rows where project = 't4-lines';
  assert n = 0, 'a rejected put must change nothing';
end $$;

-- break: put accepts text longer than 600 characters.
do $$
declare raised boolean := false; n int;
begin
  begin
    perform knowledge.put('t4-chars', 'state', 'k', repeat('a', 601), '{"value":"v"}'::jsonb);
  exception when raise_exception or check_violation then raised := true; end;
  assert raised, 'put must reject text longer than 600 characters';
  select count(*) into n from knowledge.rows where project = 't4-chars';
  assert n = 0, 'a rejected put must change nothing';
end $$;

-- break: put accepts a row missing a required field of its kind.
do $$
declare raised boolean := false; n int;
begin
  begin
    perform knowledge.put('t4-field', 'decision', 'k', 'ok', '{"why":"w"}'::jsonb);
  exception when raise_exception then raised := true; end;
  assert raised, 'put must reject a row missing a required field of its kind';
  select count(*) into n from knowledge.rows where project = 't4-field';
  assert n = 0, 'a rejected put must change nothing';
end $$;

-- break: put accepts an unknown kind.
do $$
declare raised boolean := false; n int;
begin
  begin
    perform knowledge.put('t4-kind', 'no_such_kind', 'k', 'ok', '{}'::jsonb);
  exception when foreign_key_violation then raised := true; end;
  assert raised, 'put must reject an unknown kind with the foreign-key error';
  select count(*) into n from knowledge.rows where project = 't4-kind';
  assert n = 0, 'a rejected put must change nothing';
end $$;

-- Should_FindByKeyAndText_When_Searching

-- break: search misses a word in the text, ignores the kind filter, returns a superseded row,
-- or the headline is not the first line.
do $$
declare
  id_a bigint;
  id_g bigint;
  id_b1 bigint;
begin
  id_a := knowledge.put('t6', 'decision', 'alpha', E'flamingo stands tall\nsecond line', '{"why":"w","options":"o","who_ruled":"master"}'::jsonb);
  id_g := knowledge.put('t6', 'state', 'gamma', 'flamingo quiet value', '{"value":"v"}'::jsonb);
  id_b1 := knowledge.put('t6', 'lesson', 'beta', 'flamingo lesson one', '{"incident":"i","rule":"r"}'::jsonb);
  perform knowledge.put('t6', 'lesson', 'beta', 'rewritten with no bird', '{"incident":"i","rule":"r"}'::jsonb);

  assert exists (select 1 from knowledge.search('t6', 'flamingo') s where s.id = id_a), 'search finds a word in the text';
  assert exists (select 1 from knowledge.search('t6', 'flamingo') s where s.id = id_g), 'search finds the word across kinds';
  assert not exists (select 1 from knowledge.search('t6', 'flamingo') s where s.id = id_b1), 'a superseded row is absent from search';
  assert exists (select 1 from knowledge.search('t6', 'flamingo', 'decision') s where s.id = id_a), 'the kind filter keeps the asked kind';
  assert not exists (select 1 from knowledge.search('t6', 'flamingo', 'decision') s where s.id = id_g), 'the kind filter excludes other kinds';
  assert (select headline from knowledge.search('t6', 'flamingo') s where s.id = id_a) = 'flamingo stands tall', 'the headline is the first line of text';
end $$;
