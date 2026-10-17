-- 002-tasks-project-item-id.sql: a task's GitHub ProjectV2 item id (PVTI_...), so a board move
-- does not need gh project item-list again. Nullable, additive, idempotent.
alter table knowledge.tasks add column if not exists project_item_id text;
