---
name: knowledge
description: The project's memory in Postgres. At the start read what is stored and tell the user in one sentence. A task gets a tasks row, a decision or a lesson gets a notes row with the task ref and the session id, the end of a session gets state and next notes. The main session writes, subagents only read.
user-invocable: false
---

# The knowledge store

One Postgres database, one schema `knowledge`, reached through the MCP tool `execute_sql`. The
main session connects as `master` and writes. A spawned subagent connects as `agent` and reads,
and may make tables of its own (the `data` skill). The session-start hook prints one line with the
session id and the project name. Use both in every write, as `<session>` and `<project>` below.
No hook line (another client): leave `session` null.

## The tables
| table | one row is | key |
|---|---|---|
| projects | a project | name |
| sessions | one Claude Code session: started_at, ended_at, summary | id, the session id |
| tasks | a unit of work: title, url, status | project, ref |
| notes | one thing worth keeping: kind, key, text, ref, session, created_at | id |
| current | a view: the newest note per project, kind and key | |
| kinds | decision, fact, state, lesson, pointer, incident, recipe, term, next, summary | name |
| datasets | a table of your own in this schema, with what it holds, ref, session | table_name |

A task's `ref` is whatever names it where work is tracked: `#41`, `PROJ-42`, `docs/plan.md` or a
URL. A note's `ref` must be a row in `tasks`, so insert the task first or leave `ref` null. A
note's `key` is `<area>-<topic>`, like `billing-cancel`. Text is at most 2000 characters. Notes
are only ever inserted. The same key again is the new truth, `current` shows it, the old note
stays as history. A new kind: `insert into knowledge.kinds values ('convention', 'a house convention');`

## At the start, and after a compaction
```sql
select kind, key, text from knowledge.current where project = '<project>' and kind in ('state', 'next');
select kind, key, text, created_at from knowledge.current where project = '<project>' order by created_at desc limit 30;
```
Tell the user one sentence, never the query. Nothing stored: "The knowledge store is up. I will
keep structured notes here on what we work on." Rows found: "The knowledge store is up, with N
notes on this project. The latest: <one line>."

## While working (main session only)
```sql
-- a task starts
insert into knowledge.tasks (project, ref, title, url, status) values ('<project>', '#41', 'Cancel at period end', 'https://github.com/acme/demo/issues/41', 'open')
  on conflict (project, ref) do update set title = excluded.title, url = excluded.url, status = excluded.status;
-- something is decided, learned, changed or found
insert into knowledge.notes (project, kind, key, text, ref, session)
  values ('<project>', 'decision', 'billing-cancel', 'Cancel at the period end, never at the webhook time. Operator ruling.', '#41', '<session>');
-- a task ends
update knowledge.tasks set status = 'done' where project = '<project>' and ref = '#41';
```
Store a decision when it is made, a lesson when something bit, a fact when it was verified, a
pointer when a place proved worth reading, an incident with its cause and fix, a recipe with its
steps, a term with its definition, a summary when a task closes.

## At the end, and before a compaction
A `state` note (what is up, what is in flight) and a `next` note (the next steps, as the user
worded them), then close the session:
```sql
update knowledge.sessions set ended_at = now(), summary = 'Built the cancel flow for #41, tests green, merged.' where id = '<session>';
```

## Finding things (either role)
```sql
-- open work
select ref, title, status from knowledge.tasks where project = '<project>' and status <> 'done';
-- everything about one task
select kind, key, text, created_at from knowledge.notes where project = '<project>' and ref = '#41' order by created_at;
-- by kind, by area, by words
select key, text from knowledge.current where project = '<project>' and kind = 'lesson';
select kind, key, text from knowledge.current where project = '<project>' and key like 'billing-%';
select kind, key, text from knowledge.current where project = '<project>' and to_tsvector('simple', key || ' ' || text) @@ websearch_to_tsquery('simple', 'cancel webhook');
-- the history of one key
select text, created_at from knowledge.notes where project = '<project>' and key = 'billing-cancel' order by created_at;
-- what one session did, and the last sessions
select s.started_at, s.summary, n.kind, n.key from knowledge.sessions s left join knowledge.notes n on n.session = s.id where s.id = '<session>';
select id, started_at, summary from knowledge.sessions where project = '<project>' order by started_at desc limit 10;
-- the last month, per task
select t.ref, t.title, t.status, count(*) as notes, min(n.created_at), max(n.created_at) from knowledge.tasks t
  join knowledge.notes n on n.project = t.project and n.ref = t.ref
  where t.project = '<project>' and n.created_at >= now() - interval '30 days' group by t.ref, t.title, t.status order by max(n.created_at) desc;
-- a decision and the session that made it
select n.text, s.started_at, s.summary from knowledge.notes n join knowledge.sessions s on s.id = n.session where n.project = '<project>' and n.kind = 'decision' and n.key = 'billing-cancel';
-- the data behind a task
select table_name, what from knowledge.datasets where project = '<project>' and ref = '#41';
```
A question about the past starts at `tasks` or `sessions`, then joins `notes`.

## Never
No secrets, no personal data, no transcripts, no model replies. Never more than 40 lines of query
output into the context: add a `limit`.
