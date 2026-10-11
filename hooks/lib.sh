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
