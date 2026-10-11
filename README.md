# knowledge

Three stores in one Postgres: `knowledge`, `scratch` and `ds`, reached through SQL functions as
the whole tool surface, in front of any Postgres MCP server, shipped as a Claude Code plugin with
three skills (`skills/knowledge`, `skills/datasets`, `skills/scratch`) that teach an agent to use
them.

## Install

From the marketplace:

```
claude plugin marketplace add search-apply/knowledge
claude plugin install knowledge@knowledge
```

Then export the four passwords (see Environment below) and bring the store up once:

```
export POSTGRES_PASSWORD=... KNOWLEDGE_MASTER_PASSWORD=... KNOWLEDGE_AGENT_PASSWORD=... KNOWLEDGE_HOOK_PASSWORD=...
bin/knowledge-up
```

For development, load the plugin from a local clone instead of the marketplace:

```
claude --plugin-dir /path/to/knowledge
```

## Environment

| variable | default | meaning |
|---|---|---|
| `KNOWLEDGE_CONTAINER`, `KNOWLEDGE_VOLUME`, `KNOWLEDGE_NETWORK` | `knowledge`, `knowledge_data`, `knowledge` | the container, the named volume, the private network |
| `KNOWLEDGE_PORT` | unset | set to publish `127.0.0.1:$KNOWLEDGE_PORT` |
| `KNOWLEDGE_PROJECT` | the working directory's name | the project column of every row |
| `KNOWLEDGE_DUMP_DIR` | `$HOME/.knowledge/dumps` | the daily `pg_dump` folder |
| `KNOWLEDGE_SCRATCH_THRESHOLD`, `KNOWLEDGE_SCRATCH` | `40`, `on` | lines before an output is stored; `off` disables the wrapper |
| `POSTGRES_PASSWORD` and the three `KNOWLEDGE_*_PASSWORD` (master, agent, hook) | required | set at `docker run`; keep them in `$HOME/.config/knowledge/env` |

## Clients

Each MCP client points `DATABASE_URI` at the role it should use. Claude Code and the plugin's own
`.mcp.json` run the docker form; any other client can run the same image directly or use
`uvx postgres-mcp` instead of docker.

Claude Code (`.mcp.json`, shipped with the plugin):

```json
{
  "mcpServers": {
    "knowledge": {
      "command": "docker",
      "args": ["run", "-i", "--rm", "--network", "${KNOWLEDGE_NETWORK:-knowledge}", "-e", "DATABASE_URI", "crystaldba/postgres-mcp", "--access-mode=unrestricted"],
      "env": { "DATABASE_URI": "postgresql://master:${KNOWLEDGE_MASTER_PASSWORD}@${KNOWLEDGE_CONTAINER:-knowledge}:5432/knowledge" }
    }
  }
}
```

Cursor (`.cursor/mcp.json`) and Codex (`~/.codex/config.toml` `[mcp_servers.knowledge]`) take the
same `command`/`args`/`env` shape as the block above, under their own config key.

A plain MCP client, or `uvx` instead of docker:

```
DATABASE_URI=postgresql://agent:$KNOWLEDGE_AGENT_PASSWORD@localhost:5432/knowledge \
  uvx postgres-mcp --access-mode=unrestricted
```

## Backup and restore

```
bin/knowledge-up --dump
bin/knowledge-up --restore "$KNOWLEDGE_DUMP_DIR/knowledge-20261010-0900.dump"
```

The session-start hook runs `--dump` once a day on its own. A project's own JSON export rides
with every handoff:

```
psql_as master -c "select knowledge.export('<project>','json')" > file
```

## Schema changes

0.1.0 ships no migrations. To change the schema by hand: dump first, remove the volume with the
one command the volume-guard hook blocks (so run it deliberately, not by accident), bring the
store back up against the new `db/init`, then restore or import:

```
bin/knowledge-up --dump
docker volume rm knowledge_data
bin/knowledge-up
bin/knowledge-up --restore <dump file>
```

## Emergency

Archive the volume through a throwaway helper container, without touching the running one:

```
docker run --rm -v knowledge_data:/v -v "$PWD":/out alpine tar czf /out/knowledge_data.tgz -C /v .
```

## Development

Docker is the only host dependency. `db/tests/run.sh` starts a throwaway `postgres:18` container
(`knowledge-test-$$`), applies `db/init`, runs every `db/tests/*.sql` file in name order and every
`db/tests/hooks/*.sh` hook script, then removes the container on exit; it ends with a
`tests: N passed, M failed` line. Pass `--keep` to leave the container running for inspection.

```
db/tests/run.sh
db/tests/run.sh --keep
```

A test file is a sequence of `do $$ ... assert ...; end $$;` blocks, one block per assertion group,
each with a `-- break:` comment above it naming what a failing assert means. See `db/tests/01-init.sql`
for the shape. A hook test script feeds the hook its real stdin shape (a PreToolUse or SessionStart
JSON) and reads the result back through `docker exec psql`; see `db/tests/hooks/scratch.sh` and
`db/tests/hooks/install.sh`.
