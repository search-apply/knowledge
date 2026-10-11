#!/usr/bin/env bash
# 00-roles.sh: create the login roles master and agent.
# Run by the postgres image's docker-entrypoint-initdb.d with the container env.
set -euo pipefail

for var in KNOWLEDGE_MASTER_PASSWORD KNOWLEDGE_AGENT_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    echo "00-roles.sh: $var is unset" >&2
    exit 1
  fi
done

create_role() {
  local role="$1" password="$2"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
do \$\$
begin
  if not exists (select 1 from pg_roles where rolname = '$role') then
    execute format('create role %I login password %L', '$role', '$password');
  end if;
end
\$\$;
SQL
}

create_role master "$KNOWLEDGE_MASTER_PASSWORD"
create_role agent "$KNOWLEDGE_AGENT_PASSWORD"
