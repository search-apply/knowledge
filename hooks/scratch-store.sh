#!/usr/bin/env bash
# scratch-store.sh <file> <rc> <command>: at or under KNOWLEDGE_SCRATCH_THRESHOLD lines, prints
# <file> unchanged. Over it and the store reachable, writes one CSV record (project, session from
# KNOWLEDGE_SESSION, command truncated to 500 characters, body) through psql_as hook's \copy and
# prints the digest from the same psql session. On any failure (store down, insert error) prints
# <file> unchanged. Always exits with <rc>; always removes <file>.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$ROOT}"
# shellcheck source=./lib.sh
source "$CLAUDE_PLUGIN_ROOT/hooks/lib.sh"

file="$1"
rc="$2"
command="$3"

cleanup() { rm -f "$file"; }
trap cleanup EXIT

threshold="${KNOWLEDGE_SCRATCH_THRESHOLD:-40}"
lines=$(wc -l < "$file" | tr -d ' ')

print_unchanged() { cat "$file"; }

csv_field() {
  local v="$1"
  v="${v//\"/\"\"}"
  printf '"%s"' "$v"
}

store_and_digest() {
  local project session cmd_trunc body csv digest
  project="$(knowledge_project)"
  session="${KNOWLEDGE_SESSION:-}"
  cmd_trunc="${command:0:500}"
  body="$(cat "$file")"

  csv="$(csv_field "$project"),$(csv_field "$session"),$(csv_field "$cmd_trunc"),$(csv_field "$body")"

  digest="$(printf '%s\n' "$csv" | psql_as hook \
    -c '\copy scratch.outputs (project, session, command, body) from stdin csv' \
    -c 'select scratch.digest(lastval())' 2>/dev/null)"

  [ -n "$digest" ] || return 1
  printf '%s\n' "$digest"
}

if [ "$lines" -le "$threshold" ]; then
  print_unchanged
elif store_up && store_and_digest; then
  :
else
  print_unchanged
fi

exit "$rc"
