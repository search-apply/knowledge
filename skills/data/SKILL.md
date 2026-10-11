---
name: data
description: Your own tables in the ds schema of the knowledge store. How to shape a table so it lines up with the rest, how to describe it, how to find what exists, how to read it without flooding the context.
user-invocable: false
---

# Your own tables

The `ds` schema is yours. Any role may create tables there, the main session and subagents alike.
Use it for rows of data a piece of work produces, like research results, measurements or lists to
compare, instead of pasting them into the context. Reach it through the MCP tool `execute_sql`.

## The shape
- Name: `ds.<project>_<topic>`, lowercase with underscores, like `ds.demo_titles`.
- Columns: whatever the data needs, plus `created_at timestamptz default now()`. Add a
  `project text` column only when one table mixes projects.
- Describe it, one sentence on what it holds and where it came from:
  `comment on table ds.demo_titles is 'seven job titles with the role the parser gave each, from the 2026-10 bakeoff';`
  A table without a comment is invisible to the next session.
- Load it: `insert into ds.demo_titles (title, verdict) values ('Senior QA', 'tester'), ('SDET', 'tester');`

## The map
- What exists:
  ```
  select c.relname as table_name, obj_description(c.oid) as what, s.n_live_tup as rows
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  left join pg_stat_user_tables s on s.relid = c.oid
  where n.nspname = 'ds' and c.relkind = 'r' order by c.relname;
  ```
- The columns of one table:
  `select column_name, data_type from information_schema.columns where table_schema = 'ds' and table_name = 'demo_titles';`

## Reading
- Always a limit: `select title, verdict from ds.demo_titles order by created_at desc limit 50;`
- Summarise instead of listing: `select verdict, count(*) from ds.demo_titles group by 1 order by 2 desc;`
- The agent role has a five-second statement timeout. A query that times out needs a narrower
  where clause or an index.
- In a reply, give table names and counts, never the rows.

## Keeping it tidy
- One table per topic. Drop a table when its work is done and its result is stored as a knowledge
  row: `drop table ds.demo_titles;`
- A table that must stay gets a knowledge `pointer` row: key = the table name, path = `ds.demo_titles`,
  what = the comment.
