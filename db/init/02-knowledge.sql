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

