# recall-pg

Recall is a PostgreSQL memory store for an AI study assistant. The database itself enforces isolation between students, fact history and provenance, and a test suite proves each guarantee. Design: [docs/specs/recall-design.md](docs/specs/recall-design.md).

## Run it

Start Postgres 16 with pgvector (first start applies every `db/*.sql` file):

```
docker compose up -d
```

Run the tests. Each run rebuilds a throwaway `recall_test` database from `db/*.sql`.

From any terminal (PowerShell included), inside the container:

```
docker compose exec -e PGPASSWORD=postgres db bash /work/tests/run.sh        # all tests
docker compose exec -e PGPASSWORD=postgres db bash /work/tests/run.sh t05    # one test
```

Or from Git Bash / WSL if `psql`, `createdb` and `dropdb` are on your PATH:

```
PGPASSWORD=postgres tests/run.sh
```

## Layout

| Path | What |
|---|---|
| `db/01_extensions.sql` | btree_gist, pgcrypto |
| `db/02_schema.sql` | tables, keys, constraints |
| `db/04_functions.sql` | query and write functions |
| `tests/t*.sql` | one file per guarantee; each runs in a transaction that is rolled back |
| `tests/_helpers.sql` | `t.ok`, `t.eq`, `t.raises`, `t.lives` assertions |
