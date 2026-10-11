-- 02-knowledge.sql: the failing tests for the knowledge schema and functions (tests-first).
-- Covers the grants, supersede and add_kind, the rejected puts, recall, search/get/list,
-- about, and export/import round-trip (the knowledge criteria of the epic).
-- Run as postgres against a fresh postgres:18 container with db/init applied; a failing assert
-- stops the file (psql -v ON_ERROR_STOP=1). Every block arranges its own rows inline under its
-- own project name (no seed file); a past-dated row is a put followed by an update of created_at;
-- set role / reset role prove a grant; an expected error is caught with exception when ... inside
-- the block. With no db/init/02-knowledge.sql these blocks fail because knowledge.rows and the
-- functions do not exist: that is the proof the tests are not tautological.

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

-- break: the hook role can reach knowledge; it has no usage on the schema, so insert and select
-- must both be refused with insufficient_privilege.
do $$
declare
  ins_blocked boolean := false;
  sel_blocked boolean := false;
begin
  set role hook;
  begin
    insert into knowledge.rows (project, kind, key, text) values ('t2-hook', 'state', 'x', 'y');
  exception when insufficient_privilege then ins_blocked := true; end;
  begin
    perform 1 from knowledge.rows limit 1;
  exception when insufficient_privilege then sel_blocked := true; end;
  reset role;
  assert ins_blocked, 'hook insert on knowledge.rows must raise insufficient_privilege';
  assert sel_blocked, 'hook select on knowledge.rows must raise insufficient_privilege (no usage)';
end $$;

-- Should_SupersedeCurrentRow_When_SameKeyPut

-- break: a put of the same project, kind and key leaves two current rows, or the old row still
-- current; or supersede() loses the old fields, or accepts a row that is not current.
do $$
declare
  id1 bigint;
  id2 bigint;
  id3 bigint;
  cur_count int;
  not_current_blocked boolean := false;
begin
  id1 := knowledge.put('t3-sup', 'decision', 'k', 'first', '{"why":"w","options":"o","who_ruled":"master"}'::jsonb);
  id2 := knowledge.put('t3-sup', 'decision', 'k', 'second', '{"why":"w2","options":"o2","who_ruled":"master"}'::jsonb);
  assert (select superseded_by from knowledge.rows where id = id1) = id2, 'put must set the old row''s superseded_by to the new id';
  assert (select superseded_by from knowledge.rows where id = id2) is null, 'the new row must be current';
  select count(*) into cur_count from knowledge.current where project = 't3-sup' and kind = 'decision' and key = 'k';
  assert cur_count = 1, 'only one current row per project, kind, key after a supersede';
  id3 := knowledge.supersede(id2, 'third');
  assert (select fields from knowledge.rows where id = id3) = '{"why":"w2","options":"o2","who_ruled":"master"}'::jsonb, 'supersede keeps the old fields when null is passed';
  assert (select superseded_by from knowledge.rows where id = id2) = id3, 'supersede marks the old row superseded';
  begin
    perform knowledge.supersede(id2, 'again');
  exception when raise_exception then not_current_blocked := true; end;
  assert not_current_blocked, 'supersede must raise when the row is not current';
end $$;

-- Should_AcceptNewKind_When_AddKindCalled

-- break: add_kind does not register a usable kind, the new kind does not enforce its required
-- field, a put of it does not supersede the same key, or a duplicate name is accepted.
do $$
declare
  id1 bigint;
  id2 bigint;
  missing_blocked boolean := false;
  dup_blocked boolean := false;
begin
  perform knowledge.add_kind('t3kind', 'a kind for the add_kind test', '["foo"]'::jsonb);
  id1 := knowledge.put('t3-addk', 't3kind', 'k', 'one', '{"foo":"bar"}'::jsonb);
  assert id1 is not null, 'a put of an added kind returns an id';
  id2 := knowledge.put('t3-addk', 't3kind', 'k', 'two', '{"foo":"baz"}'::jsonb);
  assert (select superseded_by from knowledge.rows where id = id1) = id2, 'an added kind supersedes the same key like any other';
  begin
    perform knowledge.put('t3-addk', 't3kind', 'k2', 'no field', '{}'::jsonb);
  exception when raise_exception then missing_blocked := true; end;
  assert missing_blocked, 'an added kind enforces its required field';
  begin
    perform knowledge.add_kind('t3kind', 'again', '["foo"]'::jsonb);
  exception when others then dup_blocked := true; end;
  assert dup_blocked, 'add_kind must raise on a duplicate name';
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

-- Should_ReturnSections_When_RecallCalled

-- break: recall drops or reorders a section, includes a row past its window, exceeds the line
-- cap, or omits (none) for an empty section.
do $$
declare
  r text;
  id_dold bigint;
  id_lold bigint;
  p_state int; p_dec int; p_les int; p_ptr int; p_ds int; p_open int;
  ds_section text;
