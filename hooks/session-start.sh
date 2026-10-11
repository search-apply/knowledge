#!/usr/bin/env bash
# session-start.sh: SessionStart hook, matchers "startup" and "compact".
# Calls ensure_up first (first run writes the env file and brings the container up in the
# background), then: when the store is up, expires scratch (hook role) and dumps the database
# through bin/knowledge-up --dump when the newest dump is over a day old, printing nothing. When
# the store is still coming up, prints one line and exits 0 (never blocks the session).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$ROOT}"
# shellcheck source=./lib.sh
source "$CLAUDE_PLUGIN_ROOT/hooks/lib.sh"

main() {
  ensure_up || true
  if ! store_up 2>/dev/null; then
    echo "knowledge: store is still coming up; it will be used from the next command on"
    exit 0
  fi
  psql_as hook -c 'select scratch.expire()' >/dev/null
  if [ "$(newest_dump_age_hours)" -gt 24 ]; then
    "$CLAUDE_PLUGIN_ROOT/bin/knowledge-up" --dump >/dev/null 2>&1 || true
  fi
  exit 0
}

main
