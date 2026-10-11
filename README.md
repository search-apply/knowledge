# knowledge

A memory store for coding agents, shipped as a Claude Code plugin. One Postgres container holds
three stores -- curated knowledge, automatic command-output overflow, and agent datasets -- reached
through SQL functions as the whole tool surface, in front of a generic Postgres MCP server. The
plugin brings its own container up, so after you install it you only tell your model to use it.
Nothing ever leaves your machine.

Here is what a session sees first -- the recall of the bundled `demo` project:

```
# demo recall 2026-10-11
## state
k#2 release: the next release is in progress
k#1 runs: api and worker containers are up
## decisions (last 30 days)
k#5 ui: front the store with a generic postgres mcp server
k#4 store: add a ds schema for agent datasets
## lessons (last 14 days)
k#6 bash-wrap: a big command output must not sit in context
## pointers
k#7 start: read the brief before touching the schema
## datasets
demo_titles: 7 rows, seven sample title verdicts for the demo project
## open
(none)
```

(reproduce it: load `db/seed/demo.sql` into a container and run
`select knowledge.recall('demo')` -- the exact steps are under Development.)

## Requirements

- Docker running (Docker Desktop on macOS, or the Docker engine on Linux).
- macOS or Linux, with `bash` and `jq` on the PATH.
- Windows is supported only through WSL, and is untested.

That is all. The plugin pulls the Postgres and MCP images itself on first use.

## Quickstart

Install from the marketplace:

```
claude plugin marketplace add search-apply/knowledge
claude plugin install knowledge@knowledge
```

Then open Claude Code in any repository and say:

```
use the knowledge plugin
```

Nothing else. On that first start the plugin, in the background:

- writes `$HOME/.config/knowledge/env` with four random passwords (mode 600);
- creates a private docker network and the `knowledge` container on it, from `postgres:18`, with a
  named volume for its data;
- pulls the Postgres MCP image.

A cold first start takes a few seconds, so the first session prints one line saying the store is
coming up and will be used from the next command on. Every session after that opens with the recall
above, for your project. If Docker is not running the plugin says so once and stays out of the way.

## What gets stored

The curated store has eleven built-in kinds; a project adds its own with `add_kind`.

- `decision` -- a ruling with its why and the options it chose among.
- `fact` -- a verified fact, with when and how it was verified.
- `state` -- a current state value (what is up, what release is in progress).
- `pointer` -- a pointer to a place worth reading.
- `lesson` -- a lesson learned from an incident.
- `finding` -- a finding from one piece of work.
- `section` -- a markdown heading indexed from a repo, so docs are searchable.
- `incident` -- an incident record: date, what, cause, fix.
- `environment` -- a fact about the running environment.
- `recipe` -- a recipe with its steps.
- `term` -- a defined term.

## How it works

Three stores share one Postgres database:

- `knowledge` -- curated, kept for years. Short rows (at most three lines) of the kinds above. A new
  write on the same key supersedes the old one; nothing is deleted. `recall` returns the short brief
  a session opens with; `search`, `get` and `list` read it back.
- `scratch` -- automatic, kept for days. A `PreToolUse` hook wraps every Bash command; when its
  output runs over a threshold (default 40 lines) the output is stored locally and the context gets
  a short digest instead (an id, a line count, a head and a tail). Read it back with
  `scratch.read`/`scratch.grep` rather than re-running the command. Rows expire after seven days.
- `ds` -- datasets an agent builds: plain tables, queried read-only through `ds.sql` with a row cap
  and a timeout, summarised rather than pasted.

Two MCP entries sit in front: `knowledge` (read and write) for the main session, and
`knowledge-agent` (read only) for spawned subagents. Three skills teach an agent to use the stores;
a client that cannot load skills uses `docs/agent-rules.md` instead.

Full disclosure of the hook behaviour, because it is automatic:

- Every Bash command's output, when it runs over the threshold, is kept in your local container for
  seven days. Set `KNOWLEDGE_SCRATCH=off` for a session that must see raw output inline (a live log
  you watch).
- This includes any secret a command happens to print: it is stored like any other output. It never
  leaves your machine, but treat the scratch store as holding whatever your commands printed, and
  dump or rotate accordingly.
- Nothing is ever sent anywhere. The store is a container on your machine; there is no telemetry and
  no network egress from the plugin beyond pulling the two docker images.

