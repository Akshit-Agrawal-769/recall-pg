# Recall Lab Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the database-only "lab layer" of Recall (spec section 9, layer 1): every table, rule, role, access policy and function the spec needs without vectors, each proven by a SQL test.

**Architecture:** All business rules live in PostgreSQL: constraints, triggers, functions, roles, row-level security. Numbered `db/*.sql` files build the database in order. Each guarantee has a `tests/t*.sql` file that runs in `BEGIN … ROLLBACK` and uses the `t.*` assertion helpers. `tests/run.sh` rebuilds a throwaway database and runs everything.

**Tech Stack:** PostgreSQL 16, extensions `btree_gist`, `pgcrypto`, `dblink` (tests only); Docker (`pgvector/pgvector:pg16`); bash + psql test runner.

**Spec:** `docs/specs/recall-design.md`

## Global Constraints

- PostgreSQL 16. Required extensions: `btree_gist`, `pgcrypto`. `vector` is optional and appears only in `db/06_vectors.sql` (not part of this plan).
- The lab layer must work with no pgvector installed and with `chunk.embedding` absent.
- Business rules live in the database (constraints, functions, triggers, policies), never in a client.
- Naming: snake_case. Primary keys: `uuid DEFAULT gen_random_uuid()` (except `access_log.id`, `bigint GENERATED ALWAYS AS IDENTITY`). Timestamps: `timestamptz`.
- Roles (cluster-wide, so created idempotently): `recall_owner` NOLOGIN; `recall_app`, `recall_reviewer`, `recall_dashboard`, `recall_admin` LOGIN. No passwords in SQL files.
- Every table, view and function in schema `public` is owned by `recall_owner`.
- Every SECURITY DEFINER function: owned by `recall_owner`, declared with `SET search_path = public, pg_temp`, checks ownership against `current_student()` before touching data, and has EXECUTE revoked from PUBLIC.
- Session token: `student_id:expiry_epoch:hex_signature`, signature = `hmac(student_id || ':' || expiry_epoch, app_secret.hmac_key, 'sha256')`, lifetime 8 hours, read from the setting `app.token`.
- Fact versions are stamped with `clock_timestamp()` inside `supersede_fact()`, never `now()`.
- Embedding models seeded: `all-MiniLM-L6-v2` (active) and `bge-small-en-v1.5`, both `dimensions = 384`.
- Tests: one SQL file per guarantee in `tests/`, wrapped in `BEGIN; … ROLLBACK;` unless the task says otherwise; superuser bypasses RLS, so tests switch identity with `SET LOCAL ROLE`. The whole suite (`tests/run.sh`) passes before every commit.
- Any change to spec section 10 (out of scope) needs the user's approval first.

## Review Focus

1. A client that never logs in (no `app.token` set) sees zero rows and gets no error from `current_student()`. Pinned in Task 3.
2. Malformed tokens (no colons, non-uuid id, non-numeric expiry, empty string) make `current_student()` return NULL, not raise. Pinned in Task 3.
3. Search text containing quotes, `&`, `!`, `:` or only stop-words returns rows or zero rows, never a syntax error. Pinned in Task 7.
4. Deleting a student removes every profile, session, message, fact, fact_source and chunk below it, and leaves access_log rows untouched. Pinned in Task 2 (cascade) and Task 6 (log survives).
5. `supersede_fact()` with an empty source list is rejected, because every fact must have provenance. Pinned in Task 5.

## File Map

| File | Responsibility | Tasks |
|---|---|---|
| `db/01_extensions.sql` | Extensions | done |
| `db/02_schema.sql` | Tables, keys, CHECK/UNIQUE/EXCLUDE rules, generated columns, indexes, access_log and its guard triggers | 1, 2, 6 |
| `db/03_auth.sql` | Roles, `student_credential`, `app_secret`, token and login functions | 3 |
| `db/04_functions.sql` | `facts_as_of`, `supersede_fact`, `log_access`, `get_facts`, `get_messages`, `search_keyword`, `stale_chunks` | 1, 5, 6, 7 |
| `db/05_views.sql` | Dashboard views | 8 |
| `db/08_access.sql` | Ownership, GRANT/REVOKE, RLS enable/force/policies (runs last so it covers every object) | 4, then extended by 5–8 |
| `db/seed/seed.sql` | Synthetic NSUT demo data (not run by Docker init or tests) | 8 |
| `eval/demo_no_lock.sql` | Demo: concurrent supersede without the advisory lock fails | 5 |
| `tests/run.sh`, `tests/_helpers.sql` | Runner and assertions | 1, 5 (dblink) |

