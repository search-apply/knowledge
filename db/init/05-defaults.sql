-- 05-defaults.sql: the ten built-in kinds.

insert into knowledge.kinds (name, description) values
  ('decision', 'a ruling, as it was made'),
  ('fact', 'a verified fact, with how it was verified'),
  ('state', 'what is up and what is in flight, right now'),
  ('lesson', 'what an incident or a mistake taught'),
  ('pointer', 'a place worth reading, and why'),
  ('incident', 'what broke, its cause and its fix'),
  ('recipe', 'how to do something, step by step'),
  ('term', 'a defined term'),
  ('next', 'the next steps, as the user worded them'),
  ('summary', 'what a task or a piece of work came to');