## Database access

| role | grants | used by |
|---|---|---|
| `postgres` | superuser; owns the schemas | `knowledge-up` only, for dump, restore and migrate |
| `master` | all on `knowledge` and `ds`, read `scratch` | the main session's MCP entry (`knowledge`) |
| `agent` | read `knowledge` and `scratch`, all on `ds` (including create table) | a subagent's MCP entry (`knowledge-agent`) |
| `hook` | insert on `scratch` only | the Bash hook |

The passwords live only in `$HOME/.config/knowledge/env` (mode 600, generated on the first start,
never written to any config file); the MCP wrapper `bin/mcp` reads them and builds the connection
string at launch. Open psql by hand (no published port needed):
`docker exec -it knowledge psql -U master -d knowledge` -- or, with `KNOWLEDGE_PORT` set, connect to
`postgresql://master:...@localhost:$KNOWLEDGE_PORT/knowledge`. Rotate one password with
`docker exec -it knowledge psql -U postgres -d knowledge -c "alter role master password '<new>'"`,
put the same value in the env file, then reconnect the MCP servers (`/mcp` reconnect). The database
is reachable only on the private docker network unless you set `KNOWLEDGE_PORT`.

## Measured token savings

Measured on one machine; tokens are characters / 4, and the command behind every number is shown.
The store replaces a large paste with a small read.

| case | inline tokens | with-store tokens | saving |
|---|---|---|---|
| orientation (newest handoff + MEMORY.md vs recall) | 6,449 | 125 | 6,324 |
| scratch: `git log` (400 lines) vs its digest | 4,440 | 118 | 4,322 |
| scratch: `find / -name '*.sql'` (352 lines) vs its digest | 11,367 | 320 | 11,047 |
| scratch: `db/tests/run.sh` (13 lines) -- under threshold | 286 | 286 | 0 |
| dataset: 2000 rows pasted vs one `ds.sql` summary | 10,956 | 447 | 10,509 |

Method and commands:

- orientation: `wc -c` of the newest file in the Playbook handoffs folder (4,191 chars) plus
  `wc -c` of `MEMORY.md` (21,607 chars) = 25,798 chars inline, against
  `select knowledge.recall('demo')` on a seeded throwaway (503 chars).
- scratch: each command's real output stored, then its `scratch.digest` read back -- `git log |
  head -400` (17,762 chars) -> digest 473 chars; `find / -name '*.sql' 2>/dev/null | head -2000`
  (45,470 chars, 352 found) -> digest 1,283 chars; `db/tests/run.sh` (1,144 chars, 13 lines) is
  under the 40-line threshold, so it passes through unchanged and nothing is stored. One targeted
  `select * from scratch.grep(<id>, '02-knowledge')` read-back of the find output costs 494 tokens
  (1,976 chars) -- still a fraction of the 11,367 inline.
- dataset: 2000 rows inserted into a `ds` table and read back as text (43,824 chars) against one
  `select ... from ds.sql('demo', 'select company, count(*) from ds.meas group by 1')` (1,790 chars).

## Other clients

Any MCP client can point at the store. Each entry sets `DATABASE_URI` to the role it should use; the
plugin's `.mcp.json` runs `bin/mcp master` and `bin/mcp agent` so the password stays out of config.
For another client, run the image directly:

```
docker run -i --rm --network knowledge \
  -e DATABASE_URI="postgresql://agent:<AGENT_PASSWORD>@knowledge:5432/knowledge" \
  crystaldba/postgres-mcp --access-mode=unrestricted
```

Cursor (`.cursor/mcp.json`) and Codex (`~/.codex/config.toml`, `[mcp_servers.knowledge]`) take that
same `command`/`args`/`env` shape under their own config key. A client with no host network reaches
the container through a published port: set `KNOWLEDGE_PORT` and use
`postgresql://agent:<AGENT_PASSWORD>@localhost:$KNOWLEDGE_PORT/knowledge`.

A client that cannot load the plugin's skills should be given the rules block in
`docs/agent-rules.md`; it carries the same guidance the skills do.

