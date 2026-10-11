# knowledge

Three stores in one Postgres: `knowledge`, `scratch` and `ds`, reached through SQL functions as
the whole tool surface, in front of any Postgres MCP server, shipped as a Claude Code plugin.

## Development

Run `db/tests/run.sh` to start a throwaway container, apply `db/init`, and run the SQL tests.
