#!/bin/bash
set -e

echo "Creating fusionpbx database and user..."

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER fusionpbx WITH PASSWORD '${POSTGRES_PASSWORD}';
    CREATE DATABASE fusionpbx OWNER fusionpbx;
    GRANT ALL PRIVILEGES ON DATABASE fusionpbx TO fusionpbx;
EOSQL

echo "✅ fusionpbx database and user created."