Ruling against spec section 8 layout: grants and policies move from `03_roles.sql` into `08_access.sql`, because policies call functions defined in 03/04 and must cover views and functions created later. `03` becomes `03_auth.sql`.

---

### Task 1: Docker, core schema, tests 2 and 5 (DONE)

Completed in commits `461b91f` and `2cd38ad`: `docker-compose.yml`, `db/01`, `db/02` core tables with composite foreign keys, `fact_range_forward` CHECK, `fact_no_overlap` EXCLUDE, `facts_as_of()`, `tests/t00`, `t02`, `t05`. Suite: 3 passed.

---

### Task 2: Remaining data rules

**Files:**
- Modify: `db/02_schema.sql`
- Test: `tests/t11_data_rules.sql`

**Interfaces:**
- Consumes: Task 1 tables.
- Produces: `chunk.search_vector tsvector` (generated, stored) with GIN index `chunk_search_idx`; partial unique index `embedding_model_one_active`.

- [ ] **Step 1: Write `tests/t11_data_rules.sql`.** Fixture: one student, profile, session, message (reuse the ids style from t02). Assertions:
  - `t.raises` 23514 for `message.speaker = 'bot'`; `t.lives` for `'student'` and `'assistant'`.
  - `t.raises` 23514 for `message.content = ''`.
  - `t.raises` 23514 for `roll_number = '23UCS1'`; `t.lives` for `'2023UCS0003'` (pattern `^[0-9]{4}U[A-Z]{2}[0-9]{4}$`).
  - `t.raises` 23505 for a second `profile(student_id, 'DBMS')` for the same student.
  - `t.raises` 23514 for `chunk.source_type = 'pdf'`; for `source_type = 'message'` with `message_id NULL`; for `source_type = 'note'` with a message_id.
  - `t.raises` 23514 for `embedding_model.dimensions = 768`.
  - `t.raises` 23505 when a second model is set `is_active = true`.
  - `t.eq` that `search_vector` of a chunk with text `'Normalization removes redundancy'` matches `to_tsquery('english','normalize')` (i.e. `search_vector @@ … ` is true).
  - Cascade: delete the student; `t.eq(0)` row counts for profile, session, message, fact, fact_source and chunk with that profile_id.

- [ ] **Step 2: Run** `tests/run.sh t11`. Expected: FAIL, first message "speaker … expected error 23514, but the statement succeeded".

- [ ] **Step 3: Add to `db/02_schema.sql`:** CHECK `speaker IN ('student','assistant')`; CHECK `length(content) > 0`; CHECK on roll_number pattern; `UNIQUE (student_id, subject)` on profile; CHECK `source_type IN ('message','note')` and `CHECK ((source_type = 'message') = (message_id IS NOT NULL))` on chunk; CHECK `dimensions = 384`; `CREATE UNIQUE INDEX embedding_model_one_active ON embedding_model (is_active) WHERE is_active`; `search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english', text)) STORED` plus `CREATE INDEX chunk_search_idx ON chunk USING gin (search_vector)`. Insert the two seed models from Global Constraints.

- [ ] **Step 4: Run** `tests/run.sh`. Expected: `4 passed, 0 failed`.

- [ ] **Step 5: Commit** `db/02_schema.sql tests/t11_data_rules.sql` — "Data rules: value checks, one profile per subject, one active model, generated search column (t11)".

---

### Task 3: Roles, credentials and signed session tokens

**Files:**
- Create: `db/03_auth.sql`
- Test: `tests/t01a_tokens.sql`

