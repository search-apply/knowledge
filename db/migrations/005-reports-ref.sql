-- 005-reports-ref.sql: a report's ref, the Research issue it answers, so the session hook can
-- list every report for the task in work. Additive, nullable, idempotent.
alter table knowledge.reports add column if not exists ref text;
