---
name: knowledge
description: The curated store: recall first, then search by kind and key, get one row; only the master puts; every put names its issue and ends the hop comment with the ids stored.
user-invocable: false
---

# The knowledge store

Curated memory kept for years, one project per store (the `KNOWLEDGE_PROJECT` env is the `project` column). Install and connect: the README. Reach every function through the MCP `execute_sql` tool.

## The map
- Kinds (the `kind` column): decision, fact, state, pointer, lesson, finding, section, incident, environment, recipe, term. A project adds its own with `add_kind`.
- A row is at most three lines and 600 characters.

| column | meaning |
|---|---|
| id | the row id, cited as `k#<id>` |
| project kind key | the identity; a new put on the same three supersedes the old |
| text | the body, at most three lines |
| fields | the kind's required fields, as jsonb |
| issue commit source | provenance of the row |
| who tags created_at superseded_by | author, tags, time, the newer row |

## Reading (any role)
- Recall the project at session start: `select knowledge.recall('<project>');`
- Search by words, optional kind: `select * from knowledge.search('<project>', 'webhook cancel', 'decision');`
- Get one row by id: `select * from knowledge.get(42);`
- List a kind newest first: `select * from knowledge.list('<project>', 'state');`
- About an issue and its parents: `select * from knowledge.about('<project>', '#7');`

## Writing (only the master)
- Put a row; a new put on the same key supersedes: `select knowledge.put('<project>', 'decision', 'stripe-cancel', 'one to three lines', '{"why":"...","options":"...","who_ruled":"operator"}'::jsonb, issue => '#7');`
- Each kind requires its fields; a miss raises `knowledge.put: kind % requires field %`.
- Over three lines raises `knowledge.put: text has more than three lines or 600 characters`.
- Replace a row, keep its identity: `select knowledge.supersede(42, 'the new text');` a stale id raises `knowledge.supersede: row % not found or not current`.
- Link an issue to its parent: `select knowledge.link('<project>', '#7', '#9');`
- Add a kind with its required fields: `select knowledge.add_kind('convention', 'a house convention', '["rule"]'::jsonb);`

## Boundary (the master, before a compaction)
- Write the hop's state keys, decisions and lessons as rows.
- Export the project with the handoff: `select knowledge.export('<project>', 'json');`
- Take a `pg_dump` backup before any schema change.

## Never
- No secrets, no personal data, no transcripts, no agents' replies.
