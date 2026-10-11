-- 01-init.sql: the schemas, the login roles and the schema grants of a fresh init.
-- Covers Should_CreateSchemasRolesAndDefaults_When_InitRuns (the schemas and roles part)
-- and Should_EnforceGrants_When_EachRoleActs (the schema part).
-- Run as postgres against a fresh postgres:18 container with db/init applied; a failing
-- assert stops the file (psql -v ON_ERROR_STOP=1). These blocks read catalog and privilege
-- state only, so no block arranges data of its own.

-- break: a schema the init is meant to create (knowledge, scratch or ds) is missing or misnamed.
do $$
declare
  schema_count int;
begin
  select count(*) into schema_count
  from information_schema.schemata
  where schema_name in ('knowledge', 'scratch', 'ds');
  assert schema_count = 3,
    format('schemas: expected knowledge, scratch and ds (3), found %s', schema_count);
end $$;

-- break: a login role the init is meant to create (master, agent or hook) is missing or cannot log in.
do $$
declare
  role_count int;
begin
  select count(*) into role_count
  from pg_roles
  where rolname in ('master', 'agent', 'hook') and rolcanlogin;
  assert role_count = 3,
    format('roles: expected master, agent and hook as login roles (3), found %s', role_count);
end $$;

-- break: usage is granted to the wrong role -- master and agent must reach all three schemas,
-- hook only scratch (never knowledge or ds).
do $$
begin
  assert has_schema_privilege('master', 'knowledge', 'usage'), 'usage: master should have usage on knowledge';
  assert has_schema_privilege('master', 'scratch', 'usage'),   'usage: master should have usage on scratch';
  assert has_schema_privilege('master', 'ds', 'usage'),        'usage: master should have usage on ds';
  assert has_schema_privilege('agent', 'knowledge', 'usage'),  'usage: agent should have usage on knowledge';
  assert has_schema_privilege('agent', 'scratch', 'usage'),    'usage: agent should have usage on scratch';
  assert has_schema_privilege('agent', 'ds', 'usage'),         'usage: agent should have usage on ds';
  assert has_schema_privilege('hook', 'scratch', 'usage'),     'usage: hook should have usage on scratch';
  assert not has_schema_privilege('hook', 'knowledge', 'usage'), 'usage: hook should NOT have usage on knowledge';
  assert not has_schema_privilege('hook', 'ds', 'usage'),        'usage: hook should NOT have usage on ds';
end $$;

-- break: create on ds is granted to hook, or withheld from master or agent.
do $$
begin
  assert has_schema_privilege('master', 'ds', 'create'),      'create: master should have create on ds';
  assert has_schema_privilege('agent', 'ds', 'create'),       'create: agent should have create on ds';
  assert not has_schema_privilege('hook', 'ds', 'create'),    'create: hook should NOT have create on ds';
end $$;

-- break: a default kind or config row is missing, duplicated or dropped by a later init file.
do $$
declare
  kind_count int;
  config_count int;
begin
  select count(*) into kind_count from knowledge.kinds;
  assert kind_count = 11,
    format('kinds: expected the eleven built-in kinds (11), found %s', kind_count);

  select count(*) into config_count from knowledge.config;
  assert config_count = 5,
    format('config: expected the five `*` defaults (5), found %s', config_count);
end $$;
