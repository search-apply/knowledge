-- 01-schemas.sql: the one store.
create schema if not exists knowledge;

grant usage, create on schema knowledge to master, agent;
