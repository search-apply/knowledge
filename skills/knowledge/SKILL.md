---
name: knowledge
description: The project's memory in Postgres. At the start read what is stored and tell the user in one sentence. A task gets a tasks row, a decision or a lesson gets a notes row with the task ref and the session id, the end of a session gets state and next notes. The main session writes, subagents only read.
user-invocable: false
---

# The knowledge store

One Postgres database, one schema `knowledge`, reached through the MCP tool `execute_sql`. The main session connects as `master` and writes. A spawned subagent connects as `agent` and reads, and may make tables of its own (the `data` skill). The session-start hook prints one line with the session id and the project name. Use both in every write, as `<session>` and `<project>` below. No hook line (another client): leave `session` null. MCP down: the main session falls back to `docker exec -i knowledge psql -U postgres -d knowledge -At <<'SQL' ... SQL`; an agent without that access gets the recipe pasted into its brief.

## The tables
| table | one row is | key |
|---|---|---|
| projects | a project | name |
| sessions | one Claude Code session: started_at, ended_at, summary | id, the session id |
| tasks | a unit of work: title, url, status, project_item_id, repo, branch, hop | project, ref |
| notes | one thing worth keeping: kind, key, text, ref, session, created_at | id |
| current | a view: the newest note per project, kind and key | |
| kinds | decision, fact, state, lesson, pointer, incident, recipe, term, next, summary | name |
| datasets | a table of your own in this schema, with what it holds, ref, session | table_name |
| handoffs | one row per boundary: text (one screen: newest facts first, what to read last), notes (the ids to read), task_ref, repos, session, created_at | id |
| reports | a research report: slug, question, verdict, method, sources, body, ref | slug |

A task's `ref` is whatever names it where work is tracked: `#41`, `PROJ-42`, `docs/plan.md` or a URL. A new `ref` gets a stub `tasks` row automatically (title = the ref); give it a real title/url with the upsert when you know them. A note's `key` is `<area>-<topic>`, like `billing-cancel`; areas in use: `webui-`, `nextjs-`, `ops-`, `release-`, `stripe-`, `bedrock-`. Text is at most 2000 characters (a check constraint, it stays). Notes are only ever inserted; the same key again is the new truth, `current` shows it, the old note stays as history. `recipe` = an `ops-<topic>` operation a future session will run again (prefer it over burying steps in an incident note); `state` = a point-in-time status a handoff cites; `incident` = what broke, its cause, its fix. A report by slug: `select question, verdict, body from knowledge.reports where slug = '<slug>';`

## At the start, and after a compaction
The hook prints the newest handoff for the project, or `knowledge: no handoff yet`. Read its notes, then the open tasks:
```sql
select n.kind, n.key, n.text from knowledge.handoffs h join knowledge.notes n on n.id = any(h.notes) or n.session = h.session where h.id = <id> order by n.created_at;
select ref, title, status from knowledge.tasks where project = '<project>' and status <> 'done';
```
Then run the handoff retention delete (the end section, one statement). Tell the user one sentence, never the query. No handoff: "The knowledge store is up. I will keep structured notes here on what we work on." A handoff: "The knowledge store is up. The last handoff says: <one line>."

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
Fill `project_item_id` (`PVTI_...`) from `gh project item-list 5 --owner search-apply --format json`, matched by content.repository + content.number, then an `update ... set project_item_id`. A board move is one `updateProjectV2ItemFieldValue` per item, from a python loop; a zsh `set --` loop broke the GraphQL args. Store a decision when it is made, a lesson when something bit, a fact when it was verified, a pointer when a place proved worth reading, an incident with its cause and fix, a recipe with its steps, a term with its definition, a summary when a task closes.

## At the end, and before a compaction
Every insert into notes ends with `returning id`. Keep the ids. Write the handoff, one screen, newest facts first: what is live, what is in flight, the next steps as the user worded them, what is open, and last of all what to read first. Then close the session:
```sql
insert into knowledge.handoffs (project, session, text, notes, task_ref, repos) values ('<project>', '<session>', '<one screen>', array[<ids>], '<repo>#<n>', array['<repo>', ...]) returning id;
update knowledge.sessions set ended_at = now(), summary = 'Built the cancel flow for #41, tests green, merged.' where id = '<session>';
```
Ids lost after a compaction: pass `'{}'`, the notes of this session are found through `session`. The kinds `state` and `next` stay for notes that are not a boundary.
Handoff rows are not history, the notes are: the newest row per UTC day stays, the per-turn rows of the day go. Notes sort the same way: a fact, decision, recipe, incident, pointer or term is product or project truth and stays; a lesson becomes a line in the skill it binds the same day and the note only records who ruled and when; a `state` note lives until the newest handoff stops naming it; `next` is never a note (the handoff's NEXT line is); `summary` once per closed Epic. Run this delete at every session start, right after reading the newest handoff; it keeps the newest row of every day, today's included, so it is always safe and days apart do not matter:
```sql
delete from knowledge.handoffs h where h.project = '<project>' and h.id not in (select distinct on ((created_at at time zone 'UTC')::date) id from knowledge.handoffs where project = '<project>' order by (created_at at time zone 'UTC')::date, created_at desc);
delete from knowledge.notes where project = '<project>' and kind in ('state','next') and created_at < now() - interval '7 days' and key not like 'release-live-%' and id <> all ((select coalesce(notes, '{}') from knowledge.handoffs where project = '<project>' order by id desc limit 1)::bigint[]);
```

## Finding things (either role)
```sql
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
No secrets, no personal data, no transcripts, no model replies. Never more than 40 lines of query output into the context: add a `limit`.
