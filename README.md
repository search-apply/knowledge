# knowledge

A memory store for coding agents, shipped as a Claude Code plugin. One Postgres container on your
machine holds three things: the knowledge your agent should keep, the long command outputs that
would otherwise flood its context, and the data tables it builds while working. The agent reaches
all of it through plain SQL functions, behind a standard Postgres MCP server. The plugin starts its
own container, so after installing it you only tell your model to use it. Nothing leaves your
machine.

## What a session sees at start

When a session starts, and again after a compaction, the plugin prints the project's memory. This
is the bundled `demo` project. Your own project starts empty and fills up as you work:

```
demo, recall of 2026-10-11

State
- release: the next release is in progress
- runs: api and worker containers are up

Decisions of the last 30 days
- ui: front the store with a generic postgres mcp server
- store: add a ds schema for agent datasets

Lessons of the last 14 days
- bash-wrap: a big command output must not sit in context

Pointers
- start: read the brief before touching the schema

Datasets
- demo_titles: 7 rows, seven sample title verdicts for the demo project

Open
- none
```

Each line is one stored row: its key, then its text. Old decisions and lessons drop out of this
view after a while, but they stay in the store and remain searchable.

## Requirements

- Docker, running. Docker Desktop on macOS, or the Docker engine on Linux.
- macOS or Linux, with `bash` and `jq` on the PATH. Without `jq` the command-output wrapper stays
  off and everything else works.
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

- writes `$HOME/.config/knowledge/env` with four random passwords, readable only by you
- creates a private docker network and the `knowledge` container on it, from `postgres:18`, with a
  named volume for the data
- pulls the Postgres MCP image

The first start takes a few seconds. That first session prints one line saying the store is coming
up and will be used from the next command on. Every session after that opens with the recall shown
above, for your project. If Docker is not running, the plugin says so once and stays out of the
way.

Telling the model

```
use the knowledge plugin
```

starts nothing. It only tells the model to lean on the store that is already there.

## What gets stored

The store has eleven built-in kinds of row. A project can add its own with `add_kind`.

- `decision`, a ruling with its why and the options it chose among
- `fact`, a verified fact, with when and how it was verified
- `state`, a current value, like what is running or which release is in progress
- `pointer`, a place worth reading
- `lesson`, a lesson learned from an incident
- `finding`, a finding from one piece of work
- `section`, a markdown heading indexed from a repo, so docs become searchable
- `incident`, an incident record with date, what happened, cause and fix
- `environment`, a fact about the running environment
- `recipe`, a recipe with its steps
- `term`, a defined term

### How the data is stored

Three tables carry everything. Agents touch them only through the SQL functions.

`knowledge.rows` holds the curated memory, one row per item. Writing the same project, kind and key
again adds a new row and marks the old one as superseded, so history stays and the view
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
carry. The eleven built-in kinds are listed above. `add_kind('convention', 'a house convention',
'["rule"]')` adds one.

| name | fields |
|---|---|
| decision | why, options, who_ruled |
| lesson | incident, rule |
| state | value |
| pointer | path, what |
| fact | verified_on, how |

`scratch.outputs` holds command output that was too long for the context. The hook stores the
whole output, hands the agent a five-line digest, and the agent reads the rest with `scratch.read`
or `scratch.grep`. Rows expire after seven days.

| id | session | command | lines | expires_at |
|---|---|---|---|---|
| 12 | 7f3a... | docker logs api | 4812 | 2026-10-18 |

`ds.catalog` is the index of the agent's data tables. The data itself is a plain table in the `ds`
schema, one per dataset, registered here so that `recall` and `ds.list` show it.

| table_name | project | summary | who |
|---|---|---|---|
| demo_titles | demo | seven sample title verdicts for the demo project | master |

`knowledge.config` holds the few settings: the recall windows, how long scratch rows live, the
digest size, the row cap and timeout for dataset queries. Each has a `*` default and can be set per
project.

### How an agent uses them

- At session start the hook prints `knowledge.recall('<project>')`, the block at the top of this
  file.
- Before working on an issue: `select * from knowledge.about('<project>', '#12')` returns every row
  linked to that issue and its parents. `knowledge.search('<project>', 'webhook cancel')` searches
  by words.
- When something is decided or learned: `select knowledge.put('<project>', 'decision',
  'billing-cancel', 'the subscription ends at cancel_at', '{"why": "...", "options": "...",
  "who_ruled": "operator"}', issue => '#12')`. The same key again supersedes the old row.
