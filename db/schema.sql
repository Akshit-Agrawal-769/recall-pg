
CREATE TABLE student (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    roll_number text NOT NULL UNIQUE,
    name        text NOT NULL,
    email       text NOT NULL UNIQUE,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE profile (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    student_id  uuid NOT NULL REFERENCES student(id) ON DELETE CASCADE,
    subject     text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE session (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id  uuid NOT NULL REFERENCES profile(id) ON DELETE CASCADE,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, profile_id)            -- target for composite FKs below
);

CREATE TABLE message (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id  uuid NOT NULL,
    profile_id  uuid NOT NULL,
    speaker     text NOT NULL,
    content     text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, profile_id),
    -- the session must belong to the same profile as the message
    FOREIGN KEY (session_id, profile_id) REFERENCES session (id, profile_id) ON DELETE CASCADE
);

CREATE TABLE fact (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id  uuid NOT NULL REFERENCES profile(id) ON DELETE CASCADE,
    subject     text NOT NULL,
    predicate   text NOT NULL,
    object      text NOT NULL,
    valid_from  timestamptz NOT NULL DEFAULT now(),
    valid_to    timestamptz,              -- NULL = still valid
    UNIQUE (id, profile_id),
    -- a version's range is never empty or backwards
    CONSTRAINT fact_range_forward CHECK (valid_to IS NULL OR valid_to > valid_from),
    -- two versions of the same fact are never valid at the same moment
    -- (btree_gist supplies '=' for uuid/text inside a GiST index; the index also serves facts_as_of)
    CONSTRAINT fact_no_overlap EXCLUDE USING gist (
        profile_id WITH =,
        subject    WITH =,
        predicate  WITH =,
        tstzrange(valid_from, valid_to) WITH &&
    )
);

CREATE TABLE fact_source (
    fact_id     uuid NOT NULL,
    message_id  uuid NOT NULL,
    profile_id  uuid NOT NULL,
    PRIMARY KEY (fact_id, message_id),
    -- both ends must belong to the same profile, so provenance never crosses students
    FOREIGN KEY (fact_id, profile_id)    REFERENCES fact    (id, profile_id) ON DELETE CASCADE,
    FOREIGN KEY (message_id, profile_id) REFERENCES message (id, profile_id) ON DELETE CASCADE
);

CREATE TABLE embedding_model (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL UNIQUE,
    provider    text NOT NULL,
    dimensions  int  NOT NULL,
    is_active   boolean NOT NULL DEFAULT false
);

CREATE TABLE chunk (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id          uuid NOT NULL REFERENCES profile(id) ON DELETE CASCADE,
    message_id          uuid,              -- NULL for notes
    source_type         text NOT NULL,
    text                text NOT NULL,
    embedding_model_id  uuid REFERENCES embedding_model(id),
    -- a chunk built from a message must use a message of the same profile
    -- (MATCH SIMPLE: skipped when message_id is NULL)
    FOREIGN KEY (message_id, profile_id) REFERENCES message (id, profile_id) ON DELETE CASCADE
);
