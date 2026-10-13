-- Test utilities. Loaded by tests/run.sh into a separate schema "t".
-- Never part of the product database.

CREATE SCHEMA IF NOT EXISTS t;

-- Fail unless cond is true.
CREATE OR REPLACE FUNCTION t.ok(cond boolean, msg text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF cond IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: %', msg;
    END IF;
END $$;

-- Fail unless actual = expected.
CREATE OR REPLACE FUNCTION t.eq(actual anyelement, expected anyelement, msg text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'FAIL: % (expected %, got %)', msg, expected, actual;
    END IF;
END $$;

-- Fail unless running stmt raises an error with the given SQLSTATE.
-- Runs in a subtransaction, so a statement that wrongly succeeds is rolled back.
CREATE OR REPLACE FUNCTION t.raises(stmt text, expected_state text, msg text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    got text;
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN OTHERS THEN
        got := SQLSTATE;
    END;
    IF got IS NULL THEN
        RAISE EXCEPTION 'FAIL: % (expected error %, but the statement succeeded)', msg, expected_state;
    ELSIF got <> expected_state THEN
        RAISE EXCEPTION 'FAIL: % (expected error %, got %)', msg, expected_state, got;
    END IF;
END $$;

-- Fail if running stmt raises any error.
CREATE OR REPLACE FUNCTION t.lives(stmt text, msg text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE stmt;
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'FAIL: % (unexpected error %: %)', msg, SQLSTATE, SQLERRM;
END $$;
