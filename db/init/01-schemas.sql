-- 01-schemas.sql: the two stores.
create schema if not exists knowledge;
create schema if not exists ds;

grant usage on schema knowledge to master, agent;
