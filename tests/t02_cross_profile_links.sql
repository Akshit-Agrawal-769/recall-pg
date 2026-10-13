-- t02 Cross-profile links
-- Guarantee: no row can link data from one profile to data in another profile.
-- Proves: the composite foreign keys on message, fact_source and chunk reject cross-profile links,
-- while links inside one profile still work.
BEGIN;

-- Two students, each with one profile, session, message and fact.
INSERT INTO student (id, roll_number, name, email) VALUES
  ('a0000000-0000-0000-0000-000000000001', '2023UCS0001', 'Asha',  'asha@nsut.ac.in'),
  ('b0000000-0000-0000-0000-000000000001', '2023UCS0002', 'Bilal', 'bilal@nsut.ac.in');
INSERT INTO profile (id, student_id, subject) VALUES
  ('a0000000-0000-0000-0000-0000000000a1', 'a0000000-0000-0000-0000-000000000001', 'DBMS'),
  ('b0000000-0000-0000-0000-0000000000b1', 'b0000000-0000-0000-0000-000000000001', 'DBMS');
INSERT INTO session (id, profile_id) VALUES
  ('a0000000-0000-0000-0000-00000000a5a1', 'a0000000-0000-0000-0000-0000000000a1'),
  ('b0000000-0000-0000-0000-00000000b5b1', 'b0000000-0000-0000-0000-0000000000b1');
INSERT INTO message (id, session_id, profile_id, speaker, content) VALUES
  ('a0000000-0000-0000-0000-0000000a3e51', 'a0000000-0000-0000-0000-00000000a5a1', 'a0000000-0000-0000-0000-0000000000a1', 'student', 'I keep mixing up 3NF and BCNF'),
  ('b0000000-0000-0000-0000-0000000b3e51', 'b0000000-0000-0000-0000-00000000b5b1', 'b0000000-0000-0000-0000-0000000000b1', 'student', 'Explain two-phase locking');
INSERT INTO fact (id, profile_id, subject, predicate, object) VALUES
  ('a0000000-0000-0000-0000-00000000fac1', 'a0000000-0000-0000-0000-0000000000a1', 'student', 'is weak at', 'normalization');

DO $$
BEGIN
    -- Control: links inside one profile are accepted.
    PERFORM t.lives($q$
        INSERT INTO fact_source (fact_id, message_id, profile_id) VALUES
        ('a0000000-0000-0000-0000-00000000fac1', 'a0000000-0000-0000-0000-0000000a3e51', 'a0000000-0000-0000-0000-0000000000a1')
    $q$, 'same-profile fact_source is accepted');
    PERFORM t.lives($q$
        INSERT INTO chunk (profile_id, message_id, source_type, text) VALUES
        ('a0000000-0000-0000-0000-0000000000a1', 'a0000000-0000-0000-0000-0000000a3e51', 'message', 'I keep mixing up 3NF and BCNF')
    $q$, 'same-profile chunk is accepted');

    -- A's fact sourced from B's message, labelled as A's profile.
    PERFORM t.raises($q$
        INSERT INTO fact_source (fact_id, message_id, profile_id) VALUES
        ('a0000000-0000-0000-0000-00000000fac1', 'b0000000-0000-0000-0000-0000000b3e51', 'a0000000-0000-0000-0000-0000000000a1')
    $q$, '23503', 'fact_source: A''s fact cannot cite B''s message (labelled A)');

    -- Same link, labelled as B's profile instead.
    PERFORM t.raises($q$
        INSERT INTO fact_source (fact_id, message_id, profile_id) VALUES
        ('a0000000-0000-0000-0000-00000000fac1', 'b0000000-0000-0000-0000-0000000b3e51', 'b0000000-0000-0000-0000-0000000000b1')
    $q$, '23503', 'fact_source: A''s fact cannot cite B''s message (labelled B)');

    -- A chunk in A's profile built from B's message.
    PERFORM t.raises($q$
        INSERT INTO chunk (profile_id, message_id, source_type, text) VALUES
        ('a0000000-0000-0000-0000-0000000000a1', 'b0000000-0000-0000-0000-0000000b3e51', 'message', 'Explain two-phase locking')
    $q$, '23503', 'chunk: A''s chunk cannot point at B''s message');

    -- A message filed under A's profile but inside B's session.
    PERFORM t.raises($q$
        INSERT INTO message (session_id, profile_id, speaker, content) VALUES
        ('b0000000-0000-0000-0000-00000000b5b1', 'a0000000-0000-0000-0000-0000000000a1', 'student', 'hello')
    $q$, '23503', 'message: cannot sit in B''s session under A''s profile');
END $$;

ROLLBACK;
