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

select knowledge.put('demo', 'term', 'recall', 'the short text a session reads when a project starts', '{"definition":"the short text a session reads when a project starts"}'::jsonb);

select knowledge.link('demo', 'demo#2', 'demo#1');
select knowledge.link('demo', 'demo#3', 'demo#2');
