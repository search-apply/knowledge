-- 02-knowledge.sql: the knowledge schema (curated, kept for years) -- six tables, one view,
-- grants. Plain tables, no functions.

create table knowledge.projects (
  name text primary key,
  created_at timestamptz not null default now()
);

create table knowledge.kinds (
  name text primary key,
  description text not null
);

create table knowledge.sessions (
  id text primary key,
  project text not null references knowledge.projects,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  summary text
);

create table knowledge.tasks (
  project text not null references knowledge.projects,
  ref text not null,
  title text not null,
  url text,
  status text not null default 'open',
  created_at timestamptz not null default now(),
  primary key (project, ref)
);

create table knowledge.notes (
  id bigint generated always as identity primary key,
  project text not null references knowledge.projects,
  kind text not null references knowledge.kinds,
  key text not null,
  text text not null check (char_length(text) <= 2000),
  ref text,
  session text references knowledge.sessions,
  created_at timestamptz not null default clock_timestamp(),
  foreign key (project, ref) references knowledge.tasks (project, ref),
  unique (project, kind, key, created_at)
);

create index notes_project_kind_key_idx on knowledge.notes (project, kind, key);
create index notes_project_ref_idx on knowledge.notes (project, ref);
create index notes_session_idx on knowledge.notes (session);
create index notes_fts_idx on knowledge.notes using gin (to_tsvector('simple', key || ' ' || text));

create view knowledge.current as
  select distinct on (project, kind, key) id, project, kind, key, text, ref, session, created_at
  from knowledge.notes
  order by project, kind, key, created_at desc;

create table knowledge.datasets (
  table_name text primary key,
  project text not null references knowledge.projects,
  ref text,
  session text references knowledge.sessions,
  what text not null,
  created_at timestamptz not null default now(),
  foreign key (project, ref) references knowledge.tasks (project, ref)
);

-- grants: master owns the data, agent reads it; each role may create its own tables, readable
-- by the other.
grant select, insert, update, delete on all tables in schema knowledge to master;
grant usage, select on all sequences in schema knowledge to master;
grant select on all tables in schema knowledge to agent;
alter default privileges for role master in schema knowledge grant select on tables to agent;
alter default privileges for role agent in schema knowledge grant all on tables to master;
alter role agent set statement_timeout = '5s';
