# Recall: design spec

Status: draft for group review · 2026-10-12

Recall is a PostgreSQL memory store for an AI study assistant. It stores what the assistant learns about each NSUT student, where each fact came from, and who may see what. The database enforces isolation, history and provenance itself, and a test suite proves each guarantee.

## 1. Goals and constraints

**Goals**

1. Demonstrate the DBMS lab brief: database design, DDL, DML and DCL, on a 2-tier architecture.
2. Fix, with database features, the data-layer failures seen in popular agent projects in 2025-26: one user reading another's memories, search indexes going stale, memories overwritten without history, and corruption under concurrent writers.
3. Prove each fix with an automated test.

**Constraints**

- PostgreSQL 16 with the `pgvector`, `btree_gist` and `pgcrypto` extensions, run in Docker.
- 2-tier: a thin Python client (psycopg + Streamlit) connects directly to Postgres. Business rules live in constraints, functions, triggers and policies, not in the client.
- Team of 3-4, about 5-7 weeks.

**Success criteria**

- Tests 1-7 and 10 in section 7 pass.
- Tests 8-9 produce result tables for the report.
- Every table, role and test traces to a DDL, DML or DCL item in the lab brief.

## 2. Demo scenario

Recall backs an NSUT study assistant. Each student has one study profile per subject (for example DBMS, OS). Chats happen in sessions inside a profile. From those chats the assistant extracts facts such as "student · is weak at · normalization". Staff (a TA reviewer, an admin, a dashboard) have fixed, limited views.

Data: synthetic students and chats generated with Faker, plus the team's own notes as extra searchable text.

## 3. Entities and relationships

```
student 1──N profile 1──N session 1──N message
                │                          │
                ├─1──N fact ──M:N (fact_source)
                │
                └─1──N chunk N──1 embedding_model
                        └── N──1 (optional) message

access_log         (no foreign keys; written by log_access())
student_credential (1:1 with student; readable only by recall_owner)
app_secret         (single row: the token signing key)
```

- **student**: an NSUT student. Top of the isolation tree.
- **profile**: one study profile per subject per student. The unit that memories belong to.
- **session**: one chat conversation inside a profile.
- **message**: one turn in a session, from the student or the assistant.
- **fact**: one learned statement as subject, predicate, object, with a validity time range. A change closes the old row and inserts a new one; history is the set of closed rows.
- **fact_source**: links each fact to the messages it came from (many-to-many). This is provenance.
- **chunk**: a searchable piece of text (part of a message, or a note) with a keyword index and a vector embedding.
- **embedding_model**: the model that produced each chunk's vector. Exactly one model is active at a time.
- **access_log**: append-only record of reads of facts and messages.
- **student_credential** and **app_secret**: password hashes and the token signing key. Security plumbing; add them to the ER diagram as a separate group.

## 4. Tables

Naming: snake_case. Keys: `uuid` primary keys with `gen_random_uuid()`. Timestamps: `timestamptz`.

### student
| Column | Type | Rules |
|---|---|---|
| id | uuid | PK |
| roll_number | text | NOT NULL, UNIQUE, CHECK matches `^[0-9]{4}U[A-Z]{2}[0-9]{4}$` |
| name | text | NOT NULL |
| email | text | NOT NULL, UNIQUE |
| created_at | timestamptz | NOT NULL, default now() |

### student_credential
| Column | Type | Rules |
|---|---|---|
| student_id | uuid | PK, FK → student(id) ON DELETE CASCADE |
| password_hash | text | NOT NULL, bcrypt via pgcrypto `crypt()` |

Owned by recall_owner. No role except recall_owner can read it; `app_login()` reads it as SECURITY DEFINER.

### app_secret
| Column | Type | Rules |
|---|---|---|
| id | boolean | PK, CHECK (id) (single row) |
| hmac_key | bytea | NOT NULL, from `gen_random_bytes(32)` |

Owned by recall_owner, unreadable by every other role. Used to sign and verify session tokens (section 5).

### profile
| Column | Type | Rules |
|---|---|---|
| id | uuid | PK |
| student_id | uuid | NOT NULL, FK → student(id) ON DELETE CASCADE |
| subject | text | NOT NULL |
| created_at | timestamptz | NOT NULL, default now() |

UNIQUE (student_id, subject). UNIQUE (id, student_id) so child tables could reference it if needed.

