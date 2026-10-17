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

            local task_ref
            task_ref="$(psql_as master <<SQL 2>/dev/null
select coalesce(task_ref, '') from knowledge.handoffs where id = ${h_id}
SQL
            )"

            if [ -n "$task_ref" ]; then
              local task_line
              task_line="$(psql_as master -F $'\t' -v p="$project" -v tref="$task_ref" <<SQL 2>/dev/null
select ref, title, coalesce(url,'-'), coalesce(repo,'-'), coalesce(branch,'-'), coalesce(hop,'-'), coalesce(status,'-')
from knowledge.tasks where project = :'p' and ref = :'tref'
SQL
              )"
              if [ -n "$task_line" ]; then
                local t_ref t_title t_url t_repo t_branch t_hop t_status
                IFS=$'\t' read -r t_ref t_title t_url t_repo t_branch t_hop t_status <<< "$task_line"
                echo "knowledge: task ${t_ref} | ${t_title} | ${t_url} | ${t_repo} ${t_branch} | hop ${t_hop} | ${t_status}"
              fi

              local seen_tables=","
              local reports_rows
              reports_rows="$(psql_as master -F $'\t' -v p="$project" -v tref="$task_ref" <<SQL 2>/dev/null
select slug, left(coalesce(verdict,'-'), 80), coalesce(tables, '{}') from knowledge.reports where project = :'p' and ref = :'tref' order by created_at
SQL
              )"
              if [ -n "$reports_rows" ]; then
                while IFS=$'\t' read -r r_slug r_verdict r_tables; do
                  [ -z "$r_slug" ] && continue
                  local inner tbl_list="" count name name_esc shown=0
                  inner="${r_tables#\{}"
                  inner="${inner%\}}"
                  if [ -n "$inner" ]; then
                    local tbl_arr
                    IFS=',' read -ra tbl_arr <<< "$inner"
                    for name in "${tbl_arr[@]}"; do
                      seen_tables="${seen_tables}${name},"
                      [ "$shown" -ge 10 ] && continue
                      name_esc="${name//\"/\"\"}"
                      count="$(psql_as master <<SQL 2>/dev/null
select count(*) from knowledge."${name_esc}"
SQL
                      )"
                      [ -n "$tbl_list" ] && tbl_list="${tbl_list}, "
                      tbl_list="${tbl_list}${name}(${count:-0})"
                      shown=$((shown + 1))
                    done
                  fi
                  echo "knowledge: report ${r_slug} | ${r_verdict} | tables: ${tbl_list}"
                done <<< "$reports_rows"
              fi

              local data_rows
              data_rows="$(psql_as master -F $'\t' -v p="$project" -v tref="$task_ref" <<SQL 2>/dev/null
select table_name, left(coalesce(what,'-'), 80) from knowledge.datasets where project = :'p' and ref = :'tref' order by created_at
SQL
              )"
              if [ -n "$data_rows" ]; then
                while IFS=$'\t' read -r d_table d_what; do
                  [ -z "$d_table" ] && continue
                  case "$seen_tables" in
                    *",${d_table},"*) ;;
                    *) echo "knowledge: data ${d_table} | ${d_what}" ;;
                  esac
                done <<< "$data_rows"
              fi
            fi

            echo "knowledge: read its notes: select n.id, n.kind, n.key, n.text from knowledge.notes n where n.id = any((select notes from knowledge.handoffs where id = ${h_id})) order by n.id"
          fi
        fi
      fi
    fi
  fi
  exit 0
}

main
