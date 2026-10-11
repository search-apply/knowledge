---
name: scratch
description: Large command outputs live in scratch: read the digest, then scratch.read by range or scratch.grep by pattern; never re-run a command to see its output again.
user-invocable: false
---

# Scratch (automatic output overflow)

A PreToolUse hook wraps every Bash command. A large output is stored and replaced in context by a digest; read it back instead of re-running the command. Reach the functions through the MCP `execute_sql` tool.

## What happens
- Over the threshold (`KNOWLEDGE_SCRATCH_THRESHOLD`, default 40 lines) the output is stored and the context gets a digest.
- The digest is one id line plus a head and a tail: `scratch#<id>: <n> lines, stored <date>; read: select * from scratch.read(<id>, 1, 200)`.
- Under the threshold, or when the store is down, the output passes through unchanged and the exit code is kept.

## Reading back
- By line range: `select * from scratch.read(12, 1, 200);` (the range is capped at `scratch.read_cap`, default 200).
- By pattern: `select * from scratch.grep(12, 'ERROR');`
- Just the ends: `select * from scratch.head(12);` and `select * from scratch.tail(12);`
- Rows expire after `scratch.retention_days` (default 7); read it while it lasts, never re-run the command.

## Turning it off
- Set `KNOWLEDGE_SCRATCH=off` for a session that must see raw output inline (a live log you watch); leave it on otherwise.

## Not stored
- Output under the threshold, and anything while the store is unreachable: the wrapper fails open.