### session
| Column | Type | Rules |
|---|---|---|
| id | uuid | PK |
| profile_id | uuid | NOT NULL, FK → profile(id) ON DELETE CASCADE |
| created_at | timestamptz | NOT NULL, default now() |

UNIQUE (id, profile_id).

### message
| Column | Type | Rules |
|---|---|---|
| id | uuid | PK |
| session_id | uuid | NOT NULL |
| profile_id | uuid | NOT NULL |
| speaker | text | NOT NULL, CHECK in ('student', 'assistant') |
| content | text | NOT NULL, CHECK length(content) > 0 |
| created_at | timestamptz | NOT NULL, default now() |

FK (session_id, profile_id) → session(id, profile_id). UNIQUE (id, profile_id).

### fact
| Column | Type | Rules |
|---|---|---|
| id | uuid | PK |
| profile_id | uuid | NOT NULL, FK → profile(id) ON DELETE CASCADE |
| subject | text | NOT NULL |
| predicate | text | NOT NULL |
| object | text | NOT NULL |
| valid_from | timestamptz | NOT NULL, default now() |
| valid_to | timestamptz | NULL means still valid |

- CHECK (valid_to IS NULL OR valid_to > valid_from).
- EXCLUDE USING gist (profile_id WITH =, subject WITH =, predicate WITH =, tstzrange(valid_from, valid_to) WITH &&): two versions of the same fact can never be valid at the same moment.
- UNIQUE (id, profile_id).
- `supersede_fact()` stamps times with `clock_timestamp()`, not `now()`. `now()` is fixed for a whole transaction, so changing the same fact twice in one transaction would otherwise create a zero-length range and break the CHECK.

### fact_source
| Column | Type | Rules |
|---|---|---|
| fact_id | uuid | NOT NULL |
| message_id | uuid | NOT NULL |
| profile_id | uuid | NOT NULL |

- PK (fact_id, message_id).
- FK (fact_id, profile_id) → fact(id, profile_id).
- FK (message_id, profile_id) → message(id, profile_id).

The shared `profile_id` in both composite keys makes a cross-profile link impossible.

### embedding_model
| Column | Type | Rules |
|---|---|---|
| id | uuid | PK |
| name | text | NOT NULL, UNIQUE |
| provider | text | NOT NULL |
| dimensions | int | NOT NULL, CHECK (dimensions = 384) |
| is_active | boolean | NOT NULL, default false |

Partial unique index on (is_active) WHERE is_active: at most one active model.

Seeded with two 384-dimension models so the active model can be switched (test 6): `all-MiniLM-L6-v2` (active) and `bge-small-en-v1.5`.

### chunk
| Column | Type | Rules |
|---|---|---|
| id | uuid | PK |
| profile_id | uuid | NOT NULL, FK → profile(id) ON DELETE CASCADE |
| message_id | uuid | NULL for notes |
| source_type | text | NOT NULL, CHECK in ('message', 'note') |
| text | text | NOT NULL |
| search_vector | tsvector | GENERATED ALWAYS AS (to_tsvector('english', text)) STORED |
| embedding | vector(384) | NULL until embedded |
| embedding_model_id | uuid | FK → embedding_model(id); NULL until embedded |

- FK (message_id, profile_id) → message(id, profile_id). Skipped automatically when message_id is NULL.
- CHECK ((source_type = 'message') = (message_id IS NOT NULL)).
- CHECK ((embedding IS NULL) = (embedding_model_id IS NULL)).
- Indexes: GIN on search_vector; HNSW on embedding (vector_cosine_ops).

A chunk is **stale** when its embedding_model_id is not the active model, or it has no embedding. This is computed by a query, never stored.

### access_log
| Column | Type | Rules |
|---|---|---|
| id | bigint | PK, generated always as identity |
| reader_role | text | NOT NULL, default current_user |
| student_id | uuid | value of `app.student_id` at read time, NULL for staff |
| resource_type | text | NOT NULL, CHECK in ('fact', 'message') |
| resource_id | uuid | NOT NULL |
| accessed_at | timestamptz | NOT NULL, default now() |

No foreign keys, because it points at different kinds of rows and must survive deletions. Append-only (section 5): a BEFORE UPDATE OR DELETE row trigger and a BEFORE TRUNCATE statement trigger both raise an exception. Row triggers do not fire on TRUNCATE, so both are needed.

## 5. Roles and access (DCL)

