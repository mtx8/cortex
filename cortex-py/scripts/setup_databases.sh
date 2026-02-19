#!/bin/bash
set -e

echo "=== CORTEX Database Setup ==="

# PostgreSQL
echo "[1/3] Setting up PostgreSQL..."
createdb cortex 2>/dev/null || echo "Database 'cortex' already exists"
psql -d cortex -f cortex/storage/postgres_schema.sql
echo "PostgreSQL: OK"

# QuestDB (assumes QuestDB running on port 9000)
echo "[2/3] Setting up QuestDB..."
while IFS= read -r line; do
    if [ -n "$line" ] && [[ ! "$line" =~ ^-- ]]; then
        curl -s -G "http://localhost:9000/exec" --data-urlencode "query=$line" > /dev/null
    fi
done < cortex/storage/questdb_schema.sql
echo "QuestDB: OK"

# Redis (just verify connection)
echo "[3/3] Verifying Redis..."
redis-cli ping | grep -q PONG && echo "Redis: OK" || echo "Redis: FAILED - is redis-server running?"

echo "=== Setup Complete ==="
