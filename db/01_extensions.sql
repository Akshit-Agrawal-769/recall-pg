-- 01_extensions.sql
-- Extensions the lab layer needs. pgvector is optional and lives in 06_vectors.sql.

CREATE EXTENSION IF NOT EXISTS btree_gist;  -- '=' on uuid/text inside GiST exclusion constraints
CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- gen_random_uuid() helpers, crypt(), hmac()
