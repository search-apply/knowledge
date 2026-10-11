---
name: datasets
description: Datasets in ds: describe before query, ds.sql as the default, LIMIT on every raw select, files load through docker exec, never read a table whole.
user-invocable: false
---

# Datasets (the ds store)

Plain tables an agent writes and keeps while useful. Any role creates tables in `ds`. Reach the functions through the MCP `execute_sql` tool; load files through the container.

## Creating
- Make a table: `create table ds.postings (id bigint, title text, company text);`
- Insert in batches, not row by row: `insert into ds.postings values (...), (...);`
- Load a file through the container (no psql on the host): `docker exec -i <container> psql -U agent -d knowledge -c '\copy ds.postings from stdin csv header' < postings.csv`
- Register the table so others find it: `select ds.register('<project>', 'postings', 'open roles pulled 2026-10-10');`

## Reading
- List the catalog: `select * from ds.list('<project>');`
- Describe before you query, to learn the columns: `select * from ds.describe('postings');`
- Run one read-only statement with a timeout and a row cap: `select * from ds.sql('<project>', 'select company, count(*) from ds.postings group by 1');` a result past the cap is saved as `ds.result_<n>`.
- A raw select outside `ds.sql` carries its own `LIMIT`; never read a table whole.

## Updating
- Change columns in place: `update ds.postings set company = 'Acme' where id = 1;`
- When a table is done, drop it and its catalog row: `drop table ds.postings;` then remove its `ds.register` entry.

## The reply
- A research or audit hop returns a short summary plus the table name, never the rows.
