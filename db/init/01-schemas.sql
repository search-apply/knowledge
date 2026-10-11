-- 01-schemas.sql: the three stores and their grants.
create schema if not exists knowledge;
create schema if not exists scratch;
create schema if not exists ds;

grant usage on schema knowledge, scratch, ds to master, agent;
grant usage on schema scratch to hook;
grant create on schema ds to master, agent;

alter default privileges for role agent in schema ds grant all on tables to master;
alter default privileges for role agent in schema ds grant all on sequences to master;
