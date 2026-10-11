-- 04-ds.sql: the ds schema (datasets agents write) -- tables, functions, grants.

-- tables

create table ds.catalog (
  table_name text primary key,
  project text not null,
  summary text not null,
  issue text,
  who text not null default 'master',
  created_at timestamptz not null default clock_timestamp()
);

create sequence ds.result_seq;

-- put ds on every session's search_path, so that an unqualified table name in the ds functions
-- resolves to the ds schema.
alter database knowledge set search_path = public, ds;

-- functions

create or replace function ds.register(project text, table_name text, summary text, issue text default null)
returns void
language plpgsql security invoker as $$
#variable_conflict use_variable
begin
  if to_regclass(format('ds.%I', table_name)) is null then
    raise exception 'ds.register: table ds.% not found', table_name;
  end if;

  insert into ds.catalog (table_name, project, summary, issue, who, created_at)
  values (table_name, project, summary, issue, current_user, clock_timestamp())
  on conflict on constraint catalog_pkey do update
    set project = excluded.project, summary = excluded.summary, issue = excluded.issue,
        who = excluded.who, created_at = excluded.created_at;
end;
$$;

create or replace function ds.list(project text)
returns table (table_name text, rows bigint, summary text, issue text, who text, created_at timestamptz)
language plpgsql stable security invoker as $$
#variable_conflict use_variable
declare
  v_row record;
  v_count bigint;
begin
  for v_row in
    select c.table_name, c.summary, c.issue, c.who, c.created_at
    from ds.catalog c where c.project = list.project order by c.created_at desc
  loop
    execute format('select count(*) from ds.%I', v_row.table_name) into v_count;
    table_name := v_row.table_name;
    rows := v_count;
    summary := v_row.summary;
    issue := v_row.issue;
    who := v_row.who;
    created_at := v_row.created_at;
    return next;
  end loop;
end;
$$;

create or replace function ds.describe(table_name text)
returns text
language plpgsql stable security invoker as $$
#variable_conflict use_variable
declare
  v_cat ds.catalog;
  v_rows bigint;
  v_header text;
  v_cols text;
  v_colline text;
  v_lines text[] := array[]::text[];
  v_sample record;
begin
  select * into v_cat from ds.catalog c where c.table_name = describe.table_name;
  if not found then
    raise exception 'ds.describe: table ds.% not registered', table_name;
  end if;

  execute format('select count(*) from ds.%I', table_name) into v_rows;

  v_lines := v_lines || array[format('ds.%s: %s rows; registered %s by %s; %s',
    table_name, v_rows, to_char(v_cat.created_at, 'YYYY-MM-DD'), v_cat.who,
    split_part(v_cat.summary, E'\n', 1))];

  for v_colline in
    select format('%s %s %s', ic.column_name, ic.data_type,
        case when ic.is_nullable = 'YES' then 'null' else 'not null' end)
    from information_schema.columns ic
    where ic.table_schema = 'ds' and ic.table_name = describe.table_name
    order by ic.ordinal_position
  loop
    v_lines := v_lines || array[v_colline];
  end loop;

  select string_agg(format('%I::text', ic.column_name), ', ' order by ic.ordinal_position)
    into v_cols
    from information_schema.columns ic
    where ic.table_schema = 'ds' and ic.table_name = describe.table_name;

  select string_agg(ic.column_name, '|' order by ic.ordinal_position)
    into v_header
    from information_schema.columns ic
    where ic.table_schema = 'ds' and ic.table_name = describe.table_name;

  v_lines := v_lines || array['--- sample ---', v_header];

  for v_sample in
    execute format('select concat_ws(''|'', %s) as line from ds.%I limit 5', v_cols, table_name)
  loop
    v_lines := v_lines || array[v_sample.line];
  end loop;

  return array_to_string(v_lines, E'\n');
end;
$$;

create or replace function ds.sql(project text, statement text)
returns table (rows_total bigint, result jsonb, saved_table text)
language plpgsql security invoker as $$
#variable_conflict use_variable
declare
  v_cap int;
  v_timeout int;
  v_count bigint;
  v_json jsonb;
  v_table text;
  v_desc text;
begin
  v_cap := coalesce(knowledge.setting(project, 'ds.row_cap'), '50')::int;
  v_timeout := coalesce(knowledge.setting(project, 'ds.sql_timeout_ms'), '5000')::int;

  begin
    set local transaction_read_only = on;
    execute format('set local statement_timeout = %s', v_timeout);
    execute format('select count(*) from (%s) ds_sql_src', statement) into v_count;

    if v_count > v_cap then
      raise exception 'ds.sql: over cap' using errcode = 'P0001';
    end if;

    execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from (select * from (%s) ds_sql_src limit %s) t',
      statement, v_cap) into v_json;

    rows_total := v_count;
    result := v_json;
    saved_table := null;
    return next;
    return;
  exception
    when sqlstate 'P0001' then
      v_table := 'result_' || nextval('ds.result_seq');
      execute format('set local statement_timeout = %s', v_timeout);
      execute format('create table ds.%I as %s', v_table, statement);
      execute format('select count(*) from ds.%I', v_table) into v_count;
      perform ds.register(project, v_table, 'result of: ' || left(statement, 120));
      v_desc := ds.describe(v_table);

      rows_total := v_count;
      result := to_jsonb(v_desc);
      saved_table := v_table;
      return next;
      return;
  end;
end;
$$;

-- stale(project, days): catalogued tables that have not been read in days -- both the last
-- sequential scan and the last index scan are null (never scanned) or older than days.
-- last_seq_scan and last_idx_scan come from pg_stat_all_tables (PostgreSQL 16+); a null is
-- treated as the epoch, so a never-scanned table always counts as stale.
create or replace function ds.stale(project text, days int)
returns table (table_name text, last_seq_scan timestamptz, last_idx_scan timestamptz, summary text)
language sql stable security invoker as $$
  select c.table_name, s.last_seq_scan, s.last_idx_scan, c.summary
  from ds.catalog c
  left join pg_stat_all_tables s
    on s.schemaname = 'ds' and s.relname = c.table_name
  where c.project = stale.project
    and coalesce(s.last_seq_scan, 'epoch'::timestamptz) < now() - make_interval(days => stale.days)
    and coalesce(s.last_idx_scan, 'epoch'::timestamptz) < now() - make_interval(days => stale.days)
  order by c.created_at;
$$;

-- grants: master all on ds.catalog and ds.result_seq; agent all on ds.catalog plus usage on
-- ds.result_seq; execute on every function to master and agent; nothing to hook.
grant all on ds.catalog to master, agent;
grant all on ds.result_seq to master;
grant usage on ds.result_seq to agent;
grant execute on all functions in schema ds to master, agent;
