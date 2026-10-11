# Security

## Local only

The knowledge store is a Postgres container on your own machine. The plugin has no telemetry and
makes no network calls of its own beyond pulling the `postgres` and Postgres MCP docker images.
Nothing you store is sent anywhere.

## Credentials

Four passwords are generated on the first start and written only to `$HOME/.config/knowledge/env`
(mode 600). They are never written to any config file; the MCP wrapper reads the env file and builds
the connection string at launch. Rotate a password with `alter role <role> password '<new>'` through
`docker exec` as `postgres`, put the same value in the env file, and reconnect the MCP servers.

## What scratch stores

A `PreToolUse` hook stores every Bash command's output that runs over the threshold (default 40
lines) in the local container for seven days, and hands the session a short digest instead. This
includes any secret a command happens to print: it is stored like any other output. It never leaves
your machine, but treat the scratch store as holding whatever your commands printed. Set
`KNOWLEDGE_SCRATCH=off` to disable the wrapper for a session, and dump or drop the store if a secret
was captured.

## Reporting

Report a security issue privately to the maintainer (see the plugin author in
`.claude-plugin/plugin.json`) rather than opening a public issue.
