-- 003-handoffs-task-ref.sql: a handoff names the task in work (task_ref, as "<repo>#<n>") and the
-- repos touched this stretch, so the session hook can print the restore map without a second
-- round trip through the issue tracker. Additive, nullable, idempotent.
alter table knowledge.handoffs add column if not exists task_ref text, add column if not exists repos text[];
