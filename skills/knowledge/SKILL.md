---
name: knowledge
description: The curated store. At the start, look at what is stored and tell the user in one sentence. Search by words and kind, get one row by id. The main session writes, spawned subagents only read. A row is at most three lines.
user-invocable: false
---

# The knowledge store

Curated memory kept for years, one project per store. The `KNOWLEDGE_PROJECT` env sets the
`project` column; it defaults to the working directory's name. Install and connect: the README.
Reach every function through the MCP `execute_sql` tool.

Two database roles sit behind the MCP. The main Claude Code session connects as `master` and may
read and write. A spawned subagent connects as `agent` and may only read. In short: the main
session writes, spawned subagents read.

## The map
- Kinds (the `kind` column): decision, fact, state, pointer, lesson, finding, section, incident,
  environment, recipe, term. Add your own with `add_kind`.
- A row is at most three lines and 600 characters.

| column | meaning |
|---|---|
| id | the row id, cited as `k#<id>` |
| project kind key | the identity; a new put on the same three supersedes the old |
| text | the body, at most three lines |
| fields | the kind's required fields, as jsonb |
| issue | optional: a reference to a ticket this row belongs to |
| commit source | the commit it rode in on and where it came from |
| who tags created_at superseded_by | author, tags, time, the newer row |

## At the start of a session (main session)
- Look at what is stored: `select kind, key, text from knowledge.current where project = '<project>' order by created_at desc limit 30;`
- Then tell the user one sentence, never the query. Nothing stored: "The knowledge store is up. I will keep structured notes here on
  what we work on." Rows found: "The knowledge store is up, with N notes on this project. The latest: <one line>."
- Do the same after a compaction.

## Reading (either role)
- Search by words, optional kind: `select * from knowledge.search('<project>', 'webhook cancel', 'decision');`
- Get one row by id: `select * from knowledge.get(42);`
- List a kind newest first: `select * from knowledge.list('<project>', 'state');`
- Follow a ticket to its parents: `select * from knowledge.about('<project>', 'billing-epic');`
- List rows gone stale: `select * from knowledge.stale('<project>', 30);`

## Writing (main session only)
- Put a row; a new put on the same key supersedes: `select knowledge.put('<project>', 'decision', 'stripe-cancel', 'one to three lines', '{"why":"...","options":"...","who_ruled":"operator"}'::jsonb, issue => 'billing-ticket');`
- Each kind requires its fields; a miss raises `knowledge.put: kind % requires field %`.
- Over three lines raises `knowledge.put: text has more than three lines or 600 characters`.
- Replace a row, keep its identity: `select knowledge.supersede(42, 'the new text');` a stale id raises `knowledge.supersede: row % not found or not current`.
- Link a ticket to its parent: `select knowledge.link('<project>', 'billing-task', 'billing-epic');`
- Add a kind with its required fields: `select knowledge.add_kind('convention', 'a house convention', '["rule"]'::jsonb);`

## Indexing
- `bin/index-headings <project> <path>...` writes one `section` row per markdown heading, keyed
  `<file>#<slug>`, with `file`, `heading`, `lines` and `summary` in its fields. A rerun supersedes
  a heading that moved or changed and keeps the rest. Search them with the `section` kind.

## Never
- No secrets, no personal data, no transcripts, no model replies.
