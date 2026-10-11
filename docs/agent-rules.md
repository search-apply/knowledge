# knowledge plugin: agent rules

Paste this into a client that cannot load the plugin's skills (for example Cursor or Codex). It
carries the same rules the skills teach. Reach every function through the MCP `execute_sql` tool.
`<project>` is this repository's name unless you set `KNOWLEDGE_PROJECT`.

## knowledge (curated, kept for years)
- Start by looking at what is stored: `select kind, key, text from knowledge.current where project = '<project>' order by created_at desc limit 30;` then tell the user in one sentence whether the store is up and what is there. Never show the query.
- Find things: `select * from knowledge.search('<project>', 'some words', 'decision');`
  one row: `select * from knowledge.get(42);` a kind: `select * from knowledge.list('<project>','state');`
- The main session connects as `master` and may write; a spawned subagent connects as `agent` and
  may only read. So write only from the main session.
- Write with `knowledge.put('<project>', <kind>, <key>, <text>, <fields jsonb>)`. A new put on the
  same project+kind+key supersedes the old row. A row is at most three lines and 600 characters.
- Kinds: decision, fact, state, pointer, lesson, finding, section, incident, environment, recipe,
  term. Each kind requires its own fields; a miss raises an error. Add a kind with
  `knowledge.add_kind(name, description, '["field"]'::jsonb)`.
- Never store secrets, personal data, transcripts, or model replies.

## scratch (automatic command-output overflow)
- A large Bash output is stored and replaced in context by a short digest naming a `scratch#<id>`.
- Read it back instead of re-running the command: `select * from scratch.read(<id>, 1, 200);`
  by pattern `select * from scratch.grep(<id>, 'ERROR');` ends `scratch.head(<id>)` / `scratch.tail(<id>)`.
- Rows expire after seven days. Never re-run a command just to see its output again.

## datasets (tables an agent builds)
- Create a table in `ds`, insert in batches, then `select ds.register('<project>','name','summary');`
- Load a file: `docker exec -i knowledge psql -U agent -d knowledge -c '\copy ds.name from stdin csv header' < file.csv`
- Describe before you query: `select * from ds.describe('name');`
- Query read-only with a cap: `select * from ds.sql('<project>', 'select col, count(*) from ds.name group by 1');`
  a result past the cap is saved as `ds.result_<n>`. A raw select carries its own `LIMIT`; never read a table whole.
- Return a short summary plus the table name, never the rows.
