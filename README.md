# knowledge

A memory for coding agents: one Postgres container on your machine, a standard Postgres MCP
server in front of it, and two short skills that teach the model how to store what it learns and
how to find it again. Shipped as a Claude Code plugin. The plugin starts its own container, so
after installing it you only tell your model to use it. Nothing leaves your machine.

## What a session says at start

When a session starts, the plugin makes sure the store is up, records the session, and gives the
model one line with the session id and the project name, then the newest handoff for the project.
The model reads the notes behind it and tells you in one sentence. On a new project:

```
The knowledge store is up. I will keep structured notes here on what we work on.
```

Later, with a handoff stored:

```
The knowledge store is up. The last handoff says: the cancel flow for #41 is merged, next is the
webhook replay in #42.
```

What the plugin prints is for the model. The model reads the store and speaks.

## Requirements

- Docker, running. Docker Desktop on macOS, or the Docker engine on Linux.
- macOS or Linux, with `bash` and `jq` on the PATH.
- Windows only through WSL, untested.

That is all. The plugin pulls the two images it needs on first use.

## Quickstart

Install from the marketplace:

```
claude plugin marketplace add search-apply/knowledge
claude plugin install knowledge@knowledge
```

Then open Claude Code in any repository. The store comes up on its own at the start of the session.
On that first start the plugin, in the background:

- writes `$HOME/.config/knowledge/env` with random passwords, readable only by you
- creates a private docker network and the `knowledge` container on it, from `postgres:18`, with a
  named volume for the data
- pulls the Postgres MCP image

The first start takes a few seconds. That first session prints one line saying the store is coming
up and will be used from the next command on. Every session after that opens with the sentence
shown above, for your project. If Docker is not running, the plugin says so once and stays out of
the way.

Telling the model

```
use the knowledge plugin
```

starts nothing. It only tells the model to lean on the store that is already there.

## What is in the database

One schema, `knowledge`. Seven default tables and one view, created once when the container is
made. The model's own tables live in the same schema, next to them.

### The default tables

| table | one row is | key |
|---|---|---|
| `projects` | a project, by default the working directory's name | name |
| `sessions` | one Claude Code session, with when it started and ended and a summary | id, the session id |
| `tasks` | a unit of work: a ticket, a page, a file | project and ref |
| `notes` | one thing worth keeping, of one kind, under one key, at most 2000 characters | id |
| `kinds` | the vocabulary for notes | name |
| `datasets` | a table the model made, with what it holds | table_name |
| `handoffs` | one screen written at a boundary: what is live, in flight, next, open, what to read, with the ids of the notes behind it | id |

The view `knowledge.current` shows the newest note per project, kind and key. Notes are never
updated or deleted. A new note under the same key is the new truth and the view shows it. The old
notes stay as history.

Every note can point at a task (`ref`) and at the session that wrote it (`session`). A task's
`ref` is whatever names it where you track work: `#41` for a GitHub issue, `PROJ-42` for Jira,
`docs/plan.md` for a file, or a URL. That is how a question like "what did we decide on the
billing task last month" becomes one join.

Rows of the bundled `demo` project. The tasks:

| project | ref | title | url | status |
|---|---|---|---|---|
| demo | #41 | Cancel at period end | https://github.com/acme/demo/issues/41 | done |
| demo | #42 | Webhook replay | https://github.com/acme/demo/issues/42 | open |

The notes:

| kind | key | text | ref | session |
|---|---|---|---|---|
| decision | billing-cancel | Cancel at the period end, never at the webhook time. Operator ruling. | #41 | 3f2a |
| lesson | stripe-webhook | A scheduled cancel arrives as an update with cancel_at set, not as a delete. | #41 | 3f2a |
| summary | task-41 | Cancel flow built and merged. Two tests cover the scheduled cancel. | #41 | 3f2a |
| state | release | 0.4.0 on the release branch, tests green, not merged. | | 9c1e |
| next | release | Merge 0.4.0 on the user's word, then tag. | | 9c1e |

