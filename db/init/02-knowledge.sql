-- 02-knowledge.sql: the knowledge schema (curated, kept for years) -- tables, functions, grants.

-- tables

create table knowledge.kinds (
  name text primary key,
  description text not null,
  fields jsonb not null default '[]'::jsonb
);

create table knowledge.rows (
  id bigint generated always as identity primary key,
  project text not null,
  kind text not null references knowledge.kinds (name),
  key text not null,
  text text not null,
  fields jsonb not null default '{}'::jsonb,
  issue text,
  commit text,
  source text,
  who text not null default 'master',
  tags text[] not null default '{}'::text[],
  created_at timestamptz not null default clock_timestamp(),
  superseded_by bigint references knowledge.rows (id),
  constraint rows_text_three_lines check (
    char_length(text) <= 600
    and array_length(string_to_array(text, E'\n'), 1) <= 3
  ),
  unique (project, kind, key, created_at)
);

create index rows_project_kind_current_idx on knowledge.rows (project, kind) where superseded_by is null;
create index rows_issue_idx on knowledge.rows (issue);
create index rows_fts_idx on knowledge.rows using gin (to_tsvector('simple', key || ' ' || text));

create view knowledge.current as
  select * from knowledge.rows where superseded_by is null;

create table knowledge.config (
  project text not null,
  name text not null,
  value text not null,
  primary key (project, name)
);

create table knowledge.issues (
  project text not null,
  issue text not null,
  parent text,
  primary key (project, issue)
);

-- base grants: master owns the data, agent reads it, hook stays out (no usage on this schema).
grant select, insert, update, delete on knowledge.kinds, knowledge.rows, knowledge.config, knowledge.issues to master;
grant usage, select on all sequences in schema knowledge to master;
grant select on knowledge.kinds, knowledge.rows, knowledge.config, knowledge.issues, knowledge.current to agent;

-- functions

create or replace function knowledge.setting(project text, name text)
returns text
language sql stable security invoker as $$
  select value from knowledge.config c
    where c.project = setting.project and c.name = setting.name
  union all
  select value from knowledge.config c
    where c.project = '*' and c.name = setting.name
  limit 1;
$$;

create or replace function knowledge.put(
  project text,
  kind text,
  key text,
  text text,
  fields jsonb default '{}'::jsonb,
  issue text default null,
  commit text default null,
  source text default null,
  who text default 'master',
  tags text[] default '{}'::text[]
)
returns bigint
language plpgsql security invoker as $$
#variable_conflict use_variable
declare
  v_id bigint;
  v_old_id bigint;
  v_required jsonb;
  v_field text;
begin
  if array_length(string_to_array(text, E'\n'), 1) > 3 or char_length(text) > 600 then
    raise exception 'knowledge.put: text has more than three lines or 600 characters';
  end if;

  select k.fields into v_required from knowledge.kinds k where k.name = kind;
  if v_required is not null then
    for v_field in select jsonb_array_elements_text(v_required) loop
      if not (fields ? v_field) then
        raise exception 'knowledge.put: kind % requires field %', kind, v_field;
      end if;
    end loop;
  end if;

  select r.id into v_old_id from knowledge.current r
    where r.project = project and r.kind = kind and r.key = key;

  insert into knowledge.rows (project, kind, key, text, fields, issue, commit, source, who, tags)
  values (project, kind, key, text, fields, issue, commit, source, who, tags)
  returning id into v_id;

  if v_old_id is not null then
    update knowledge.rows set superseded_by = v_id where id = v_old_id;
  end if;

  return v_id;
end;
$$;

create or replace function knowledge.supersede(
  old_id bigint,
  text text,
  fields jsonb default null,
  source text default null,
  who text default 'master'
)
returns bigint
language plpgsql security invoker as $$
#variable_conflict use_variable
declare
  v_old knowledge.rows;
begin
  select * into v_old from knowledge.rows r where r.id = old_id and r.superseded_by is null;
  if not found then
    raise exception 'knowledge.supersede: row % not found or not current', old_id;
  end if;

  return knowledge.put(
    v_old.project, v_old.kind, v_old.key, text,
    coalesce(fields, v_old.fields),
    v_old.issue, v_old.commit,
    coalesce(source, v_old.source),
    who
  );
end;
$$;

create or replace function knowledge.get(id bigint)
returns setof knowledge.rows
language sql stable security invoker as $$
  select r.* from knowledge.rows r where r.id = get.id;
$$;