| Role | Logs in | Can | Cannot |
|---|---|---|---|
| recall_owner | No | Own all objects, run migrations | Be used by any client |
| recall_app | Yes (student client) | SELECT and INSERT own sessions, messages, chunks, fact_source; read own facts; call `supersede_fact()` and the search functions | See other students' rows; UPDATE or DELETE anything directly; touch embedding_model |
| recall_reviewer | Yes (TA) | SELECT fact and fact_source for all students | SELECT message or chunk |
| recall_dashboard | Yes | SELECT summary views only | SELECT any base table |
| recall_admin | Yes | Manage student, profile, embedding_model; SELECT access_log | UPDATE or DELETE access_log |

**Mechanisms**

1. **GRANT / REVOKE** per table and role as above. `REVOKE ALL ... FROM PUBLIC` first, on tables and on functions.

2. **Signed session token.** `app_login(roll_number, password)` is SECURITY DEFINER. It checks the bcrypt hash in `student_credential` and returns a token `student_id:expiry:signature`, where the signature is `hmac(student_id || ':' || expiry, app_secret.hmac_key, 'sha256')`. The client runs `SET app.token = '<token>'`. A SECURITY DEFINER function `current_student()` verifies the signature and expiry and returns the student_id, or NULL if the token is missing, expired or forged. A client can still set any string, but cannot forge another student's token without the key, which no client role can read. Tokens expire after 8 hours.

3. **Row-level security** with FORCE ROW LEVEL SECURITY on profile, session, message, fact, fact_source and chunk.
    - recall_app: a row is visible only when its profile's student_id = `current_student()`. INSERT policies use the same check in WITH CHECK.
    - recall_reviewer: SELECT on fact and fact_source, all rows.
    - recall_admin: SELECT, INSERT, UPDATE on profile, all rows.
    - recall_owner: a permissive `USING (true)` policy. FORCE applies RLS to the owner too, and the dashboard views and SECURITY DEFINER functions run as the owner, so without this policy they would see zero rows.

4. **SECURITY DEFINER functions check ownership themselves.** Because they run as the owner, RLS no longer protects the caller's data inside them. Every such function that takes a profile_id, fact_id or message_id first checks it belongs to `current_student()` and raises an exception if not. Test 10 covers this.

5. **Fact changes through one function**: `supersede_fact(profile_id, subject, predicate, new_object, source_message_ids[])`, SECURITY DEFINER. In one transaction it:
    1. checks the profile belongs to `current_student()` and that every source message belongs to that profile;
    2. takes `pg_advisory_xact_lock(hashtext(profile_id || subject || predicate))`, so concurrent changes to the same fact queue up. This also covers the very first version of a fact, where there is no existing row to lock;
    3. reads the open row in a new statement after the lock, so it sees any version committed while it waited;
    4. closes that row with `valid_to = clock_timestamp()`, inserts the new row with `valid_from` equal to that same timestamp, and inserts fact_source rows.

   recall_app has EXECUTE on it and no UPDATE on fact.

6. **Search functions** run as SECURITY INVOKER, so RLS applies inside them. They write to access_log through `log_access(resource_type, resource_ids[])`, a SECURITY DEFINER helper that only inserts. recall_app has EXECUTE on `log_access()` and no privileges on access_log.

7. **Views for the dashboard**: `v_facts_per_subject`, `v_stale_chunks_per_model`, created with `security_barrier` and owned by recall_owner. They return aggregates only, never row-level text.

8. **Append-only access_log**: UPDATE, DELETE and TRUNCATE revoked from every role, plus the two triggers in section 4, which also stop the owner.

9. **What is and isn't logged.** Reads through `get_facts()`, `get_messages()` and the search functions are logged. Postgres has no SELECT trigger, so a staff role's direct SELECT on a table is not logged. The report should say so.

**Remaining limits (state them in the viva).** A stolen token works until it expires. The token travels in a session setting, so anyone who can read the client's connection can reuse it. Per-student database logins or a middle tier would remove both, and are out of scope.

## 6. Key queries and functions