**Interfaces:**
- Consumes: `student`.
- Produces:
  - roles `recall_owner`, `recall_app`, `recall_reviewer`, `recall_dashboard`, `recall_admin` (created only if missing)
  - tables `student_credential(student_id uuid PK → student ON DELETE CASCADE, password_hash text NOT NULL)`, `app_secret(id boolean PK CHECK (id), hmac_key bytea NOT NULL)`, with one row inserted using `gen_random_bytes(32)`
  - `set_student_password(p_student_id uuid, p_password text) RETURNS void` — SECURITY DEFINER; stores `crypt(p_password, gen_salt('bf'))`; EXECUTE for `recall_admin` only
  - `sign_token(p_student_id uuid, p_expires_at timestamptz) RETURNS text` — SECURITY DEFINER; no EXECUTE for any client role (tests call it as superuser)
  - `app_login(p_roll_number text, p_password text) RETURNS text` — SECURITY DEFINER; returns `sign_token(id, now() + interval '8 hours')`; raises SQLSTATE `28P01` on unknown roll number or wrong password (same message for both); EXECUTE for `recall_app`
  - `current_student() RETURNS uuid` — SECURITY DEFINER, STABLE; reads `current_setting('app.token', true)`; returns NULL for missing, malformed, expired or badly signed tokens; never raises

- [ ] **Step 1: Write `tests/t01a_tokens.sql`.** Fixture: students Asha and Bilal; `set_student_password` for Asha with `'asha-pass'`. Assertions (as superuser unless noted):
  - `app_login('2023UCS0001','asha-pass')` returns a token; after `SET LOCAL app.token = <that token>`, `current_student()` = Asha's id.
  - `t.raises` 28P01 for a wrong password and for an unknown roll number.
  - Token signed for Asha with Bilal's id swapped into the first field: `current_student()` IS NULL.
  - `sign_token(Asha, now() - interval '1 minute')`: `current_student()` IS NULL.
  - Review Focus 1: with `app.token` reset, `current_student()` IS NULL.
  - Review Focus 2: for each of `''`, `'garbage'`, `'not-a-uuid:123:abc'`, `'<asha id>:notanumber:abc'`, `current_student()` IS NULL (use `t.lives` around the call, then `t.ok(... IS NULL)`).
  - `student_credential.password_hash` does not contain `'asha-pass'`.

- [ ] **Step 2: Run** `tests/run.sh t01a`. Expected: FAIL with "function set_student_password … does not exist".

- [ ] **Step 3: Implement `db/03_auth.sql`** with the interfaces above. Role creation inside `DO` blocks checking `pg_roles`. `current_student()` wraps its parsing in `BEGIN … EXCEPTION WHEN OTHERS THEN RETURN NULL` and compares signatures with `=` on the hex strings.

- [ ] **Step 4: Run** `tests/run.sh`. Expected: `5 passed, 0 failed`.

- [ ] **Step 5: Commit** `db/03_auth.sql tests/t01a_tokens.sql` — "Auth: roles, hashed credentials, HMAC-signed session tokens (t01a)".

---

### Task 4: Ownership, privileges and row-level security

**Files:**
- Create: `db/08_access.sql`
- Test: `tests/t01b_isolation.sql`, `tests/t03_privileges.sql`

**Interfaces:**
- Consumes: Task 3 roles and `current_student()`; all tables.
- Produces:
  - every table, view and function in `public` owned by `recall_owner` (DO-loop over `pg_class` / `pg_proc` in schema `public`, skipping extension-owned objects)
  - `REVOKE ALL` on all tables and functions FROM PUBLIC, then the grant matrix of spec section 5
  - RLS ENABLE + FORCE on profile, session, message, fact, fact_source, chunk, with policies:
    - `<table>_student`: recall_app, `profile_id IN (SELECT id FROM profile WHERE student_id = current_student())` (on profile itself: `student_id = current_student()`), for SELECT and INSERT (`WITH CHECK` same predicate)
    - `<table>_reviewer`: recall_reviewer, SELECT `USING (true)` on fact and fact_source
    - `profile_admin`: recall_admin, SELECT/INSERT/UPDATE `USING (true)` on profile
    - `<table>_owner`: recall_owner, ALL `USING (true)`
  - Grants for this task: recall_app SELECT on profile (profiles are created by recall_admin); SELECT, INSERT on session, message, chunk, fact_source; SELECT on fact; EXECUTE on `app_login`, `current_student`, `facts_as_of`. recall_reviewer SELECT on fact, fact_source. recall_admin SELECT, INSERT, UPDATE on student, profile, embedding_model; EXECUTE on `set_student_password`. recall_dashboard nothing yet (views in Task 8).
  - `db/08_access.sql` is idempotent and re-run as the last file; later tasks append their grants here.