- A long command output: the hook stores it and hands back a five-line digest with its id.
  `select scratch.read(<id>)` or `scratch.grep(<id>, 'error')` reads the rest. The command is never
  run again just to see its output.
- Rows of data from research: `create table ds.titles as ...`, then
  `ds.register('<project>', 'titles', 'what it holds')`. Others query it with
  `ds.sql('<project>', 'select ... from ds.titles')`, which is read-only, capped and has a timeout.
- `bin/index-headings <project> docs/*.md` turns a repo's markdown headings into `section` rows, so
  the agent can search the docs.

## How it works

Three stores share one Postgres database.

- `knowledge` is curated and kept for years. Short rows of the kinds above, at most three lines
  each. A new write on the same key supersedes the old one. Nothing is deleted. `recall` returns
  the short text a session opens with. `search`, `get` and `list` read rows back.
- `scratch` is automatic and kept for days. A hook wraps every Bash command. When the output runs
  over a threshold (40 lines by default) the output is stored and the context gets a short digest
  instead: an id, a line count, the first and the last lines. The agent reads it back with
  `scratch.read` or `scratch.grep` rather than running the command again. Rows expire after seven
  days.
- `ds` holds datasets an agent builds: plain tables, queried read-only through `ds.sql` with a row
  cap and a timeout, and summarised rather than pasted.

Two MCP entries sit in front: `knowledge` (read and write) for the main session, and
`knowledge-agent` (read only) for spawned subagents. Three skills teach an agent to use the stores.
A client that cannot load skills gets the same guidance from `docs/agent-rules.md`.

Because the hook is automatic, here is exactly what it does:

- Every Bash command's output, when it runs over the threshold, is kept in your local container for
  seven days. Set `KNOWLEDGE_SCRATCH=off` for a session that must see raw output inline, like a
  live log you are watching.
- That includes any secret a command happens to print. It is stored like any other output. It never
  leaves your machine, but treat the scratch store as holding whatever your commands printed.
- Nothing is sent anywhere. The store is a container on your machine. There is no telemetry and no
  network traffic from the plugin beyond pulling the two docker images.

## Database access

| role | grants | used by |
|---|---|---|
| `postgres` | superuser, owns the schemas | `knowledge-up` only, for dump, restore and migrate |
| `master` | all on `knowledge` and `ds`, read `scratch` | the main session's MCP entry (`knowledge`) |
| `agent` | read `knowledge` and `scratch`, all on `ds` (including create table) | a subagent's MCP entry (`knowledge-agent`) |
| `hook` | insert on `scratch` only | the Bash hook |

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

## Measured token savings

Measured on one machine. Tokens are characters divided by 4. The command behind every number is
listed below. The store replaces a large paste with a small read.

| case | inline tokens | with the store | saving |
|---|---|---|---|
| orientation at session start (newest handoff plus MEMORY.md, against the recall) | 6,449 | 125 | 6,324 |
| `git log`, 400 lines, against its digest | 4,440 | 118 | 4,322 |
| `find / -name '*.sql'`, 352 lines, against its digest | 11,367 | 320 | 11,047 |
| `db/tests/run.sh`, 13 lines, under the threshold | 286 | 286 | 0 |
| 2000 data rows pasted, against one `ds.sql` summary | 10,956 | 447 | 10,509 |

The 125 for orientation is the recall of the small twelve-row `demo` project. A real project's
recall is capped at ten rows per section and will run to a few hundred tokens. Read 125 as the
shape of the saving, not a fixed promise.

How each number was taken:

- Orientation: `wc -c` of the newest file in the Playbook handoffs folder (4,191 characters) plus
  `wc -c` of `MEMORY.md` (21,607 characters) gives 25,798 characters inline. Against that,
  `select knowledge.recall('demo')` on a seeded throwaway container gives 503 characters.
- Scratch: each command's real output was stored and its digest read back. `git log | head -400`
  is 17,762 characters, its digest 473. `find / -name '*.sql' 2>/dev/null | head -2000` is 45,470
  characters (352 files found), its digest 1,283. `db/tests/run.sh` prints 1,144 characters in 13
  lines, under the 40-line threshold, so it passes through unchanged and nothing is stored. One
  targeted read-back of the find output, `select * from scratch.grep(<id>, '02-knowledge')`, costs
  494 tokens (1,976 characters), still a fraction of the 11,367 inline.
- Dataset: 2000 rows inserted into a `ds` table and read back as text are 43,824 characters.
  One `select ... from ds.sql('demo', 'select company, count(*) from ds.meas group by 1')` is
  1,790 characters.

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

