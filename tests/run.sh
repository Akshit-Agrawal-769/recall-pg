#!/usr/bin/env bash
# Rebuild a throwaway database from db/*.sql, then run every tests/t*.sql file.
# Usage: tests/run.sh [pattern]     e.g. tests/run.sh t02
# Connection comes from the usual PG* variables (default: localhost, user postgres).
set -uo pipefail

cd "$(dirname "$0")/.."
export PGHOST="${PGHOST:-localhost}" PGUSER="${PGUSER:-postgres}" PGPORT="${PGPORT:-5432}"
TEST_DB="${TEST_DB:-recall_test}"
PATTERN="${1:-}"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d "$TEST_DB")

dropdb --if-exists "$TEST_DB" && createdb "$TEST_DB" || { echo "cannot create $TEST_DB"; exit 2; }

has_vector=$(psql -X -Atd "$TEST_DB" -c "select count(*) from pg_available_extensions where name='vector'")
for f in db/[0-9]*.sql; do
    if [[ "$f" == *_vectors.sql && "$has_vector" == "0" ]]; then
        echo "skip  $f (pgvector not installed)"; continue
    fi
    "${PSQL[@]}" -f "$f" >/dev/null || { echo "SETUP FAILED in $f"; exit 2; }
done
"${PSQL[@]}" -f tests/_helpers.sql >/dev/null || { echo "SETUP FAILED in helpers"; exit 2; }

pass=0; fail=0
for t in tests/t[0-9]*.sql; do
    [[ -n "$PATTERN" && "$t" != *"$PATTERN"* ]] && continue
    if out=$("${PSQL[@]}" -f "$t" 2>&1); then
        echo "PASS  $t"; pass=$((pass+1))
    else
        echo "FAIL  $t"; echo "$out" | grep -E "ERROR|FAIL" | sed 's/^/        /'; fail=$((fail+1))
    fi
done
echo "---- $pass passed, $fail failed"
[[ $fail -eq 0 ]]
