-- 004-tasks-repo-branch-hop.sql: a task's repo, branch and hop (planned, tests+code, test check,
-- fix round, review, merged, released), so the session hook can print where a task stands.
-- Additive, nullable, idempotent. A BEFORE INSERT OR UPDATE trigger fills repo from ref
-- ("<repo>#<n>") when repo is left null; the backfill below is the one data change this hop
-- makes, for rows that predate the trigger.
alter table knowledge.tasks add column if not exists repo text, add column if not exists branch text, add column if not exists hop text;

create or replace function knowledge.tasks_repo_from_ref() returns trigger as $$
begin
  if new.repo is null and new.ref ~ '^[a-z0-9.-]+#[0-9]+$' then
    new.repo := split_part(new.ref, '#', 1);
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists tasks_repo_from_ref_trg on knowledge.tasks;
create trigger tasks_repo_from_ref_trg
  before insert or update on knowledge.tasks
  for each row execute function knowledge.tasks_repo_from_ref();

update knowledge.tasks set repo = split_part(ref, '#', 1)
  where repo is null and ref ~ '^[a-z0-9.-]+#[0-9]+$';