Subagents, from this plugin or another: give a spawned agent only the read-only `knowledge-agent`
entry, never the writable one. Its tools appear under the plugin prefix
`mcp__plugin_knowledge_knowledge-agent__*`; the writable `knowledge` server is
`mcp__plugin_knowledge_knowledge__*`. Allow a subagent only the former, so only the main session
writes.

## Team use

The store is per machine; share knowledge by exporting and importing a project:

```
docker exec -i knowledge psql -U master -d knowledge -qAt \
  -c "select knowledge.export('<project>', 'json')" > knowledge-<project>.json
```

Commit that file. On the other machine, import it:

```
docker exec -i knowledge psql -U master -d knowledge \
  -c "select knowledge.import('<project>', pg_read_file('/path/to/knowledge-<project>.json')::jsonb)"
```

Import replays each row in order, so a later export of the same project is a clean round-trip.

## Backup, restore, upgrade, uninstall

- Backup: `bin/knowledge-up --dump` writes a `pg_dump` into `$HOME/.knowledge/dumps` and keeps the
  newest 14 plus the first dump of every month. The session-start hook dumps once a day on its own.
- Restore: `bin/knowledge-up --restore "$HOME/.knowledge/dumps/knowledge-YYYYMMDD-HHMM.dump"`.
- Status: `bin/knowledge-up --status` prints up/down, volume size, rows per kind, scratch rows, ds
  tables and the newest dump age.
- Upgrade: pull the new plugin, then `bin/knowledge-up --migrate` applies any new schema migrations
  (see `db/migrations/README.md`). 0.1.0 ships none.
- Uninstall: stop and remove the container with `bin/knowledge-up --down` (the data volume is kept).
  To delete the data too, remove the volume deliberately -- this is the one command the volume-guard
  hook blocks, so run it yourself: `docker volume rm knowledge_data`.

## Troubleshooting

- Docker is not running: the session prints `docker is not available; the store is skipped this
  session` and continues without the store. Start Docker and open a new session.
- Store still coming up: a first-ever start runs `initdb`, which takes a few seconds; the session
  says so and uses the store from the next command on. Run `bin/knowledge-up --status` to watch it.
- `/mcp` shows `knowledge` failed: the MCP server was started before the database finished coming
  up. It keeps retrying the connection (it does not exit), so reconnect from `/mcp`, or open a new
  session, once `--status` reports `up`.
- What the background start is doing: its log is `$HOME/.knowledge/init.log` -- the container
  creation, the image pulls, and any error from them land there.

## Environment

| variable | default | meaning |
|---|---|---|
| `KNOWLEDGE_CONTAINER`, `KNOWLEDGE_VOLUME`, `KNOWLEDGE_NETWORK` | `knowledge`, `knowledge_data`, `knowledge` | the container, named volume, private network |
| `KNOWLEDGE_IMAGE`, `KNOWLEDGE_MCP_IMAGE` | `postgres:18`, `crystaldba/postgres-mcp` | the two images |
| `KNOWLEDGE_PORT` | unset | set to publish `127.0.0.1:$KNOWLEDGE_PORT` |
| `KNOWLEDGE_PROJECT` | the working directory's name | the `project` column of every row |
| `KNOWLEDGE_DUMP_DIR` | `$HOME/.knowledge/dumps` | the daily `pg_dump` folder |
| `KNOWLEDGE_SCRATCH_THRESHOLD`, `KNOWLEDGE_SCRATCH` | `40`, `on` | lines before an output is stored; `off` disables the wrapper |
| `KNOWLEDGE_AUTOUP` | `on` | `off` to manage the store yourself (the plugin will not create or start it) |

## Development

`db/tests/run.sh` starts a throwaway `postgres:18` container (`knowledge-test-$$`), applies
`db/init`, runs every `db/tests/*.sql` file and every `db/tests/hooks/*.sh` hook, then removes the
container on exit; it ends with a `tests: N passed, M failed` line. Pass `--keep` to leave it
running.

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

`bin/index-headings <project> <path>...` indexes a repo's markdown headings into `knowledge`
section rows; see `skills/knowledge/SKILL.md`. A test file is a sequence of
`do $$ ... assert ...; end $$;` blocks, each with a `-- break:` comment naming what a failing assert
means; a hook test feeds the hook its real stdin and reads the result back through `docker exec
psql`. See `db/tests/hooks/scratch.sh` and `db/tests/hooks/ensure-up.sh`.
