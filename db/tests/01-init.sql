-- 01-init.sql: the schema, the login roles, the six tables and the view, and the default kinds
-- of a fresh init. Run as postgres against a fresh postgres:18 container with db/init applied;
-- a failing assert stops the file (psql -v ON_ERROR_STOP=1). These blocks read catalog state
-- only, so no block arranges data of its own.

-- break: the three login roles (postgres, master, agent) do not add up to three.
do $$
declare
  role_count int;
begin
  select count(*) into role_count
  from pg_roles
  where rolname in ('postgres', 'master', 'agent') and rolcanlogin;
  assert role_count = 3,
    format('roles: expected postgres, master and agent as login roles (3), found %s', role_count);
end $$;

-- break: one of the seven tables or the view is missing or misnamed.
do $$
declare
  table_count int;
begin
  select count(*) into table_count
  from information_schema.tables
  where table_schema = 'knowledge'
    and table_name in ('projects', 'kinds', 'sessions', 'tasks', 'notes', 'datasets', 'handoffs', 'current');
  assert table_count = 8,
    format('tables: expected the seven tables plus the view (8), found %s', table_count);
end $$;

-- break: a default kind is missing, duplicated or dropped by a later init file.
do $$
declare
  kind_count int;
begin
  select count(*) into kind_count from knowledge.kinds;
  assert kind_count = 10,
    format('kinds: expected the ten built-in kinds (10), found %s', kind_count);
end $$;
