-- t00: the helpers themselves must catch failures, or every other test is meaningless.
BEGIN;
DO $$
DECLARE caught boolean;
BEGIN
    -- t.raises must complain when the statement succeeds
    caught := false;
    BEGIN PERFORM t.raises('SELECT 1', '23503', 'x'); EXCEPTION WHEN OTHERS THEN caught := true; END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: t.raises accepted a statement that succeeded'; END IF;

    -- t.raises must complain when the error code differs
    caught := false;
    BEGIN PERFORM t.raises('SELECT 1/0', '23503', 'x'); EXCEPTION WHEN OTHERS THEN caught := true; END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: t.raises accepted the wrong SQLSTATE'; END IF;

    -- and accept the right one
    PERFORM t.raises('SELECT 1/0', '22012', 'division by zero is 22012');

    -- t.ok / t.eq / t.lives must complain on false / mismatch / error
    caught := false;
    BEGIN PERFORM t.ok(false, 'x'); EXCEPTION WHEN OTHERS THEN caught := true; END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: t.ok accepted false'; END IF;

    caught := false;
    BEGIN PERFORM t.eq(1, 2, 'x'); EXCEPTION WHEN OTHERS THEN caught := true; END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: t.eq accepted 1 = 2'; END IF;

    caught := false;
    BEGIN PERFORM t.lives('SELECT 1/0', 'x'); EXCEPTION WHEN OTHERS THEN caught := true; END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: t.lives accepted an error'; END IF;
END $$;
ROLLBACK;
