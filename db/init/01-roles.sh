#!/bin/bash
# Runs once, on first container start, before the database accepts connections.
#
# Creates the runtime role the application connects as. It is deliberately
# unprivileged: no SUPERUSER, no BYPASSRLS, no CREATEDB, no CREATEROLE. Row-level
# security policies therefore apply to it, which is the guarantee the whole
# multi-tenant design rests on. tests/tenant-isolation.test.ts asserts these
# attributes at runtime, so a misconfigured environment fails loudly.
#
# A shell script rather than plain SQL so the password comes from the
# environment. Shipping a hardcoded one would put the development password on
# every production host.
set -euo pipefail

APP_PASSWORD="${MINIHR_APP_PASSWORD:-minihr_dev_password}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	DO \$\$
	BEGIN
	  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'minihr_app') THEN
	    CREATE ROLE minihr_app WITH LOGIN PASSWORD '${APP_PASSWORD}'
	      NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
	  ELSE
	    ALTER ROLE minihr_app WITH PASSWORD '${APP_PASSWORD}';
	  END IF;
	END
	\$\$;

	-- The database name differs between the dev, test and production stacks.
	DO \$\$
	BEGIN
	  EXECUTE format('GRANT CONNECT ON DATABASE %I TO minihr_app', current_database());
	END
	\$\$;

	GRANT USAGE ON SCHEMA public TO minihr_app;

	-- DML only, never DDL. Applies to the tables the migrations create later.
	ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA public
	  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO minihr_app;
	ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA public
	  GRANT USAGE, SELECT ON SEQUENCES TO minihr_app;
EOSQL