- [ ] **Step 1: Write `tests/t01b_isolation.sql`.** Fixture as superuser: Asha and Bilal, each with profile, session, message, fact, chunk. Then `SET LOCAL app.token = sign_token(Asha, now()+'1h')` and `SET LOCAL ROLE recall_app`:
  - `t.eq` count of Bilal's rows visible = 0 in each of profile, session, message, fact, fact_source, chunk; Asha's own rows count ≥ 1.
  - `facts_as_of(<Bilal profile>, now())` returns 0 rows.
  - `t.raises` 42501 (RLS WITH CHECK violation) inserting a session into Bilal's profile.
  - With `app.token` set to `''`: 0 rows in every table (Review Focus 1).

- [ ] **Step 2: Write `tests/t03_privileges.sql`.** A `VALUES` list of `(role, statement, expect)` where expect is `'ok'` or `'42501'`. A DO block loops: `SET LOCAL ROLE`, then `t.lives` or `t.raises`, then `RESET ROLE`. Cover at least:
  - recall_app: SELECT fact ok; UPDATE fact 42501; DELETE message 42501; SELECT student_credential 42501; SELECT app_secret 42501; SELECT embedding_model 42501; EXECUTE sign_token 42501.
  - recall_reviewer: SELECT fact ok; SELECT message 42501; SELECT chunk 42501.
  - recall_dashboard: SELECT fact 42501; SELECT profile 42501.
  - recall_admin: INSERT profile ok; SELECT student_credential 42501.

