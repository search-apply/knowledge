---
name: data
description: Your own tables for the rows a piece of work produces, in the knowledge schema, each registered with one datasets row so the next session finds it. Either role may create them.
user-invocable: false
---

# Your own tables

Rows of data a piece of work produces, like research results, measurements or lists to compare,
go into a table of your own instead of the context. It lives in the `knowledge` schema next to the
default tables. Any role may create one, the main session and subagents alike. Reach it through
the MCP tool `execute_sql`.

## The shape
- Name: `knowledge.<project>_<topic>`, lowercase with underscores, like `knowledge.demo_titles`.
- Columns: whatever the data needs, plus `created_at timestamptz default now()`.
- Register it with one row in `knowledge.datasets`, with the task it belongs to and the session
  that made it. A table without a datasets row is invisible to the next session.

```sql
create table knowledge.demo_titles (title text, verdict text, created_at timestamptz default now());
insert into knowledge.datasets (table_name, project, ref, session, what)
  values ('demo_titles', '<project>', '#42', '<session>', 'Seven job titles with the verdict the parser gave each, from the 2026-10 bakeoff');
insert into knowledge.demo_titles (title, verdict) values ('Senior QA', 'tester'), ('SDET', 'tester');
```

## The map
- What exists: `select table_name, what, ref, created_at from knowledge.datasets where project = '<project>';`
- The data behind a task: the same query with `and ref = '#42'`.
- The columns of one table: `select column_name, data_type from information_schema.columns where table_schema = 'knowledge' and table_name = 'demo_titles';`

## Reading
- Always a limit: `select title, verdict from knowledge.demo_titles order by created_at desc limit 50;`
- Summarise instead of listing: `select verdict, count(*) from knowledge.demo_titles group by 1 order by 2 desc;`
- The agent role has a five-second statement timeout. A query that times out needs a narrower
  where clause or an index. Load in batches of a few thousand rows.
- In a reply, give table names and counts, never the rows.

## Keeping it tidy
- One table per topic. When its work is done and the result is a note, drop the table and delete
  its datasets row: `drop table knowledge.demo_titles; delete from knowledge.datasets where table_name = 'demo_titles';`
