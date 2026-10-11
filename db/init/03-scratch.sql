-- 03-scratch.sql: the scratch schema (automatic, kept for days) -- table, trigger, functions, grants.

-- table

create table scratch.outputs (
  id bigint generated always as identity primary key,
  project text not null,
  session text not null,
  command text not null,
  body text not null,
  lines int,
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz
);

create index outputs_expires_at_idx on scratch.outputs (expires_at);

-- trigger: fills lines from body and expires_at from the project's retention setting.
-- security definer because the hook role has no usage on the knowledge schema.

create or replace function scratch.on_insert()
returns trigger
language plpgsql security definer as $$
#variable_conflict use_variable
declare
  v_days int;
begin
  new.lines := coalesce(array_length(string_to_array(new.body, E'\n'), 1), 0);
  v_days := coalesce(knowledge.setting(new.project, 'scratch.retention_days'), '7')::int;
  new.expires_at := now() + (v_days || ' days')::interval;
  return new;
end;
$$;

create trigger outputs_before_insert
  before insert on scratch.outputs
  for each row execute function scratch.on_insert();

-- functions

create or replace function scratch.put(project text, session text, command text, body text)
returns bigint
language plpgsql security definer as $$
#variable_conflict use_variable
declare
  v_id bigint;
begin
  insert into scratch.outputs (project, session, command, body)
  values (project, session, command, body)
  returning id into v_id;
  return v_id;
end;
$$;

-- read(id, from_line, to_line): the body's lines numbered by their real line number, in range,
-- capped at scratch.read_cap rows.
create or replace function scratch.read(id bigint, from_line int default 1, to_line int default 200)
returns table (n int, line text)
language plpgsql stable security invoker as $$
#variable_conflict use_variable
declare
  v_project text;
  v_cap int;
begin
  select o.project into v_project from scratch.outputs o where o.id = read.id;
  if not found then
    raise exception 'scratch.read: id % not found', id;
  end if;
  v_cap := coalesce(knowledge.setting(v_project, 'scratch.read_cap'), '200')::int;

  return query
    select l.n, l.line
    from scratch.outputs o
    cross join lateral (
      select u.ord::int as n, u.val as line
      from unnest(string_to_array(o.body, E'\n')) with ordinality as u (val, ord)
    ) l
    where o.id = read.id
      and l.n between read.from_line and read.to_line
    order by l.n
    limit v_cap;
end;
$$;

-- grep(id, pattern): case-insensitive regex match, numbered by real line number, capped.
create or replace function scratch.grep(id bigint, pattern text)
returns table (n int, line text)
language plpgsql stable security invoker as $$
#variable_conflict use_variable
declare
  v_project text;
  v_cap int;
begin
  select o.project into v_project from scratch.outputs o where o.id = grep.id;
  if not found then
    raise exception 'scratch.grep: id % not found', id;
  end if;
  v_cap := coalesce(knowledge.setting(v_project, 'scratch.read_cap'), '200')::int;

  return query
    select l.n, l.line
    from scratch.outputs o
    cross join lateral (
      select u.ord::int as n, u.val as line
      from unnest(string_to_array(o.body, E'\n')) with ordinality as u (val, ord)
    ) l
    where o.id = grep.id
      and l.line ~* grep.pattern
    order by l.n
    limit v_cap;
end;
$$;

-- head(id, lim): the first lim lines, numbered from 1, capped at scratch.read_cap.
create or replace function scratch.head(id bigint, lim int default 20)
returns table (n int, line text)
language plpgsql stable security invoker as $$
#variable_conflict use_variable
declare
  v_project text;
  v_cap int;
begin
  select o.project into v_project from scratch.outputs o where o.id = head.id;
  if not found then
    raise exception 'scratch.head: id % not found', id;
  end if;
  v_cap := coalesce(knowledge.setting(v_project, 'scratch.read_cap'), '200')::int;

  return query
    select l.n, l.line
    from scratch.outputs o
    cross join lateral (
      select u.ord::int as n, u.val as line
      from unnest(string_to_array(o.body, E'\n')) with ordinality as u (val, ord)
    ) l
    where o.id = head.id
    order by l.n
    limit least(head.lim, v_cap);
end;
$$;

-- tail(id, lim): the last lim lines, numbered to the body's real last line, capped.
create or replace function scratch.tail(id bigint, lim int default 20)
returns table (n int, line text)
language plpgsql stable security invoker as $$
#variable_conflict use_variable
declare
  v_project text;
  v_cap int;
  v_take int;
begin
  select o.project into v_project from scratch.outputs o where o.id = tail.id;
  if not found then
    raise exception 'scratch.tail: id % not found', id;
  end if;
  v_cap := coalesce(knowledge.setting(v_project, 'scratch.read_cap'), '200')::int;
  v_take := least(tail.lim, v_cap);

  return query
    select t.n, t.line
    from (
      select l.n, l.line
      from scratch.outputs o
      cross join lateral (
        select u.ord::int as n, u.val as line
        from unnest(string_to_array(o.body, E'\n')) with ordinality as u (val, ord)
      ) l
      where o.id = tail.id
      order by l.n desc
      limit v_take
    ) t
    order by t.n;
end;
$$;

-- digest(id): the short text a hop reads back in place of a stored output.
create or replace function scratch.digest(id bigint)
returns text
language plpgsql stable security definer as $$
#variable_conflict use_variable
declare
  v_row scratch.outputs;
  v_digest_lines int;
  v_head text;
  v_tail text;
begin
  select * into v_row from scratch.outputs o where o.id = digest.id;
  if not found then
    raise exception 'scratch.digest: id % not found', id;
  end if;

  v_digest_lines := coalesce(knowledge.setting(v_row.project, 'scratch.digest_lines'), '5')::int;

  select string_agg(h.line, E'\n' order by h.n) into v_head
    from scratch.head(digest.id, v_digest_lines) h;
  select string_agg(t.line, E'\n' order by t.n) into v_tail
    from scratch.tail(digest.id, v_digest_lines) t;

  return format(
    'scratch#%s: %s lines, stored %s; read: select * from scratch.read(%s, 1, 200)' || E'\n' ||
    '--- head ---' || E'\n' || '%s' || E'\n' ||
    '--- tail ---' || E'\n' || '%s',
    v_row.id, v_row.lines, to_char(v_row.created_at, 'YYYY-MM-DD HH24:MI'), v_row.id, v_head, v_tail
  );
end;
$$;

-- expire(): deletes rows past expires_at, returns the count. Owned by postgres (the init user).
create or replace function scratch.expire()
returns int
language plpgsql security definer as $$
#variable_conflict use_variable
declare
  v_count int;
begin
  delete from scratch.outputs where expires_at < now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- grants: hook inserts only (and expires); master and agent read; execute on every scratch
-- function to master, agent and hook (the store-and-digest hop and the expire hop both run as
-- hook and must call scratch.digest and scratch.expire directly).
grant select on scratch.outputs to master, agent;
grant insert on scratch.outputs to hook;
grant usage, select on all sequences in schema scratch to hook;
grant execute on all functions in schema scratch to master, agent, hook;