- [ ] **Step 3: Run** `tests/run.sh t01b` and `tests/run.sh t03`. Expected: both FAIL (t01b: Bilal's rows visible; t03: first expected 42501 succeeded or role lacks SELECT).

- [ ] **Step 4: Implement `db/08_access.sql`** per Interfaces.

- [ ] **Step 5: Run** `tests/run.sh`. Expected: `7 passed, 0 failed`. If an earlier test now fails because functions are owned by recall_owner, fix the cause with superpowers:systematic-debugging; do not weaken a policy.

- [ ] **Step 6: Commit** `db/08_access.sql tests/t01b_isolation.sql tests/t03_privileges.sql` — "Access: owner, grants, row-level security (t01b, t03)".

---

### Task 5: supersede_fact()

**Files:**
- Modify: `db/04_functions.sql`, `db/08_access.sql`, `tests/_helpers.sql` or `tests/run.sh` (create `dblink` in the test DB), `tests/t05_time_travel.sql`
- Create: `tests/t04_concurrency.sql`, `tests/t10_definer_leak.sql`, `eval/demo_no_lock.sql`

**Interfaces:**
- Consumes: `current_student()`, fact/fact_source/message tables.
- Produces: `supersede_fact(p_profile_id uuid, p_subject text, p_predicate text, p_object text, p_source_message_ids uuid[]) RETURNS uuid` (id of the new version). SECURITY DEFINER. Steps in order:
  1. raise `42501` unless the profile's student_id = `current_student()`;
  2. raise `22023` if `p_source_message_ids` is NULL or empty (Review Focus 5);
  3. raise `42501` unless every source message has `profile_id = p_profile_id`;
  4. `pg_advisory_xact_lock(hashtext(p_profile_id::text || '|' || p_subject || '|' || p_predicate))`;
  5. new statement: read the open row (`valid_to IS NULL`) for that key;
  6. `v_ts := clock_timestamp()`; close the open row with `valid_to = v_ts`; insert the new row with `valid_from = v_ts`; insert fact_source rows.
  EXECUTE granted to recall_app.

- [ ] **Step 1: Extend `tests/t05_time_travel.sql`** (logged in as Asha via token + `SET LOCAL ROLE recall_app`): call `supersede_fact` twice in the same transaction on one key; `t.lives` both; then exactly one open row and versions chained with no gap (`prev.valid_to = next.valid_from`).

- [ ] **Step 2: Write `tests/t10_definer_leak.sql`** as Asha: `t.raises` 42501 for `supersede_fact(<Bilal profile>, …)`; `t.raises` 42501 for Asha's profile with Bilal's message id; `t.raises` 22023 for an empty array; afterwards Bilal's fact rows are unchanged.

- [ ] **Step 3: Write `tests/t04_concurrency.sql`.** Not wrapped in a rollback: it commits a fixture under unique ids, opens 20 `dblink` connections (`dbname=current_database()`), each runs `SET app.token = '<asha token>'; SET ROLE recall_app; SELECT supersede_fact(...)` via `dblink_send_query`, collects every result with `dblink_get_result`, then asserts: 20 calls succeeded, exactly 1 open row, 21 versions in total, no overlapping ranges, 20 + 1 fact_source groups. Repeat with a brand-new key (no initial row) and assert 1 open row and 20 versions. Final step deletes the fixture student (cascade) even on failure (`EXCEPTION` block re-raises after cleanup).

- [ ] **Step 4: Run** `tests/run.sh`. Expected: t04, t05 and t10 FAIL with "function supersede_fact … does not exist"; others pass.

- [ ] **Step 5: Implement** `supersede_fact` in `db/04_functions.sql`; grant EXECUTE in `db/08_access.sql`; add `CREATE EXTENSION IF NOT EXISTS dblink` to the test setup only.

- [ ] **Step 6: Run** `tests/run.sh`. Expected: `9 passed, 0 failed`.

- [ ] **Step 7: Write `eval/demo_no_lock.sql`**: a copy of the function without step 4 under the name `supersede_fact_nolock`, then the same 20-connection run, printing how many calls failed with `23P01`. Run it once and paste the counts into the commit message. Not part of the suite (ruling: a deliberately broken function must not live in `db/`).

- [ ] **Step 8: Commit** — "supersede_fact with advisory lock and ownership checks (t04, t05, t10)".

---

### Task 6: Append-only access log

**Files:**
- Modify: `db/02_schema.sql`, `db/04_functions.sql`, `db/08_access.sql`, `tests/t10_definer_leak.sql`
- Create: `tests/t07_append_only.sql`

**Interfaces:**
- Produces:
  - table `access_log` (spec section 4) plus `access_log_no_change` BEFORE UPDATE OR DELETE row trigger and `access_log_no_truncate` BEFORE TRUNCATE statement trigger, both raising `42501` with message "access_log is append-only"
  - `log_access(p_resource_type text, p_resource_ids uuid[]) RETURNS void` — SECURITY DEFINER; inserts one row per id with `reader_role = session_user`, `student_id = current_student()`; nothing else
  - `get_facts(p_profile_id uuid) RETURNS SETOF fact` — INVOKER; open facts of the profile; calls `log_access('fact', …)`
  - `get_messages(p_session_id uuid) RETURNS SETOF message` — INVOKER; calls `log_access('message', …)`
  - `fact_provenance(p_fact_id uuid) RETURNS SETOF message` — INVOKER; the messages linked through fact_source; calls `log_access('message', …)`
  - recall_app EXECUTE on all four; recall_admin SELECT on access_log; no role gets INSERT/UPDATE/DELETE/TRUNCATE on access_log

- [ ] **Step 1: Write `tests/t07_append_only.sql`**: insert a log row as superuser; for each of recall_owner, recall_admin, recall_app, and the superuser itself, `t.raises` for UPDATE, DELETE and TRUNCATE (expect 42501). Then Review Focus 4: delete a student whose ids appear in access_log; the log rows remain.

- [ ] **Step 2: Extend `tests/t10_definer_leak.sql`**: as Asha, `get_facts(<Asha profile>)` adds rows to access_log with Asha's student_id; `get_facts(<Bilal profile>)` returns 0 rows; `fact_provenance(<Asha fact>)` returns her source message and `fact_provenance(<Bilal fact>)` returns 0 rows; recall_app `t.raises` 42501 on a direct INSERT into access_log.

- [ ] **Step 3: Run** `tests/run.sh`. Expected: t07 and t10 FAIL.

- [ ] **Step 4: Implement** per Interfaces.

- [ ] **Step 5: Run** `tests/run.sh`. Expected: `10 passed, 0 failed`.

- [ ] **Step 6: Commit** — "Append-only access log and logged read functions (t07, t10)".

---

### Task 7: Keyword search and stale-chunk detection

**Files:**
- Modify: `db/04_functions.sql`, `db/08_access.sql`, `tests/t01b_isolation.sql`
- Create: `tests/t06_stale.sql`, `tests/t12_search.sql`

**Interfaces:**
- Produces:
  - `search_keyword(p_query text, p_k int DEFAULT 10) RETURNS TABLE (chunk_id uuid, profile_id uuid, text text, rank real)` — INVOKER; `websearch_to_tsquery('english', p_query)`, ordered by `ts_rank` desc, limit `p_k`; logs returned chunk ids via `log_access('chunk', …)` (add `'chunk'` to the access_log resource_type CHECK)
  - `stale_chunks() RETURNS SETOF chunk` — INVOKER; chunks with `embedding_model_id IS NULL` or not the active model
  - recall_app EXECUTE on both

- [ ] **Step 1: Write `tests/t12_search.sql`** as Asha: a query matching her chunk returns it, ranked first among two; a query matching only Bilal's chunk returns 0 rows; Review Focus 3: `t.lives` for `'"unclosed'`, `'a & b ! c:'`, `'the and of'`, `''`.

- [ ] **Step 2: Extend `tests/t01b_isolation.sql`**: `search_keyword` for Bilal's exact text returns 0 rows for Asha.

- [ ] **Step 3: Write `tests/t06_stale.sql`** as superuser: three chunks on the active model, two on the other, one unembedded; `stale_chunks()` returns exactly the 3 non-active-model ones; switch the active model (in one transaction: unset old, set new); now exactly the other 4 are stale.

- [ ] **Step 4: Run** `tests/run.sh`. Expected: t06, t12 and t01b FAIL.

- [ ] **Step 5: Implement** per Interfaces.

- [ ] **Step 6: Run** `tests/run.sh`. Expected: `12 passed, 0 failed`.

- [ ] **Step 7: Commit** — "Keyword search with logging and stale-chunk detection (t06, t12)".

---

### Task 8: Dashboard views and demo seed

**Files:**
- Create: `db/05_views.sql`, `db/seed/seed.sql`, `tests/t13_views.sql`
- Modify: `db/08_access.sql`, `tests/t03_privileges.sql`, `README.md`

**Interfaces:**
- Produces:
  - `v_facts_per_subject(subject text, open_facts bigint, students bigint)` and `v_stale_chunks_per_model(model_name text, stale_chunks bigint)`, both `WITH (security_barrier)`, owned by recall_owner, SELECT for recall_dashboard only
  - `db/seed/seed.sql`: 40 synthetic students with valid roll numbers, 1–3 profiles each from ('DBMS','OS','CN','DSA'), sessions, messages, facts with 1–3 versions created through `supersede_fact` (logged in per student via `sign_token`), chunks as notes and messages, passwords `'demo-<roll_number>'`. Uses `generate_series` and fixed arrays only, so it needs no extra tools.

- [ ] **Step 1: Write `tests/t13_views.sql`**: known fixture (2 students, DBMS for both, OS for one); as recall_dashboard, `v_facts_per_subject` gives DBMS → 2 students; `v_stale_chunks_per_model` counts match `stale_chunks()`.

- [ ] **Step 2: Extend `tests/t03_privileges.sql`**: recall_dashboard SELECT on both views ok; recall_app SELECT on both views 42501.

- [ ] **Step 3: Run** `tests/run.sh`. Expected: t13 and t03 FAIL.

- [ ] **Step 4: Implement** `db/05_views.sql` and grants in `db/08_access.sql`.

- [ ] **Step 5: Run** `tests/run.sh`. Expected: `13 passed, 0 failed`.

- [ ] **Step 6: Write `db/seed/seed.sql`** and run it on a fresh database built from `db/*.sql`. Expected: 40 students; at least one fact with 3 versions; `tests/run.sh` still passes afterwards (the runner rebuilds its own DB).

- [ ] **Step 7: Update `README.md`**: layout table (03, 05, 08, seed, eval) and "Load demo data: `docker compose exec db psql -U postgres -d recall -f /work/db/seed/seed.sql`".

- [ ] **Step 8: Commit** — "Dashboard views and demo seed (t13)".

---

## Not in this plan

The Streamlit client, `db/06_vectors.sql` with semantic and hybrid search, and tests 8–9 (search quality, index speed) get their own plans after this one ships (spec section 9, layers 2–3).