The sessions:

| id | project | started_at | ended_at | summary |
|---|---|---|---|---|
| 3f2a | demo | 2026-10-10 09:12 | 2026-10-10 11:40 | Built the cancel flow for #41, tests green, merged. |
| 9c1e | demo | 2026-10-11 08:00 | | |

The datasets:

| table_name | project | ref | session | what |
|---|---|---|---|---|
| demo_titles | demo | #42 | 9c1e | Seven job titles with the verdict the parser gave each |

The handoff:

| session | text | notes |
|---|---|---|
| 3f2a | Live: the cancel flow for #41, merged. Next: the webhook replay in #42. Read the lesson stripe-webhook first. | {1,2} |

The kinds are the vocabulary: `decision`, `fact`, `state`, `lesson`, `pointer`, `incident`,
`recipe`, `term`, `next` and `summary`, each with one line saying what it is for. One insert
adds another.

### How the model uses them

- At the start it reads the newest handoff the hook printed, the notes behind it and the open
  tasks, and says the sentence above.
- A task starts: one row in `tasks`.
- Something is decided, learned, changed or found: one row in `notes`, with the task ref and the
  session id.
- Rows of data a piece of work produces, like a scraped list or a benchmark: a table of its own,
  `knowledge.<project>_<topic>`, plus one row in `datasets` saying what it holds.
- At the end, and before the context is compacted: one `handoffs` row, a screen of text with the
  ids of the notes written in this stretch, and the session's summary. After a compaction the
  plugin prints that handoff, the model reads its notes and goes on. There is no handoff file.

### The queries the model uses

- At the start, the notes behind the handoff the hook printed: `select n.kind, n.key, n.text from knowledge.handoffs h join knowledge.notes n on n.id = any(h.notes) or n.session = h.session where h.id = <id> order by n.created_at`
- At the end: `insert into knowledge.handoffs (project, session, text, notes) values ('<project>', '<session>', '<one screen>', array[12, 13])`
- A task starts: `insert into knowledge.tasks (project, ref, title, url, status) values ('<project>', '#41', 'Cancel at period end', 'https://...', 'open')`
- Something is decided: `insert into knowledge.notes (project, kind, key, text, ref, session) values ('<project>', 'decision', 'billing-cancel', 'Cancel at the period end.', '#41', '<session>')`
- Everything about a task: `select kind, key, text, created_at from knowledge.notes where project = '<project>' and ref = '#41' order by created_at`
- By words: `select kind, key, text from knowledge.current where project = '<project>' and to_tsvector('simple', key || ' ' || text) @@ websearch_to_tsquery('simple', 'cancel webhook')`
- What a session did: `select s.summary, n.kind, n.key from knowledge.sessions s left join knowledge.notes n on n.session = s.id where s.id = '<session>'`
- The last month per task: the tasks of the last 30 days joined to their notes, with a count and
  the first and last note time. The `knowledge` skill carries it and the rest.

### The model's own tables

The model keeps rows of data a piece of work produces, like research results or measurements, in
tables of its own in the same schema, instead of pasting them into the context. There are no fixed
scripts for them, only a shape, so the tables line up and the next session can find them:

- the name is `knowledge.<project>_<topic>`
- every table has a `created_at` column and one row in `knowledge.datasets` saying what it holds,
  which task it belongs to and which session made it
- every read has a `limit`, and a reply carries table names and counts, never the rows

Both roles may create such tables. The `agent` role has a five-second statement timeout, so a
runaway query from a subagent stops.

## How it works

- One container, `postgres:18`, on a private docker network, with a named volume for the data.
- Two MCP entries: `knowledge` (read and write) for the main session, and `knowledge-agent` (read
  only on the default tables, may create tables of its own) for spawned subagents. Both run the
  standard `crystaldba/postgres-mcp` image. The model talks to the database with its `execute_sql`
  tool.