create or replace function knowledge.search(project text, query text, kind text default null, lim int default 20)
returns table (id bigint, kind text, key text, headline text, created_at timestamptz)
language sql stable security invoker as $$
  select c.id, c.kind, c.key, split_part(c.text, E'\n', 1) as headline, c.created_at
  from knowledge.current c
  where c.project = search.project
    and (search.kind is null or c.kind = search.kind)
    and to_tsvector('simple', c.key || ' ' || c.text) @@ websearch_to_tsquery('simple', search.query)
  order by ts_rank(to_tsvector('simple', c.key || ' ' || c.text), websearch_to_tsquery('simple', search.query)) desc,
           c.created_at desc
  limit search.lim;
$$;

create or replace function knowledge.list(project text, kind text, lim int default 50)
returns table (id bigint, key text, headline text, created_at timestamptz)
language sql stable security invoker as $$
  select c.id, c.key, split_part(c.text, E'\n', 1) as headline, c.created_at
  from knowledge.current c
  where c.project = list.project and c.kind = list.kind
  order by c.created_at desc
  limit list.lim;
$$;

create or replace function knowledge.add_kind(name text, description text, required_fields jsonb)
returns void
language sql security invoker as $$
  insert into knowledge.kinds (name, description, fields) values (add_kind.name, add_kind.description, add_kind.required_fields);
$$;

create or replace function knowledge.link(project text, issue text, parent text)
returns void
language sql security invoker as $$
  insert into knowledge.issues (project, issue, parent) values (link.project, link.issue, link.parent)
  on conflict (project, issue) do update set parent = excluded.parent;
$$;

create or replace function knowledge.about(project text, issue text)
returns setof knowledge.rows
language plpgsql stable security invoker as $$
#variable_conflict use_variable
declare
  v_parent text;
  v_grandparent text;
begin
  select i.parent into v_parent from knowledge.issues i where i.project = about.project and i.issue = about.issue;
  if v_parent is not null then
    select i.parent into v_grandparent from knowledge.issues i where i.project = about.project and i.issue = v_parent;
  end if;

  return query
    select r.id, r.project, r.kind, r.key, r.text, r.fields, r.issue, r.commit, r.source, r.who, r.tags, r.created_at, r.superseded_by
    from (
      select r.*, 1 as lvl from knowledge.current r where r.project = about.project and r.issue = about.issue
      union all
      select r.*, 2 as lvl from knowledge.current r where v_parent is not null and r.project = about.project and r.issue = v_parent
      union all
      select r.*, 3 as lvl from knowledge.current r where v_grandparent is not null and r.project = about.project and r.issue = v_grandparent
    ) r
    order by r.lvl;
end;
$$;

create or replace function knowledge.recall(project text)
returns text
language plpgsql stable security invoker as $$
#variable_conflict use_variable
declare
  v_cap int;
  v_decision_days int;
  v_lesson_days int;
  v_lines text[] := array[]::text[];
  v_row record;
  v_cnt int;
  v_rowcount bigint;
