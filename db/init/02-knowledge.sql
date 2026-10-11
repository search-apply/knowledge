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

-- base grants: master owns the data, agent reads it.
grant select, insert, update, delete on knowledge.kinds, knowledge.rows to master;
grant usage, select on all sequences in schema knowledge to master;
grant all on knowledge.current to master;
grant select on knowledge.kinds, knowledge.rows, knowledge.current to agent;

-- functions

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

-- grants: execute on every function, to master and agent.
grant execute on all functions in schema knowledge to master, agent;
