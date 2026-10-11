-- 05-defaults.sql: the ten built-in kinds.

insert into knowledge.kinds (name, description, fields) values
  ('decision', 'a ruling with its why and the options it chose among', '["why","options","who_ruled"]'::jsonb),
  ('fact', 'a verified fact', '["verified_on","how"]'::jsonb),
  ('state', 'a current state value', '["value"]'::jsonb),
  ('pointer', 'a pointer to a place worth reading', '["path","what"]'::jsonb),
  ('lesson', 'a lesson learned from an incident', '["incident","rule"]'::jsonb),
  ('finding', 'a finding from one hop of one task', '["task","hop","role"]'::jsonb),
  ('incident', 'an incident record', '["date","what","cause","fix"]'::jsonb),
  ('environment', 'a fact about the running environment', '["name","value"]'::jsonb),
  ('recipe', 'a recipe with its steps', '["steps","pointer"]'::jsonb),
  ('term', 'a defined term', '["definition"]'::jsonb);
