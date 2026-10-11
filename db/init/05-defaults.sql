-- 05-defaults.sql: the eleven built-in kinds and the `*` config defaults.

insert into knowledge.kinds (name, description, fields) values
  ('decision', 'a ruling with its why and the options it chose among', '["why","options","who_ruled"]'::jsonb),
  ('fact', 'a verified fact', '["verified_on","how"]'::jsonb),
  ('state', 'a current state value', '["value"]'::jsonb),
  ('pointer', 'a pointer to a place worth reading', '["path","what"]'::jsonb),
  ('lesson', 'a lesson learned from an incident', '["incident","rule"]'::jsonb),
  ('finding', 'a finding from one hop of one task', '["task","hop","role"]'::jsonb),
  ('section', 'a markdown section indexed by heading', '["file","heading","lines","summary"]'::jsonb),
  ('incident', 'an incident record', '["date","what","cause","fix"]'::jsonb),
  ('environment', 'a fact about the running environment', '["name","value"]'::jsonb),
  ('recipe', 'a recipe with its steps', '["steps","pointer"]'::jsonb),
  ('term', 'a defined term', '["definition"]'::jsonb);

insert into knowledge.config (project, name, value) values
  ('*', 'recall.decision_days', '30'),
  ('*', 'recall.lesson_days', '14'),
  ('*', 'recall.section_cap', '10'),
  ('*', 'scratch.retention_days', '7'),
  ('*', 'scratch.digest_lines', '5'),
  ('*', 'scratch.read_cap', '200'),
  ('*', 'ds.row_cap', '50'),
  ('*', 'ds.sql_timeout_ms', '5000');
