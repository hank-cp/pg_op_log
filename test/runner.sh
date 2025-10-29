#!/bin/bash

set -e

HOST="localhost"
PORT="5432"
USER="postgres"
PASSWORD=""
CLEANUP="true"

while [[ $# -gt 0 ]]; do
    case $1 in
        --host)
            HOST="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --user)
            USER="$2"
            shift 2
            ;;
        --password)
            PASSWORD="$2"
            shift 2
            ;;
        --no-cleanup)
            CLEANUP="false"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--host HOST] [--port PORT] [--user USER] [--password PASSWORD] [--no-cleanup]"
            exit 1
            ;;
    esac
done

PGPASSWORD_VAR=""
if [ -n "$PASSWORD" ]; then
    export PGPASSWORD="$PASSWORD"
    PGPASSWORD_VAR="PGPASSWORD=$PASSWORD"
fi

PSQL_CMD="psql -h $HOST -p $PORT -U $USER"

TEST_DB="pg_op_log_test_$(date +%s)_$RANDOM"

echo "=== Building and installing extension ==="
if ! command -v pg_config &> /dev/null; then
    if [ -f "/Applications/Postgres.app/Contents/Versions/latest/bin/pg_config" ]; then
        export PATH="/Applications/Postgres.app/Contents/Versions/latest/bin:$PATH"
    fi
fi
make install

echo ""
echo "=== Creating test database: $TEST_DB ==="
$PSQL_CMD -d postgres -c "CREATE DATABASE $TEST_DB;"

cleanup() {
    if [ "$CLEANUP" = "true" ]; then
        echo ""
        echo "=== Cleaning up test database: $TEST_DB ==="
        $PSQL_CMD -d postgres -c "DROP DATABASE IF EXISTS $TEST_DB;" || true
    else
        echo ""
        echo "=== Keeping test database: $TEST_DB ==="
    fi
}

trap cleanup EXIT

echo ""
echo "=== Running tests ==="
TEST_OUTPUT=$($PSQL_CMD -d $TEST_DB -f "$(dirname "$0")/pgtap_test.sql" 2>&1)
TEST_EXIT_CODE=$?

echo "$TEST_OUTPUT"

if echo "$TEST_OUTPUT" | grep -q "Looks like you failed"; then
    echo ""
    echo "=== Tests FAILED ==="
    exit 1
fi

if [ $TEST_EXIT_CODE -ne 0 ]; then
    echo ""
    echo "=== Test execution failed with exit code $TEST_EXIT_CODE ==="
    exit $TEST_EXIT_CODE
fi

echo ""
echo "=== Test completed successfully ==="
