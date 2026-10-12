-- demo.sql: seed data for the fake project 'demo' (the README demo). Load by hand only, never by
-- init, never by the test runner:
--   docker exec -i <container> psql -U postgres -d knowledge < db/seed/demo.sql

insert into knowledge.projects (name) values ('demo');

insert into knowledge.sessions (id, project, started_at, ended_at, summary) values
  ('3f2a', 'demo', '2026-10-10 09:12', '2026-10-10 11:40', 'Built the cancel flow for #41, tests green, merged.'),
  ('9c1e', 'demo', '2026-10-11 08:00', null, null);

insert into knowledge.tasks (project, ref, title, url, status) values
  ('demo', '#41', 'Cancel at period end', 'https://github.com/acme/demo/issues/41', 'done'),
  ('demo', '#42', 'Webhook replay', 'https://github.com/acme/demo/issues/42', 'open');

insert into knowledge.notes (project, kind, key, text, ref, session) values
  ('demo', 'decision', 'billing-cancel', 'Cancel at the period end, never at the webhook time. Operator ruling.', '#41', '3f2a'),
  ('demo', 'lesson', 'stripe-webhook', 'A scheduled cancel arrives as an update with cancel_at set, not as a delete.', '#41', '3f2a'),
  ('demo', 'summary', 'task-41', 'Cancel flow built and merged. Two tests cover the scheduled cancel.', '#41', '3f2a'),
  ('demo', 'state', 'release', '0.4.0 on the release branch, tests green, not merged.', null, '9c1e'),
  ('demo', 'next', 'release', 'Merge 0.4.0 on the user''s word, then tag.', null, '9c1e');

create table knowledge.demo_titles (
  title text,
  verdict text,
  created_at timestamptz default now()
);
insert into knowledge.demo_titles (title, verdict) values
  ('senior backend engineer', 'good fit'),
  ('junior frontend developer', 'maybe'),
  ('staff data engineer', 'good fit'),
  ('product manager', 'skip'),
  ('devops engineer', 'maybe'),
  ('qa automation engineer', 'good fit'),
  ('engineering manager', 'skip');

insert into knowledge.datasets (table_name, project, ref, session, what) values
  ('demo_titles', 'demo', '#42', '9c1e', 'Seven job titles with the verdict the parser gave each');

insert into knowledge.handoffs (project, session, text, notes) values
  ('demo', '3f2a', 'Live: the cancel flow for #41, merged. Next: the webhook replay in #42. Read the lesson stripe-webhook first.',
   (select array_agg(id) from knowledge.notes where project = 'demo' and (key, kind) in (('billing-cancel', 'decision'), ('stripe-webhook', 'lesson'))));