A client that cannot load the plugin's skills should be given the rules in `docs/agent-rules.md`.
They say the same things the skills do.

Subagents, from this plugin or any other, should get only the read-only `knowledge-agent` entry,
never the writable one. Its tools appear under the prefix `mcp__plugin_knowledge_knowledge-agent__`.
The writable `knowledge` server's tools appear under `mcp__plugin_knowledge_knowledge__`. Allow a
subagent only the first, so that only the main session writes.

## Team use

The store is per machine. To share knowledge, export a project and import it on the other machine.

Export:

```
docker exec -i knowledge psql -U master -d knowledge -qAt \
  -c "select knowledge.export('<project>', 'json')" > knowledge-<project>.json
```

Commit that file. On the other machine, import it as `master`. The file is read on the host and
passed in as a psql variable, so no superuser and no server-side file access is needed:

```
docker exec -i knowledge psql -U master -d knowledge -v doc="$(cat knowledge-<project>.json)" <<'SQL'
select knowledge.import('<project>', :'doc'::jsonb);
SQL
```

The statement has to come in on stdin, as above, because psql expands `:'doc'` only there and not
with `-c`. Import replays each row in order, so exporting the same project again gives the same
file.

## Backup, restore, upgrade, uninstall

- Backup: `bin/knowledge-up --dump` writes a `pg_dump` into `$HOME/.knowledge/dumps`. It keeps the
  newest 14 dumps plus the first dump of every month. The session-start hook takes one dump a day
  on its own.
- Restore: `bin/knowledge-up --restore "$HOME/.knowledge/dumps/knowledge-YYYYMMDD-HHMM.dump"`.
- Status: `bin/knowledge-up --status` prints whether the store is up, the volume size, the rows per
  kind, the scratch rows, the ds tables and the age of the newest dump.
- Upgrade: pull the new plugin, then run `bin/knowledge-up --migrate` to apply any new schema
  migrations (see `db/migrations/README.md`). Version 0.1.0 ships none.
- Uninstall: `bin/knowledge-up --down` stops and removes the container. The data volume is kept. To
  delete the data too, remove the volume yourself with `docker volume rm knowledge_data`. That is
  the one command the volume-guard hook blocks inside a session, so run it from a terminal.

## Troubleshooting

- Docker is not running: the session prints one line saying docker is not available and the store
  is skipped, then goes on without it. Start Docker and open a new session.
- The store is still coming up: the very first start runs `initdb`, which takes a few seconds. The
  session says so and uses the store from the next command on. `bin/knowledge-up --status` shows
  the progress.
- `/mcp` shows `knowledge` as failed: the MCP server started before the database was ready. It keeps
  retrying and does not exit, so reconnect from `/mcp`, or open a new session, once `--status`
  reports up.
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
| `KNOWLEDGE_SCRATCH_THRESHOLD`, `KNOWLEDGE_SCRATCH` | `40`, `on` | lines of output before it is stored, and `off` to disable the wrapper |
| `KNOWLEDGE_WAIT_SECS` | `5` in the hooks, `30` in `bin/mcp` | seconds to wait for the store before giving up and going on without it |
| `KNOWLEDGE_AUTOUP` | `on` | `off` to manage the store yourself, so the plugin never creates or starts it |

## Development

`db/tests/run.sh` starts a throwaway `postgres:18` container, applies `db/init`, runs every
`db/tests/*.sql` file and every `db/tests/hooks/*.sh` script, then removes the container. It ends
with a `tests: N passed, M failed` line. Pass `--keep` to leave the container running.

```
db/tests/run.sh
```

To see the recall at the top of this file for yourself:

```
docker run -d --name knowledge-try \
  -e POSTGRES_PASSWORD=x -e POSTGRES_DB=knowledge \
  -e KNOWLEDGE_MASTER_PASSWORD=x -e KNOWLEDGE_AGENT_PASSWORD=x -e KNOWLEDGE_HOOK_PASSWORD=x \
  -v "$PWD/db/init:/docker-entrypoint-initdb.d:ro" postgres:18
docker exec -i knowledge-try psql -U postgres -d knowledge < db/seed/demo.sql
docker exec -i knowledge-try psql -U agent -d knowledge -qAt -c "select knowledge.recall('demo')"
docker rm -f knowledge-try
```

A SQL test file is a sequence of `do $$ ... end $$` blocks with asserts. Each block has a
`-- break:` comment above it naming what a failing assert means. A hook test feeds the hook its
real input and reads the result back through `docker exec psql`. See `db/tests/hooks/scratch.sh`
and `db/tests/hooks/ensure-up.sh` for the shape.
