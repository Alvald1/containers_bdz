#!/bin/bash
set +x
set -euo pipefail

if [ "$#" -ne 1 ]; then
    printf '%s\n' 'Patroni must supply the PostgreSQL connection string.' >&2
    exit 1
fi

gitlab_password=$(cat /run/secrets/gitlab_db_password)
case "$gitlab_password" in
    ''|*[!a-zA-Z0-9]*)
        printf '%s\n' 'gitlab_db_password must contain only alphanumeric characters.' >&2
        exit 1
        ;;
esac

# Patroni supplies a password-free connection string, a tmpfs PGPASSFILE and
# synchronous_commit=local for bootstrap before the first replica is available.
# The GitLab password travels through stdin, never through argv or environment.
psql --no-psqlrc --no-password --quiet --set ON_ERROR_STOP=1 --dbname "$1" <<SQL
SET log_statement TO none;
SET log_min_duration_statement TO -1;
SET log_min_error_statement TO panic;
SET password_encryption TO 'scram-sha-256';

SELECT 'CREATE ROLE gitlab LOGIN'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'gitlab')
\gexec
ALTER ROLE gitlab WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
    PASSWORD '$gitlab_password';

SELECT 'CREATE DATABASE gitlabhq_production OWNER gitlab'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'gitlabhq_production')
\gexec
ALTER DATABASE gitlabhq_production OWNER TO gitlab;

\connect gitlabhq_production
CREATE EXTENSION IF NOT EXISTS amcheck;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS plpgsql;
SQL

unset gitlab_password
