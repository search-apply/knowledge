#!/usr/bin/env bash
# session-start.sh: SessionStart hook, matchers "startup" and "compact".
# Calls ensure_up first (first run writes the env file and brings the container up in the
# background), then: when the store is up, dumps the database through bin/knowledge-up --dump
# when the newest dump is over a day old, records the project and session (from the hook's stdin
# JSON) and prints one line with the session id and project, then reminds to read the state and
# next notes. When the store is still coming up, prints one line and exits 0 (never blocks the
# session).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$ROOT}"
# shellcheck source=./lib.sh
source "$CLAUDE_PLUGIN_ROOT/hooks/lib.sh"

main() {
  local stdin_json session_id project
  stdin_json="$(cat 2>/dev/null || true)"

  ensure_up || true
  if ! store_up 2>/dev/null; then
    echo "knowledge: store is still coming up; it will be used from the next command on"
    exit 0
  fi
  if [ "$(newest_dump_age_hours)" -gt 24 ]; then
    "$CLAUDE_PLUGIN_ROOT/bin/knowledge-up" --dump >/dev/null 2>&1 || true
  fi

  session_id="$(printf '%s' "$stdin_json" | jq -r '.session_id // empty' 2>/dev/null || true)"
  if [ -n "$session_id" ]; then
    project="$(knowledge_project)"
    if psql_as master -v p="$project" -v s="$session_id" <<SQL >/dev/null 2>&1
insert into knowledge.projects (name) values (:'p') on conflict do nothing;
insert into knowledge.sessions (id, project) values (:'s', :'p') on conflict do nothing;
SQL
    then
      echo "knowledge: session ${session_id}, project ${project}."

      local h_id
      if h_id="$(psql_as master -v p="$project" <<SQL 2>/dev/null
select id from knowledge.handoffs where project = :'p' order by created_at desc limit 1
SQL
      )"; then
        if [ -z "$h_id" ]; then
          echo "knowledge: no handoff yet"
        else
          local h_text
          if h_text="$(psql_as master -v p="$project" <<SQL 2>/dev/null
select text from knowledge.handoffs where project = :'p' order by created_at desc limit 1
SQL
          )"; then
            printf '%s\n' "$h_text"
            echo "knowledge: read its notes: select n.kind, n.key, n.text from knowledge.handoffs h join knowledge.notes n on n.id = any(h.notes) or n.session = h.session where h.id = ${h_id} order by n.created_at"
          fi
        fi
      fi
    fi
  fi
  exit 0
}

main
