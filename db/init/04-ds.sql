-- the ds schema (the model's own tables) -- grants and the agent timeout.
grant usage, create on schema ds to master, agent;
alter role agent set statement_timeout = '5s';
