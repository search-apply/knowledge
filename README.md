# knowledge

Three stores in one Postgres: `knowledge`, `scratch` and `ds`, reached through SQL functions as
the whole tool surface, in front of any Postgres MCP server, shipped as a Claude Code plugin.

## Run the tests

Docker is the only host dependency. `db/tests/run.sh` starts a throwaway `postgres:18` container
(`knowledge-test-$$`), applies `db/init`, runs every `db/tests/*.sql` file in name order, and removes
the container on exit; it ends with a `tests: N passed, M failed` line. Pass `--keep` to leave the
container running for inspection.

```
db/tests/run.sh
db/tests/run.sh --keep
```

A test file is a sequence of `do $$ ... assert ...; end $$;` blocks, one block per assertion group,
each with a `-- break:` comment above it naming what a failing assert means. See `db/tests/01-init.sql`
for the shape.

## Bring the store up by hand

Run `postgres:18` with `db/init` mounted read-only and the database and the four passwords passed from
your environment (no published port by default):

```
docker run -d --name knowledge \
  -e POSTGRES_DB=knowledge \
  -e POSTGRES_PASSWORD \
  -e KNOWLEDGE_MASTER_PASSWORD \
  -e KNOWLEDGE_AGENT_PASSWORD \
  -e KNOWLEDGE_HOOK_PASSWORD \
  -v "$PWD/db/init":/docker-entrypoint-initdb.d:ro \
  postgres:18
```

The init files run in name order: `00-roles.sh` creates the login roles `master`, `agent` and `hook`
from the three `KNOWLEDGE_*_PASSWORD` variables, then `01-schemas.sql` creates the schemas `knowledge`,
`scratch` and `ds` with their grants.
