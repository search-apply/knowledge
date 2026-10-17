-- 001-notes-ref-stub.sql: a note's ref must exist in knowledge.tasks (the FK stays). Before this,
-- a note whose ref had no matching tasks row failed outright. Now a BEFORE INSERT trigger on
-- notes creates a stub tasks row first when one is missing, so the insert never fails on the FK;
-- give the stub a real title/url later with the upsert in the knowledge skill. Additive, no data
-- change: existing notes and tasks are untouched; idempotent via create or replace / drop+create.
create or replace function knowledge.notes_stub_task() returns trigger as $$
begin
  if new.ref is not null then
    insert into knowledge.tasks (project, ref, title, url, status)
    values (new.project, new.ref, new.ref, null, 'open')
    on conflict (project, ref) do nothing;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists notes_stub_task_trg on knowledge.notes;
create trigger notes_stub_task_trg
  before insert on knowledge.notes
  for each row execute function knowledge.notes_stub_task();
