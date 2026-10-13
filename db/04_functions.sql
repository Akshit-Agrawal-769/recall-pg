-- 04_functions.sql
-- Query and write functions. Business rules live here and in constraints, not in the client.

-- What did this profile believe at moment ts?
-- Validity ranges are half-open [valid_from, valid_to): at the exact switch moment the newer version wins.
-- SECURITY INVOKER (the default), so row-level security applies to the caller.
CREATE OR REPLACE FUNCTION facts_as_of(p_profile_id uuid, ts timestamptz)
RETURNS TABLE (fact_id uuid, subject text, predicate text, object text,
               valid_from timestamptz, valid_to timestamptz)
LANGUAGE sql STABLE
AS $$
    SELECT f.id, f.subject, f.predicate, f.object, f.valid_from, f.valid_to
    FROM fact f
    WHERE f.profile_id = p_profile_id
      AND tstzrange(f.valid_from, f.valid_to) @> ts;
$$;
