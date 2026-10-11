---
name: knowledge
description: The project's memory in Postgres. At the start, look at what is stored and tell the user in one sentence. Store decisions, facts, state, lessons and pointers as short rows with knowledge.put. Search by words, kind or issue. The main session writes, subagents only read.
user-invocable: false
---

# The knowledge store

One Postgres database, reached through the MCP tool `execute_sql`. The main session connects as
`master` and may read and write. A spawned subagent connects as `agent` and may only read.
`KNOWLEDGE_PROJECT` names the project, by default the working directory's name.

## At the start of a session
1. `select kind, key, text, created_at from knowledge.current where project = '<project>' order by created_at desc limit 30;`
2. Tell the user one sentence, never the query. Nothing stored: "The knowledge store is up. I will
   keep structured notes here on what we work on." Rows found: "The knowledge store is up, with N
   notes on this project. The latest: <one line>."
3. Do the same after a compaction.

## The tables
`knowledge.rows` holds one row per item. Writing the same project, kind and key again adds a new
row and marks the old one superseded, so history stays.

| column | what |
|---|---|
| id | the row number |
| project | the project name |
| kind | one of the kinds below |
| key | a short stable name for the thing, like `billing-cancel` |
| text | one to three lines, at most 600 characters |
| fields | jsonb with the kind's required fields |
| issue | the ticket it belongs to, like `#12`, optional |
| commit, source, who, tags | where it came from |
| created_at, superseded_by | when, and the newer row if there is one |

`knowledge.current` is the latest row of every project, kind and key. Read this, not `rows`,
unless you want the history.

`knowledge.kinds` lists the kinds with the fields each requires:

| kind | fields | use it for |
|---|---|---|
| decision | why, options, who_ruled | a ruling and why it was made |
| fact | verified_on, how | a verified fact |
| state | value | what is running, what is in progress |
| pointer | path, what | a place worth reading |
| lesson | incident, rule | what an incident taught |
| finding | task, hop, role | a finding from one piece of work |
| incident | date, what, cause, fix | an incident record |
| environment | name, value | a fact about the running environment |
| recipe | steps, pointer | how to do something |
| term | definition | a defined term |

Add a kind: `insert into knowledge.kinds values ('convention', 'a house convention', '["rule"]');`

## Store (main session only)
- `select knowledge.put('<project>', 'decision', 'billing-cancel', 'the subscription ends at cancel_at, never at the webhook time', '{"why": "scheduled cancels were parsed as immediate", "options": "cancel_at, webhook time", "who_ruled": "operator"}', issue => '#12');`
- The same key again supersedes the old row. A missing field or a text over three lines raises an
  error that says which.
- Store a decision when it is made, a lesson when something bit, a state when it changes, a pointer
  when a place proved worth reading. Never secrets, personal data, transcripts or model replies.

## Read (either role)
- By words: `select * from knowledge.search('<project>', 'webhook cancel');` a kind as the third argument narrows it.
- By kind: `select key, text from knowledge.current where project = '<project>' and kind = 'decision' order by created_at desc;`
- By issue: `select kind, key, text from knowledge.current where project = '<project>' and issue = '#12';`
- History of a key: `select id, text, created_at, superseded_by from knowledge.rows where project = '<project>' and key = 'billing-cancel' order by created_at;`

## Command output
Never let a command print more than 40 lines into the context. Use `| head -40`, `| tail -40`,
`| grep`, or write the output to a file and read the part you need.