begin
  v_cap := coalesce(knowledge.setting(project, 'recall.section_cap'), '10')::int;
  v_decision_days := coalesce(knowledge.setting(project, 'recall.decision_days'), '30')::int;
  v_lesson_days := coalesce(knowledge.setting(project, 'recall.lesson_days'), '14')::int;

  v_lines := v_lines || array[('# ' || project || ' recall ' || to_char(now(), 'YYYY-MM-DD'))];

  v_lines := v_lines || array['## state'];
  v_cnt := 0;
  for v_row in
    select r.id, r.key, r.text from knowledge.current r
    where r.project = recall.project and r.kind = 'state'
    order by r.created_at desc limit v_cap
  loop
    v_lines := v_lines || array[('k#' || v_row.id || ' ' || v_row.key || ': ' || split_part(v_row.text, E'\n', 1))];
    v_cnt := v_cnt + 1;
  end loop;
  if v_cnt = 0 then v_lines := v_lines || array['(none)']; end if;

  v_lines := v_lines || array[('## decisions (last ' || v_decision_days || ' days)')];
  v_cnt := 0;
  for v_row in
    select r.id, r.key, r.text from knowledge.current r
    where r.project = recall.project and r.kind = 'decision'
      and r.created_at >= now() - (v_decision_days || ' days')::interval
    order by r.created_at desc limit v_cap
  loop
    v_lines := v_lines || array[('k#' || v_row.id || ' ' || v_row.key || ': ' || split_part(v_row.text, E'\n', 1))];
    v_cnt := v_cnt + 1;
  end loop;
  if v_cnt = 0 then v_lines := v_lines || array['(none)']; end if;

  v_lines := v_lines || array[('## lessons (last ' || v_lesson_days || ' days)')];
  v_cnt := 0;
  for v_row in
    select r.id, r.key, r.text from knowledge.current r
    where r.project = recall.project and r.kind = 'lesson'
      and r.created_at >= now() - (v_lesson_days || ' days')::interval
    order by r.created_at desc limit v_cap
  loop
    v_lines := v_lines || array[('k#' || v_row.id || ' ' || v_row.key || ': ' || split_part(v_row.text, E'\n', 1))];
    v_cnt := v_cnt + 1;
  end loop;
  if v_cnt = 0 then v_lines := v_lines || array['(none)']; end if;

  v_lines := v_lines || array['## pointers'];
  v_cnt := 0;
  for v_row in
    select r.id, r.key, r.text from knowledge.current r
    where r.project = recall.project and r.kind = 'pointer' and 'start' = any (r.tags)
    order by r.created_at desc limit v_cap
  loop
    v_lines := v_lines || array[('k#' || v_row.id || ' ' || v_row.key || ': ' || split_part(v_row.text, E'\n', 1))];
    v_cnt := v_cnt + 1;
  end loop;
  if v_cnt = 0 then v_lines := v_lines || array['(none)']; end if;

  v_lines := v_lines || array['## datasets'];
  v_cnt := 0;
  if to_regclass('ds.catalog') is not null then
    for v_row in
      execute format('select table_name, summary from ds.catalog where project = %L order by created_at desc limit %s',
        recall.project, v_cap)
    loop
      execute format('select count(*) from %I', v_row.table_name) into v_rowcount;
      v_lines := v_lines || array[(v_row.table_name || ': ' || v_rowcount || ' rows, ' || split_part(v_row.summary, E'\n', 1))];
      v_cnt := v_cnt + 1;
    end loop;
  end if;
  if v_cnt = 0 then v_lines := v_lines || array['(none)']; end if;

  v_lines := v_lines || array['## open'];
  v_cnt := 0;
  for v_row in
    select r.id, r.key, r.text from knowledge.current r
    where r.project = recall.project and 'open' = any (r.tags)
    order by r.created_at desc limit v_cap
  loop
    v_lines := v_lines || array[('k#' || v_row.id || ' ' || v_row.key || ': ' || split_part(v_row.text, E'\n', 1))];
    v_cnt := v_cnt + 1;
  end loop;
  if v_cnt = 0 then v_lines := v_lines || array['(none)']; end if;

  return array_to_string(v_lines, E'\n');
end;
$$;

create or replace function knowledge.export(project text, format text)
returns text
language plpgsql stable security invoker as $$
#variable_conflict use_variable
declare
  v_result text;
begin
  if format = 'json' then
    select jsonb_agg(jsonb_build_object(
        'kind', c.kind, 'key', c.key, 'text', c.text, 'fields', c.fields,
        'issue', c.issue, 'commit', c.commit, 'source', c.source, 'who', c.who,
        'tags', c.tags, 'created_at', c.created_at
      ) order by c.id)::text
      into v_result
      from knowledge.current c where c.project = export.project;
    return coalesce(v_result, '[]');
  elsif format = 'markdown' then
    select string_agg(section, E'\n\n' order by kind) into v_result
    from (
      select c.kind,
        '## ' || c.kind || E'\n' || string_agg(
          '- ' || c.key || ': ' || split_part(c.text, E'\n', 1) ||
          ' (k#' || c.id || ', ' || to_char(c.created_at, 'YYYY-MM-DD') || ')',
          E'\n' order by c.id
        ) as section
      from knowledge.current c
      where c.project = export.project
      group by c.kind
    ) s;
    return coalesce(v_result, '');
  else
    raise exception 'knowledge.export: unknown format %', format;
  end if;
end;
$$;

create or replace function knowledge.import(project text, doc jsonb)
returns int
language plpgsql security invoker as $$
#variable_conflict use_variable
declare
  v_elem jsonb;
  v_count int := 0;
begin
  for v_elem in
    select e.value from jsonb_array_elements(doc) with ordinality as e (value, ord)
    order by e.ord
  loop
    perform knowledge.put(
      project,
      v_elem ->> 'kind',
      v_elem ->> 'key',
      v_elem ->> 'text',
      coalesce(v_elem -> 'fields', '{}'::jsonb),
      v_elem ->> 'issue',
      v_elem ->> 'commit',
      v_elem ->> 'source',
      coalesce(v_elem ->> 'who', 'master'),
      coalesce((select array_agg(t) from jsonb_array_elements_text(coalesce(v_elem -> 'tags', '[]'::jsonb)) t), '{}'::text[])
    );
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- grants: execute on every function, to master and agent; nothing to hook.
grant execute on all functions in schema knowledge to master, agent;
