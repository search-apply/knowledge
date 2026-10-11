# Changelog

## 0.1.1 - unreleased

- The session no longer prints a recall block. The model reads the project's rows from `knowledge.current` at the start and tells the user in one sentence what is there. `knowledge.recall` and its settings are removed.
- README rewritten for a first-time reader: what the session says, how the data is stored, how an agent uses it.

## 0.1.0 - 2026-10-11

First public version.

- One Postgres container with three stores: `knowledge` (curated, kept for years), `scratch`
  (automatic command-output overflow, kept for days), and `ds` (datasets agents build).
- SQL functions as the whole tool surface, in front of a generic Postgres MCP server; two MCP
  entries, `knowledge` (read and write) and `knowledge-agent` (read only).
- Zero-action start: the plugin writes its own credentials, brings the container up in the
  background, and pulls the MCP image, so a user only tells their model to use it.
- `bin/knowledge-up` with `--dump` (and daily auto-dump with retention), `--restore`, `--status`,
  `--down` and `--migrate`.
- Ageing without deletion: `knowledge.stale`, `ds.stale`, and a recall nudge when rows go stale.
- Three skills for Claude Code and a paste-in rules block (`docs/agent-rules.md`) for other clients.
- A `PreToolUse` hook stores large Bash output locally and hands back a digest; opt out with
  `KNOWLEDGE_SCRATCH=off`. A volume-guard hook blocks accidental removal of the data volume.
