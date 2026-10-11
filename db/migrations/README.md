# Migrations

`db/init/*.sql` builds the schema from scratch on a brand-new container. Once a store holds data,
a schema change ships here instead, as a numbered file:

```
db/migrations/001-add-something.sql
db/migrations/002-...
```

`bin/knowledge-up --migrate` applies every file whose leading number is above the recorded
`schema_version` (a `*` config row), lowest first, each inside one transaction, and records the new
number. Running it again is a no-op.

Rules:

- One file per change, named `NNN-short-name.sql`, numbers strictly increasing with no gaps.
- Each file is a plain SQL script. `--migrate` wraps it in its own `begin`/`commit`; do not add your
  own transaction control.
- A migration is forward-only. To undo one, write the next migration.
- Keep `db/init/*.sql` as the from-scratch truth: a new install runs init, not the migrations. When
  you add a migration, also fold the same change into the matching `db/init` file so both paths end
  at the same schema.
- Take a dump first: `bin/knowledge-up --dump`.

0.1.0 is the first schema and ships no migration; this folder holds only this note until the first
one lands.