begin
  perform knowledge.put('t5', 'state', 'runs', 'service is up', '{"value":"up"}'::jsonb);
  perform knowledge.put('t5', 'decision', 'd-recent', 'keep the window', '{"why":"w","options":"o","who_ruled":"master"}'::jsonb);
  id_dold := knowledge.put('t5', 'decision', 'd-old', 'too old to show', '{"why":"w","options":"o","who_ruled":"master"}'::jsonb);
  update knowledge.rows set created_at = now() - interval '31 days' where id = id_dold;
  perform knowledge.put('t5', 'lesson', 'l-recent', 'a fresh lesson', '{"incident":"i","rule":"r"}'::jsonb);
  id_lold := knowledge.put('t5', 'lesson', 'l-old', 'stale lesson', '{"incident":"i","rule":"r"}'::jsonb);
  update knowledge.rows set created_at = now() - interval '15 days' where id = id_lold;
  perform knowledge.put('t5', 'pointer', 'p-start', 'start here', '{"path":"/x","what":"start"}'::jsonb, tags := array['start']);
  perform knowledge.put('t5', 'fact', 'f-open', 'an open thread', '{"verified_on":"2026-10-10","how":"checked"}'::jsonb, tags := array['open']);

  r := knowledge.recall('t5');

  p_state := position('## state' in r);
  p_dec := position('## decisions' in r);
  p_les := position('## lessons' in r);
  p_ptr := position('## pointers' in r);
  p_ds := position('## datasets' in r);
  p_open := position('## open' in r);
  assert position('# t5 recall ' in r) = 1, 'recall starts with the project title heading';
  assert p_state > 0 and p_dec > p_state and p_les > p_dec and p_ptr > p_les and p_ds > p_ptr and p_open > p_ds,
    'recall headings must run state, decisions, lessons, pointers, datasets, open';
  assert position('d-recent' in r) > 0, 'a decision inside recall.decision_days is shown';
  assert position('d-old' in r) = 0, 'a decision past recall.decision_days is absent';
  assert position('l-recent' in r) > 0, 'a lesson inside recall.lesson_days is shown';
  assert position('l-old' in r) = 0, 'a lesson past recall.lesson_days is absent';
  assert position('p-start' in r) > 0, 'a pointer tagged start is shown under pointers';
  assert position('f-open' in r) > 0, 'a row tagged open is shown under open';
  assert array_length(string_to_array(r, E'\n'), 1) < 40, 'recall is under 40 lines';
  ds_section := substring(r from p_ds for p_open - p_ds);
  assert position('(none)' in ds_section) > 0, 'an empty section (datasets, no ds.catalog yet) prints (none)';
end $$;

-- Should_FindByKeyAndText_When_Searching

-- break: search misses a word in the text, ignores the kind filter, returns a superseded row;
-- or get/list misbehave, or the headline is not the first line.
do $$
declare
  id_a bigint;
  id_g bigint;
  id_b1 bigint;
  id_d bigint;
begin
  id_a := knowledge.put('t6', 'decision', 'alpha', E'flamingo stands tall\nsecond line', '{"why":"w","options":"o","who_ruled":"master"}'::jsonb);
  id_g := knowledge.put('t6', 'state', 'gamma', 'flamingo quiet value', '{"value":"v"}'::jsonb);
  id_b1 := knowledge.put('t6', 'lesson', 'beta', 'flamingo lesson one', '{"incident":"i","rule":"r"}'::jsonb);
  perform knowledge.put('t6', 'lesson', 'beta', 'rewritten with no bird', '{"incident":"i","rule":"r"}'::jsonb);
  id_d := knowledge.put('t6', 'decision', 'delta', 'a later decision', '{"why":"w","options":"o","who_ruled":"master"}'::jsonb);

  assert exists (select 1 from knowledge.search('t6', 'flamingo') s where s.id = id_a), 'search finds a word in the text';
  assert exists (select 1 from knowledge.search('t6', 'flamingo') s where s.id = id_g), 'search finds the word across kinds';
  assert not exists (select 1 from knowledge.search('t6', 'flamingo') s where s.id = id_b1), 'a superseded row is absent from search';
  assert exists (select 1 from knowledge.search('t6', 'flamingo', 'decision') s where s.id = id_a), 'the kind filter keeps the asked kind';
  assert not exists (select 1 from knowledge.search('t6', 'flamingo', 'decision') s where s.id = id_g), 'the kind filter excludes other kinds';
  assert (select count(*) from knowledge.get(id_a)) = 1, 'get by id returns the row';
  assert (select count(*) from knowledge.get(999999999)) = 0, 'get returns nothing when the id is not found';
  assert (select key from knowledge.list('t6', 'decision') limit 1) = 'delta', 'list returns the kind''s current rows newest first';
  assert (select headline from knowledge.search('t6', 'flamingo') s where s.id = id_a) = 'flamingo stands tall', 'the headline is the first line of text';
