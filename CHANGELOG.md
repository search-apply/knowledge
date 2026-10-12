# Changelog

## 0.3.0 - unreleased

- The default tables are now six plain tables in one schema: `projects`, `sessions`, `tasks`, `notes`, `kinds`, `datasets`, plus the view `current`. Notes are append-only and point at a task (`ref`) and at the session that wrote them. Everything a session keeps goes here: decisions, lessons, state, next steps, session summaries.
- The session-start hook records the project and the session and gives the model one line with the session id and the project name, at start and after a compaction. The model reads the `state` and `next` notes and goes on. No handoff file.
- The model's own tables live in the `knowledge` schema too, each registered with one `datasets` row. The `ds` schema is gone.
- Removed: `knowledge.rows` with its `fields`, `tags`, `commit`, `source`, `who`, `issue` and `superseded_by` columns, `knowledge.put`, `knowledge.search`, the `finding` and `environment` kinds. Added kinds: `next`, `summary`.
- Both skills rewritten around the tables, the flow of a session and the queries.
- A `handoffs` table: one row per boundary, one screen of text with the ids of the notes behind it. The session-start hook prints the newest handoff for the project at start and after a compaction, so there is no handoff file.
- `bin/mcp` names and labels the container it starts with the owning session's pid, and reaps any labelled container whose owner pid is gone before starting its own, so a sidecar orphaned by a killed client does not outlive its session.

## 0.2.0 - unreleased

- The plugin is now a Postgres MCP server plus two skills. The default tables (`knowledge.rows`, `knowledge.kinds`, the view `knowledge.current`), one write function (`knowledge.put`) and one search function stay. The `ds` schema is free for the model's own tables, with a shape described in the `data` skill.
- Removed: the scratch store (wrapper hook, functions, table), the ds functions and catalog, the read wrappers (`get`, `list`, `about`, `stale`, `link`), the links and config tables, `export` and `import` (team sharing is two `\copy` lines in the README), the headings indexer and the `section` kind, `knowledge-up --migrate` and `--status`, `docs/agent-rules.md`, the hook database role.
- The session no longer prints a recall block. The model reads `knowledge.current` at the start and tells the user in one sentence what is there.
- README rewritten for a first-time reader.

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
