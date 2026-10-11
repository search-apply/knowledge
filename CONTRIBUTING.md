# Contributing

- Docker is the only dependency; `db/tests/run.sh` must pass before and after any change.
- Write the test first where a test is possible, then the code; never drop a test or a check.
- One coherent change per commit, with a body saying why.
- SQL: `db/init/*.sql` is the from-scratch schema, `db/migrations/NNN-*.sql` a change to a live
  store; fold a migration's change into `db/init` too so both paths end at the same schema.
- Hooks and bin scripts are shellcheck-clean bash, each with a `--self-test` where it can.
- No house- or product-specific names under `db`, `hooks`, `skills` or `bin` (the runner enforces it).
- Plain ASCII in docs and skills; each skill under 55 lines; no secrets or transcripts in the repo.
