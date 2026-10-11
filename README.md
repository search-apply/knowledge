# knowledge

A memory for coding agents: one Postgres container on your machine, a standard Postgres MCP
server in front of it, and two short skills that teach the model how to store what it learns and
how to query it back. Shipped as a Claude Code plugin. The plugin starts its own container, so
after installing it you only tell your model to use it. Nothing leaves your machine.

## What a session says at start

When a session starts, the plugin makes sure the store is up. The model then looks at what is
stored for the project and tells you in one sentence. On a new project:

```
The knowledge store is up. I will keep structured notes here on what we work on.
```

Later, with notes stored:

```
The knowledge store is up, with 14 notes on this project. The latest: the subscription ends at
Stripe's cancel_at, never at the webhook time.
```

Nothing is printed by the plugin itself. The model reads the store and speaks.

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

Two schemas. `knowledge` holds the default tables, created once when the container is made.
`ds` is empty and belongs to the model, for any table it wants to create while working.

### The default tables

`knowledge.rows` holds the memory, one row per item. Writing the same project, kind and key again
adds a new row and marks the old one as superseded, so history stays and the view
`knowledge.current` shows the latest. The text is at most three lines. The fields column carries
what the kind requires. Rows of the bundled `demo` project:

| id | kind | key | text | fields | superseded_by |
|---|---|---|---|---|---|
| 1 | state | runs | api and worker containers are up | {"value": "up"} | |
| 3 | decision | store | keep one postgres with three schemas | {"why": "fewer moving parts", "options": "one postgres, sqlite plus files", "who_ruled": "master"} | 4 |
| 4 | decision | store | add a ds schema for agent datasets | {"why": "agents need real tables, not files", "options": "a ds schema, flat files", "who_ruled": "master"} | |
| 6 | lesson | bash-wrap | a big command output must not sit in context | {"incident": "a session held a huge log in context and stalled", "rule": "store the output, hand back a digest"} | |
| 7 | pointer | start | read the brief before touching the schema | {"path": "docs/brief.md", "what": "what we build and why"} | |

The other columns are `project`, `issue` and `commit` (where the row came from), `source`, `who`,
`tags` and `created_at`.

`knowledge.kinds` is the vocabulary: a name, a description and the fields a row of that kind must
carry. Ten kinds are built in. One insert adds another.

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

One function, `knowledge.put`, writes a row: it checks the kind's fields, inserts the row and marks
the previous row of that key as superseded. One function, `knowledge.search`, finds rows by words.
Everything else is a plain query, and the skill carries the ones that matter.

### The queries the model uses

- At session start: `select kind, key, text, created_at from knowledge.current where project = '<project>' order by created_at desc limit 30`
- When something is decided or learned: `select knowledge.put('<project>', 'decision', 'billing-cancel', 'the subscription ends at cancel_at', '{"why": "...", "options": "...", "who_ruled": "operator"}', issue => '#12')`
- By words: `select * from knowledge.search('<project>', 'webhook cancel')`
- By kind or by issue: `select key, text from knowledge.current where project = '<project>' and kind = 'decision'`,
  `... and issue = '#12'`
- The history of a key: `select text, created_at from knowledge.rows where project = '<project>' and key = 'billing-cancel' order by created_at`

### The model's own tables

The `ds` schema is where the model keeps rows of data a piece of work produces, like research
results or measurements, instead of pasting them into the context. There are no fixed scripts for
it, only a shape, so the tables line up and the next session can find them:

- the name is `ds.<project>_<topic>`
- every table has a `created_at` column and a `comment on table` saying what it holds and where it
  came from
- every read has a `limit`, and a reply carries table names and counts, never the rows
- the map of what exists is one query over `pg_class` and `obj_description`, in the `data` skill

The `agent` role has a five-second statement timeout, so a runaway query from a subagent stops.

## How it works

- One container, `postgres:18`, on a private docker network, with a named volume for the data.
- Two MCP entries: `knowledge` (read and write) for the main session, and `knowledge-agent` (read
  only on `knowledge`, read and write on `ds`) for spawned subagents. Both run the standard
  `crystaldba/postgres-mcp` image. The model talks to the database with its `execute_sql` tool.
- Two skills: `knowledge` (the default tables, when to store what, the queries) and `data` (the
  shape of the model's own tables).
- Two hooks: at session start the store is brought up and a dump is taken once a day. Before any
  Bash command, a guard refuses the docker commands that would remove the volume.
- Nothing is sent anywhere. There is no telemetry and no network traffic from the plugin beyond
  pulling the two docker images.

## Database access

| role | grants | used by |
|---|---|---|
| `postgres` | superuser, owns the schemas | `knowledge-up` only, for dump and restore |
| `master` | all on `knowledge` and `ds` | the main session's MCP entry (`knowledge`) |
| `agent` | read `knowledge`, all on `ds`, five-second statement timeout | a subagent's MCP entry (`knowledge-agent`) |

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
are in `skills/knowledge/SKILL.md` and `skills/data/SKILL.md`.

Subagents, from this plugin or any other, should get only the `knowledge-agent` entry, never the
writable one. Its tools appear under the prefix `mcp__plugin_knowledge_knowledge-agent__`. The
writable `knowledge` server's tools appear under `mcp__plugin_knowledge_knowledge__`. Allow a
subagent only the first, so that only the main session writes memory.

## Team use

The store is per machine. To share a project's memory, export its current rows to a file, commit
the file, and load it on the other machine:

```
docker exec -i knowledge psql -U master -d knowledge -c "\copy (select project, kind, key, text, fields, issue, commit, source, who, tags, created_at from knowledge.current where project = '<project>' order by created_at) to stdout csv header" > knowledge-<project>.csv

docker exec -i knowledge psql -U master -d knowledge -c "\copy knowledge.rows (project, kind, key, text, fields, issue, commit, source, who, tags, created_at) from stdin csv header" < knowledge-<project>.csv
```

Loading the same file twice is refused by the unique key on project, kind, key and created_at.

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
docker exec -i knowledge-try psql -U agent -d knowledge -c "select kind, key, text from knowledge.current where project = 'demo'"
docker rm -f knowledge-try
```

A SQL test file is a sequence of `do $$ ... end $$` blocks with asserts. Each block has a
`-- break:` comment above it naming what a failing assert means. A hook test runs the shipped
script and reads the result back through `docker exec psql`. See `db/tests/hooks/ensure-up.sh`
for the shape.
