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