| Name | Purpose | Concepts |
|---|---|---|
| `app_login()`, `current_student()` | Sign in; verify the session token | pgcrypto, HMAC, SECURITY DEFINER |
| `supersede_fact()` | Replace a fact, keep history, record sources | Transaction, advisory lock, exclusion constraint |
| `facts_as_of(profile_id, ts)` | What was true at a moment | Range containment, GiST index |
| `search_keyword(q, k)` | Full-text search | tsvector, GIN, ts_rank |
| `search_semantic(vec, k)` | Nearest chunks by meaning | pgvector, HNSW; sets `hnsw.iterative_scan = relaxed_order` (pgvector 0.8+) so RLS filtering after the approximate search doesn't return fewer than k rows |
| `search_hybrid(q, vec, k)` | Reciprocal-rank fusion of both rankings | CTEs, window functions |
| `stale_chunks()` | Chunks needing re-embedding | Join + filter on active model |
| `fact_provenance(fact_id)` | Messages a fact came from | M:N join |

## 7. Tests

pytest + psycopg against the Docker database. Each test runs in a transaction rolled back at the end, except test 4, which needs real concurrent connections and cleans up after itself.

| # | Test | Method | Proves | Type |
|---|---|---|---|---|
| 1 | Isolation | Log in as student A; read every table and call every function; attempt INSERT into B's profile; set a forged, expired or missing token | Zero rows of B visible; insert rejected; bad tokens see nothing | Must pass |
| 2 | Cross-profile links | Insert fact_source and chunk rows linking A's rows to B's message | Composite FKs reject them | Must pass |
| 3 | Privilege matrix | For each role × table × action, attempt it; compare with section 5 grid | DCL matches the design exactly | Must pass |
| 4 | Concurrent updates | 20 threads call `supersede_fact()` on one existing fact; 20 threads create the same brand-new fact; repeat both with the advisory lock removed | With the lock: all calls succeed, exactly one open row, no overlaps, one history row per call. Without it: calls fail with exclusion-constraint errors, showing why the lock exists | Must pass (with lock) |
| 5 | Time travel | Build a known history; query several dates; insert an overlapping range; supersede the same fact twice in one transaction | As-of results correct; overlap rejected; double change succeeds | Must pass |
| 6 | Stale index | Switch the active model from all-MiniLM-L6-v2 to bge-small-en-v1.5 | `stale_chunks()` returns exactly the old model's chunks; re-embedding clears them | Must pass |
| 7 | Append-only log | UPDATE, DELETE and TRUNCATE on access_log as every role, including owner | All fail | Must pass |
| 8 | Search quality | recall@5 and recall@10 for keyword, semantic, hybrid on 100-200 labelled queries, 30+ of them exact-ID; also count searches returning fewer than k rows for a student with little data, with iterative scan off and on | Which method works best on this data; whether RLS shortens vector results | Experiment |
| 9 | Index speed | EXPLAIN ANALYZE on key queries with and without each index, at 10k and 100k chunks | Before/after timings for the report | Experiment |
| 10 | Definer-function leak | Logged in as A, call `supersede_fact()` with B's profile_id, and with A's profile but B's message_ids; call `log_access()` with arbitrary ids | Both supersede calls raise an exception and change nothing; `log_access()` can only insert | Must pass |

## 8. Repository layout

```
docs/specs/recall-design.md     this file
docs/er-diagram.png
db/01_extensions.sql
db/02_schema.sql                tables, keys, constraints, indexes
db/03_roles.sql                 roles, GRANT/REVOKE, RLS policies
db/04_functions.sql             supersede_fact, search, login, logging
db/05_views.sql
db/seed/                        Faker scripts and sample data
tests/                          pytest suite (tests 1-7, 10)
eval/                           tests 8-9 and result tables
client/                         Streamlit app
docker-compose.yml
```

## 9. Build layers

1. **Lab layer (weeks 1-3):** sections 4-5, `supersede_fact()`, `facts_as_of()`, keyword search, tests 1-7 and 10. This alone meets the lab brief.
2. **Resume layer (weeks 4-5):** embeddings, semantic and hybrid search, tests 8-9.
3. **Stretch (week 6+):** duplicate-fact detection, memory expiry, 100k+ scale test, client polish.

If embeddings cause trouble, the vector columns stay NULL and the lab layer still stands.

## 10. Out of scope

- Calling an LLM to extract facts automatically. Facts are inserted by the client or a seed script.
- A middle-tier API server.
- Per-student database logins.
- Deployment beyond local Docker.

## 11. Decisions and open questions

- Client: Streamlit.
- Embedding models: all-MiniLM-L6-v2 (active) and bge-small-en-v1.5, both 384 dimensions, CPU.
- Open: team size, 4 people (schema, search, security, client/testing).