end $$;

-- Should_WalkParents_When_AboutCalled

-- break: about does not walk issue -> parent -> grandparent, or returns them out of order.
do $$
declare
  r1 bigint;
  r2 bigint;
  r3 bigint;
  ids bigint[];
begin
  r1 := knowledge.put('t7', 'state', 'a', 'root', '{"value":"v"}'::jsonb, issue := 't7#1');
  r2 := knowledge.put('t7', 'state', 'b', 'mid', '{"value":"v"}'::jsonb, issue := 't7#2');
  r3 := knowledge.put('t7', 'state', 'c', 'leaf', '{"value":"v"}'::jsonb, issue := 't7#3');
  perform knowledge.link('t7', 't7#3', 't7#2');
  perform knowledge.link('t7', 't7#2', 't7#1');
  select array_agg(id) into ids from knowledge.about('t7', 't7#3');
  assert ids = array[r3, r2, r1], format('about must return the issue, its parent and its grandparent in that order; got %s', ids);
end $$;

-- Should_RoundTrip_When_ExportThenImport

-- break: a json export then import into a second project loses a field, drops the row order, or
-- carries a superseded row; or markdown misses a kind heading or shows a superseded row.
do $$
declare
  cnt int;
  src jsonb;
  dst jsonb;
  md text;
begin
  perform knowledge.put('t8src', 'decision', 'a', E'first line a\nsecond', '{"why":"w","options":"o","who_ruled":"master"}'::jsonb, source := 'src', tags := array['x']);
  perform knowledge.put('t8src', 'state', 'b', 'superseded value', '{"value":"v"}'::jsonb);
  perform knowledge.put('t8src', 'decision', 'a2', 'another a', '{"why":"w","options":"o","who_ruled":"master"}'::jsonb, issue := 't8#1', commit := 'abc123');
  perform knowledge.put('t8src', 'state', 'b', 'current value', '{"value":"v2"}'::jsonb);

  cnt := knowledge.import('t8dst', knowledge.export('t8src', 'json')::jsonb);
  assert cnt = 3, format('import returns the count of rows loaded; got %s', cnt);

  src := (select jsonb_agg(jsonb_build_object('kind', kind, 'key', key, 'text', text, 'fields', fields,
            'issue', issue, 'commit', commit, 'source', source, 'who', who, 'tags', tags) order by kind, key)
          from knowledge.current where project = 't8src');
  dst := (select jsonb_agg(jsonb_build_object('kind', kind, 'key', key, 'text', text, 'fields', fields,
            'issue', issue, 'commit', commit, 'source', source, 'who', who, 'tags', tags) order by kind, key)
          from knowledge.current where project = 't8dst');
  assert src = dst, 'export then import must preserve kind, key, text, fields, issue, commit, source, who, tags';
  assert (select array_agg(key order by id) from knowledge.current where project = 't8src')
       = (select array_agg(key order by id) from knowledge.current where project = 't8dst'),
    'export then import must preserve the row order';

  md := knowledge.export('t8src', 'markdown');
  assert position('## decision' in md) > 0, 'markdown export has one heading for the decision kind';
  assert position('## state' in md) > 0, 'markdown export has one heading for the state kind';
  assert position('current value' in md) > 0, 'markdown export shows the current row';
  assert position('superseded value' in md) = 0, 'markdown export omits the superseded row';
end $$;

-- Should_EnforceGrants_When_MasterActs (knowledge part)

-- break: master lacks select on knowledge.current, so every security invoker function that
-- reads the view (put, get, search, list, recall, about, export) raises insufficient_privilege
-- when run as master.
do $$
declare
  id_a bigint;
  id_b bigint;
  rec text;
  exp text;
  cnt int;
begin
  set role master;
  id_a := knowledge.put('t2-master', 'state', 'a', 'state value', '{"value":"v"}'::jsonb);
  id_b := knowledge.put('t2-master', 'decision', 'b', 'decision value', '{"why":"w","options":"o","who_ruled":"master"}'::jsonb, issue := 't2-master#1');
  assert (select count(*) from knowledge.get(id_a)) = 1, 'master get must return the row';
  assert (select count(*) from knowledge.search('t2-master', 'state')) >= 1, 'master search must find the row';
  assert (select count(*) from knowledge.list('t2-master', 'state')) >= 1, 'master list must find the row';
  perform knowledge.link('t2-master', 't2-master#1', 't2-master#0');
  assert (select count(*) from knowledge.about('t2-master', 't2-master#1')) >= 1, 'master about must return the row';
  rec := knowledge.recall('t2-master');
  assert rec like '%t2-master recall%', 'master recall must return the sections';
  exp := knowledge.export('t2-master', 'json');
  cnt := knowledge.import('t2-master-b', exp::jsonb);
  assert cnt = 2, format('master import must load the two exported rows; got %s', cnt);
  reset role;
end $$;
