-- t05 Time travel
-- Guarantees:
--   * a fact version's validity range is never empty or backwards (CHECK)
--   * two versions of the same fact (profile, subject, predicate) are never valid at the same moment (EXCLUDE)
--   * facts_as_of(profile, ts) returns exactly the version valid at ts, using half-open ranges [from, to)
-- Not yet covered: superseding the same fact twice in one transaction (added with supersede_fact()).
BEGIN;

INSERT INTO student (id, roll_number, name, email) VALUES
  ('a0000000-0000-0000-0000-000000000001', '2023UCS0001', 'Asha', 'asha@nsut.ac.in');
INSERT INTO profile (id, student_id, subject) VALUES
  ('a0000000-0000-0000-0000-0000000000a1', 'a0000000-0000-0000-0000-000000000001', 'DBMS'),
  ('a0000000-0000-0000-0000-0000000000a2', 'a0000000-0000-0000-0000-000000000001', 'OS');

-- Known history for (Asha/DBMS, student, is weak at):
--   1 Aug - 1 Sep : normalization
--   1 Sep - 1 Oct : indexing
--   1 Oct - now   : transactions   (open)
INSERT INTO fact (profile_id, subject, predicate, object, valid_from, valid_to) VALUES
  ('a0000000-0000-0000-0000-0000000000a1', 'student', 'is weak at', 'normalization', '2026-08-01', '2026-09-01'),
  ('a0000000-0000-0000-0000-0000000000a1', 'student', 'is weak at', 'indexing',      '2026-09-01', '2026-10-01'),
  ('a0000000-0000-0000-0000-0000000000a1', 'student', 'is weak at', 'transactions',  '2026-10-01', NULL);

DO $$
DECLARE
    p constant uuid := 'a0000000-0000-0000-0000-0000000000a1';
    weak text;
BEGIN
    -- As-of answers, including the exact boundary moments.
    SELECT object INTO weak FROM facts_as_of(p, '2026-08-15') WHERE predicate = 'is weak at';
    PERFORM t.eq(weak, 'normalization', 'as of 15 Aug');
    SELECT object INTO weak FROM facts_as_of(p, '2026-09-01') WHERE predicate = 'is weak at';
    PERFORM t.eq(weak, 'indexing', 'as of 1 Sep (boundary belongs to the newer version)');
    SELECT object INTO weak FROM facts_as_of(p, '2026-12-25') WHERE predicate = 'is weak at';
    PERFORM t.eq(weak, 'transactions', 'as of 25 Dec (open version)');
    PERFORM t.eq((SELECT count(*) FROM facts_as_of(p, '2026-07-01')), 0::bigint, 'before any history: nothing');
    PERFORM t.eq((SELECT count(*) FROM facts_as_of(p, '2026-09-15')), 1::bigint, 'exactly one version at a time');

    -- Overlaps for the same fact are rejected.
    PERFORM t.raises($q$
        INSERT INTO fact (profile_id, subject, predicate, object, valid_from, valid_to)
        VALUES ('a0000000-0000-0000-0000-0000000000a1', 'student', 'is weak at', 'joins', '2026-09-15', '2026-09-20')
    $q$, '23P01', 'overlap inside a closed version is rejected');
    PERFORM t.raises($q$
        INSERT INTO fact (profile_id, subject, predicate, object, valid_from, valid_to)
        VALUES ('a0000000-0000-0000-0000-0000000000a1', 'student', 'is weak at', 'joins', '2026-11-01', NULL)
    $q$, '23P01', 'a second open version is rejected');

    -- Controls: the same period is fine for a different predicate or a different profile.
    PERFORM t.lives($q$
        INSERT INTO fact (profile_id, subject, predicate, object, valid_from, valid_to)
        VALUES ('a0000000-0000-0000-0000-0000000000a1', 'student', 'prefers', 'diagrams', '2026-09-15', NULL)
    $q$, 'different predicate may overlap');
    PERFORM t.lives($q$
        INSERT INTO fact (profile_id, subject, predicate, object, valid_from, valid_to)
        VALUES ('a0000000-0000-0000-0000-0000000000a2', 'student', 'is weak at', 'paging', '2026-09-15', NULL)
    $q$, 'different profile may overlap');

    -- Empty or backwards ranges are rejected.
    PERFORM t.raises($q$
        INSERT INTO fact (profile_id, subject, predicate, object, valid_from, valid_to)
        VALUES ('a0000000-0000-0000-0000-0000000000a1', 'student', 'likes', 'SQL', '2026-05-01', '2026-05-01')
    $q$, '23514', 'zero-length range is rejected');
    PERFORM t.raises($q$
        INSERT INTO fact (profile_id, subject, predicate, object, valid_from, valid_to)
        VALUES ('a0000000-0000-0000-0000-0000000000a1', 'student', 'likes', 'SQL', '2026-05-02', '2026-05-01')
    $q$, '23514', 'backwards range is rejected');
END $$;

ROLLBACK;