- Two skills: `knowledge` (the tables, when to store what, the queries) and `data` (the shape of
  the model's own tables).
- Two hooks. At session start the store is brought up, the project and the session are recorded,
  the model gets one line with the session id and the project name, and a dump is taken once a
  day. Before any Bash command, a guard refuses the docker commands that would remove the volume.
- Nothing is sent anywhere. There is no telemetry and no network traffic from the plugin beyond
  pulling the two docker images.

## Database access

| role | grants | used by |
|---|---|---|
| `postgres` | superuser, owns the schema | `knowledge-up` only, for dump and restore |
| `master` | all on the `knowledge` schema | the main session's MCP entry (`knowledge`) |
| `agent` | read the default tables, create tables of its own and register them in `datasets`, five-second statement timeout | a subagent's MCP entry (`knowledge-agent`) |

A table made by one role is readable by the other.

The passwords live only in `$HOME/.config/knowledge/env`, readable only by you, generated on the
first start and never written into any config file. The MCP wrapper `bin/mcp` reads them and builds
the connection string when it launches.

Open psql by hand, no published port needed:

```
docker exec -it knowledge psql -U master -d knowledge
```

With `KNOWLEDGE_PORT` set, you can also connect to
`postgresql://master:...@localhost:$KNOWLEDGE_PORT/knowledge`. Without it the database is reachable
only on the private docker network.

To rotate a password, change it in Postgres, put the same value in the env file, then reconnect the
MCP servers from `/mcp`:

```
docker exec -it knowledge psql -U postgres -d knowledge -c "alter role master password '<new>'"
```

## Other clients

Any MCP client can point at the store. Each entry sets `DATABASE_URI` for the role it should use.
The plugin's own `.mcp.json` runs `bin/mcp master` and `bin/mcp agent`, so the password stays out
of the config. For another client, run the image directly:

```
docker run -i --rm --network knowledge \
  -e DATABASE_URI="postgresql://agent:<AGENT_PASSWORD>@knowledge:5432/knowledge" \
  crystaldba/postgres-mcp --access-mode=unrestricted
```

Cursor (`.cursor/mcp.json`) and Codex (`~/.codex/config.toml`, under `[mcp_servers.knowledge]`)
take the same `command`, `args` and `env` shape under their own config key. A client with no access
to the docker network reaches the container through a published port: set `KNOWLEDGE_PORT` and use
`postgresql://agent:<AGENT_PASSWORD>@localhost:$KNOWLEDGE_PORT/knowledge`.

A client that cannot load the plugin's skills can be given the two skill files as plain text. They
are in `skills/knowledge/SKILL.md` and `skills/data/SKILL.md`. Such a client does not get the
session line from the hook, so it inserts its project row once (`insert into knowledge.projects
(name) values ('<project>') on conflict do nothing`) and writes notes without a session id.

Subagents, from this plugin or any other, should get only the `knowledge-agent` entry, never the
writable one. Its tools appear under the prefix `mcp__plugin_knowledge_knowledge-agent__`. The
writable `knowledge` server's tools appear under `mcp__plugin_knowledge_knowledge__`. Allow a
subagent only the first, so that only the main session writes memory.

## Team use

The store is per machine. To move all of it, take a dump here and restore it there (see below).
To share one project, copy its sessions, tasks and notes to files, commit them, and load them on
the other machine in that order. The project row comes first:

```
P=knowledge; Q="docker exec -i knowledge psql -U master -d knowledge -c"
$Q "\copy (select * from knowledge.sessions where project = '<project>' order by started_at) to stdout csv header" > sessions.csv
$Q "\copy (select * from knowledge.tasks where project = '<project>' order by created_at) to stdout csv header" > tasks.csv
$Q "\copy (select project, kind, key, text, ref, session, created_at from knowledge.notes where project = '<project>' order by created_at) to stdout csv header" > notes.csv

$Q "insert into knowledge.projects (name) values ('<project>') on conflict do nothing"
$Q "\copy knowledge.sessions from stdin csv header" < sessions.csv
$Q "\copy knowledge.tasks from stdin csv header" < tasks.csv
$Q "\copy knowledge.notes (project, kind, key, text, ref, session, created_at) from stdin csv header" < notes.csv
```

Loading the same notes file twice is refused by the unique key on project, kind, key and
created_at. The model's own tables are not part of this. Dump them separately if a teammate needs
them.

## Backup, restore, uninstall

- Backup: `bin/knowledge-up --dump` writes a `pg_dump` into `$HOME/.knowledge/dumps`. It keeps the
  newest 14 dumps plus the first dump of every month. The session-start hook takes one dump a day
  on its own.
- Restore: `bin/knowledge-up --restore "$HOME/.knowledge/dumps/knowledge-YYYYMMDD-HHMM.dump"`.
- Uninstall: `bin/knowledge-up --down` stops and removes the container. The data volume is kept. To
  delete the data too, remove the volume yourself with `docker volume rm knowledge_data`. That is
  the one command the volume-guard hook blocks inside a session, so run it from a terminal.

## Troubleshooting

- Docker is not running: the session prints one line saying docker is not available and the store
  is skipped, then goes on without it. Start Docker and open a new session.
- The store is still coming up: the very first start runs `initdb`, which takes a few seconds. The
  session says so and uses the store from the next command on.
- `/mcp` shows `knowledge` as failed: the MCP server started before the database was ready. It keeps
  retrying and does not exit, so reconnect from `/mcp`, or open a new session.
- What the background start is doing: its log is `$HOME/.knowledge/init.log`. The container
  creation, the image pulls and any error from them land there.

## Environment

| variable | default | meaning |
|---|---|---|
| `KNOWLEDGE_CONTAINER`, `KNOWLEDGE_VOLUME`, `KNOWLEDGE_NETWORK` | `knowledge`, `knowledge_data`, `knowledge` | the container, the named volume, the private network |
| `KNOWLEDGE_IMAGE`, `KNOWLEDGE_MCP_IMAGE` | `postgres:18`, `crystaldba/postgres-mcp` | the two images |
| `KNOWLEDGE_PORT` | unset | set it to publish the database on `127.0.0.1:$KNOWLEDGE_PORT` |
| `KNOWLEDGE_PROJECT` | the working directory's name | the `project` column of every row |
| `KNOWLEDGE_DUMP_DIR` | `$HOME/.knowledge/dumps` | where the daily `pg_dump` goes |
| `KNOWLEDGE_WAIT_SECS` | `5` in the hooks, `30` in `bin/mcp` | seconds to wait for the store before going on without it |
| `KNOWLEDGE_AUTOUP` | `on` | `off` to manage the store yourself, so the plugin never creates or starts it |

## Development

`db/tests/run.sh` starts a throwaway `postgres:18` container, applies `db/init`, runs every
`db/tests/*.sql` file and every `db/tests/hooks/*.sh` script, then removes the container. It ends
with a `tests: N passed, M failed` line. Pass `--keep` to leave the container running.

```
db/tests/run.sh
```

To look at the bundled `demo` project yourself:

```
docker run -d --name knowledge-try \
  -e POSTGRES_PASSWORD=x -e POSTGRES_DB=knowledge \
  -e KNOWLEDGE_MASTER_PASSWORD=x -e KNOWLEDGE_AGENT_PASSWORD=x \
  -v "$PWD/db/init:/docker-entrypoint-initdb.d:ro" postgres:18
docker exec -i knowledge-try psql -U postgres -d knowledge < db/seed/demo.sql
docker exec -i knowledge-try psql -U agent -d knowledge -c "select kind, key, text, ref from knowledge.current where project = 'demo'"
docker rm -f knowledge-try
```

A SQL test file is a sequence of `do $$ ... end $$` blocks with asserts. Each block has a
`-- break:` comment above it naming what a failing assert means. A hook test runs the shipped
script and reads the result back through `docker exec psql`. See `db/tests/hooks/ensure-up.sh`
for the shape.
