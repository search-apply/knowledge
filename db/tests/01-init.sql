-- 01-init.sql: the schemas, the login roles and the schema grants of a fresh init.
-- Covers Should_CreateSchemasRolesAndDefaults_When_InitRuns (the schemas and roles part)
-- and Should_EnforceGrants_When_EachRoleActs (the schema part).
-- Run as postgres against a fresh postgres:18 container with db/init applied; a failing
-- assert stops the file (psql -v ON_ERROR_STOP=1). These blocks read catalog and privilege
-- state only, so no block arranges data of its own.

-- break: a schema the init is meant to create (knowledge or ds) is missing or misnamed.
do $$
declare
  schema_count int;
begin
  select count(*) into schema_count
  from information_schema.schemata
  where schema_name in ('knowledge', 'ds');
  assert schema_count = 2,
    format('schemas: expected knowledge and ds (2), found %s', schema_count);
end $$;

-- break: a login role the init is meant to create (master or agent) is missing or cannot log
-- in, or the three login roles (postgres, master, agent) do not add up to three.
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

-- break: usage is granted to the wrong role -- master and agent must reach both schemas.
do $$
begin
  assert has_schema_privilege('master', 'knowledge', 'usage'), 'usage: master should have usage on knowledge';
  assert has_schema_privilege('master', 'ds', 'usage'),        'usage: master should have usage on ds';
  assert has_schema_privilege('agent', 'knowledge', 'usage'),  'usage: agent should have usage on knowledge';
  assert has_schema_privilege('agent', 'ds', 'usage'),         'usage: agent should have usage on ds';
end $$;

-- break: create on ds is withheld from master or agent.
do $$
begin
  assert has_schema_privilege('master', 'ds', 'create'), 'create: master should have create on ds';
  assert has_schema_privilege('agent', 'ds', 'create'),  'create: agent should have create on ds';
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
