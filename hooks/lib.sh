#!/usr/bin/env bash
# lib.sh: shared helpers, sourced by every hook script. Not executable on its own.

knowledge_container() { printf '%s' "${KNOWLEDGE_CONTAINER:-knowledge}"; }
knowledge_project() { printf '%s' "${KNOWLEDGE_PROJECT:-$(basename "$PWD")}"; }

# store_up: 0 when the container answers pg_isready within 2 s, 1 otherwise.
store_up() {
  docker exec "$(knowledge_container)" pg_isready -q -U postgres -d knowledge -t 2
}

# psql_as <role> [args...]: runs psql as <role> against the knowledge database in the container.
psql_as() {
  local role="$1"
  shift
  docker exec -i "$(knowledge_container)" psql -U "$role" -d knowledge -v ON_ERROR_STOP=1 -qAt "$@"
}

# newest_dump_age_hours: prints the age in whole hours of the newest *.dump file in
# KNOWLEDGE_DUMP_DIR (default $HOME/.knowledge/dumps), or 999 when the dir is missing or empty.
newest_dump_age_hours() {
  local dir="${KNOWLEDGE_DUMP_DIR:-$HOME/.knowledge/dumps}" newest=0 mtime now
  if [ -d "$dir" ]; then
    shopt -s nullglob
    for f in "$dir"/*.dump; do
      mtime=$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || echo 0)
      [ "$mtime" -gt "$newest" ] && newest="$mtime"
    done
    shopt -u nullglob
  fi
  if [ "$newest" -eq 0 ]; then
    printf '999'
    return 0
  fi
  now=$(date +%s)
  printf '%d' $(( (now - newest) / 3600 ))
}
