#!/usr/bin/env bash
# session-start.sh: SessionStart hook, matcher "startup".
# When the store is up: prints the project's recall text (agent role) so it enters the
# session's context, expires scratch (hook role), and dumps the database through
# bin/knowledge-up --dump when the newest dump is over a day old.
# When the store is down: prints one notice line and exits 0 (never blocks the session).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$ROOT}"
# shellcheck source=./lib.sh
source "$CLAUDE_PLUGIN_ROOT/hooks/lib.sh"

main() {
  if ! store_up; then
    echo "knowledge: store $(knowledge_container) not reachable"
    exit 0
  fi
  psql_as agent -c "select knowledge.recall('$(knowledge_project)')"
  psql_as hook -c 'select scratch.expire()' >/dev/null
  if [ "$(newest_dump_age_hours)" -gt 24 ]; then
    "$CLAUDE_PLUGIN_ROOT/bin/knowledge-up" --dump >/dev/null 2>&1 || true
  fi
  exit 0
}

main
