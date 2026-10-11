-- demo.sql: seed data for the fake project 'demo' (the README demo and the knowledge part of the
-- tests' fake-project fixture). Load by hand only, never by init, never by the test runner:
--   docker exec -i <container> psql -U postgres -d knowledge < db/seed/demo.sql

select knowledge.put('demo', 'state', 'runs', 'api and worker containers are up', '{"value":"up"}'::jsonb);
select knowledge.put('demo', 'state', 'release', 'the next release is in progress', '{"value":"in-progress"}'::jsonb);

select knowledge.put('demo', 'decision', 'store', 'keep one postgres with three schemas', '{"why":"fewer moving parts","options":"one postgres, sqlite plus files","who_ruled":"master"}'::jsonb);
select knowledge.put('demo', 'decision', 'store', 'add a ds schema for agent datasets', '{"why":"agents need real tables, not files","options":"a ds schema, flat files","who_ruled":"master"}'::jsonb);
select knowledge.put('demo', 'decision', 'ui', 'front the store with a generic postgres mcp server', '{"why":"no server of our own to maintain","options":"a custom server, a generic mcp server","who_ruled":"master"}'::jsonb);

select knowledge.put('demo', 'lesson', 'bash-wrap', 'a big command output must not sit in context', '{"incident":"a session held a huge log in context and stalled","rule":"store the output, hand back a digest"}'::jsonb);

select knowledge.put('demo', 'pointer', 'start', 'read the brief before touching the schema', '{"path":"docs/brief.md","what":"what we build and why"}'::jsonb, tags := array['start']);

select knowledge.put('demo', 'finding', 'schema-ready', 'the knowledge tables and functions pass their tests', '{"task":"T-12","hop":"functions","role":"backend-engineer"}'::jsonb);

select knowledge.put('demo', 'term', 'current', 'the latest row of every key, the view a session reads at the start', '{"definition":"the view knowledge.current: the newest row per project, kind and key"}'::jsonb);

select knowledge.link('demo', 'demo-store-epic', 'demo-store-goal');
select knowledge.link('demo', 'demo-store-task', 'demo-store-epic');

select scratch.put('demo', 'sess-demo', 'seq 1 120',
  (select string_agg('line ' || g, E'\n' order by g) from generate_series(1, 120) g));

set role agent;

create table ds.demo_titles (id int, title text, verdict text);
insert into ds.demo_titles (id, title, verdict) values
  (1, 'senior backend engineer', 'good fit'),
  (2, 'junior frontend developer', 'maybe'),
  (3, 'staff data engineer', 'good fit'),
  (4, 'product manager', 'skip'),
  (5, 'devops engineer', 'maybe'),
  (6, 'qa automation engineer', 'good fit'),
  (7, 'engineering manager', 'skip');
select ds.register('demo', 'demo_titles', 'seven sample title verdicts for the demo project');

reset role;
