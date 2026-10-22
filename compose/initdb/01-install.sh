#!/bin/sh
# Phase 1 local-stack credential separation (RFC-0005, ADR-0006). A
# shell script, not a plain .sql file: docker-entrypoint-initdb.d runs
# executable .sh scripts with the container's environment available, so
# HELIX_WORKER_PASSWORD/HELIX_APP_PASSWORD (set via Compose from the
# gitignored .env -- see generate-env.sh, never hardcoded or committed)
# can be substituted into the role-creation statements. Four roles, four
# separate credentials, exactly RFC-0005's point:
#   helix_owner   NOLOGIN, schema owner -- never held by a running process.
#   helix_worker  the narrow worker role -- held only by the `worker` service.
#   helix_app     seeds/reads demo data -- held only by the demo script,
#                 never by `worker`.
# (A read-only role for `command`/doctor is not created here: this slice
# keeps the CLI's existing TCP/config-only doctor unchanged, per the
# governance note deferring that to a later milestone.)
#
# Never echoes a password: `set -x` is not on, and nothing below prints
# $HELIX_WORKER_PASSWORD/$HELIX_APP_PASSWORD -- they only ever appear
# inside the heredoc text piped to psql's stdin, not in any logged
# command line.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
CREATE ROLE helix_owner NOLOGIN NOSUPERUSER NOBYPASSRLS;
CREATE ROLE helix_worker LOGIN PASSWORD '$HELIX_WORKER_PASSWORD';
CREATE ROLE helix_app LOGIN PASSWORD '$HELIX_APP_PASSWORD';

CREATE EXTENSION helix;
EOSQL

# Single canonical ownership-reassignment script (not a copy of the same
# object list kernel's own test fixtures maintain) -- COPYed into this
# image by images/kernel/Dockerfile from the same helix-kernel checkout.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /post_install_ownership.sql

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'EOSQL'
GRANT CREATE ON SCHEMA public TO helix_owner;
-- FOR ROLE helix_app, not the current (postgres) role: helix_app is who
-- actually creates demo tables in this stack, and ALTER DEFAULT
-- PRIVILEGES with no FOR ROLE only covers tables created by whichever
-- role ran this statement -- a gap this exact demo caught the first time
-- it was run end to end (kernel's own pg_regress tests don't catch it
-- since every test table there is created by the same role that ran this
-- statement).
ALTER DEFAULT PRIVILEGES FOR ROLE helix_app GRANT SELECT, TRIGGER ON TABLES TO helix_owner;

-- helix_app registers/seeds demo tables; it needs ordinary CREATE/INSERT
-- on public like any application role would. It also reads its own
-- enriched view/status directly (K2's intended read path -- "a plain
-- SELECT against the resulting enriched view reads the stored sidecar
-- value"), which needs SELECT on the two helix_ai tables the
-- security_invoker view/enriched-view join against; RLS still scopes
-- every row to whatever tenant helix_app's session sets.
GRANT CREATE ON SCHEMA public TO helix_app;
GRANT USAGE ON SCHEMA helix_ai TO helix_app;
GRANT SELECT ON helix_ai.source, helix_ai.derived_value, helix_ai.status TO helix_app;

GRANT USAGE ON SCHEMA helix_ai TO helix_worker;
GRANT EXECUTE ON FUNCTION helix_ai.claim_job(text, integer, integer) TO helix_worker;
GRANT EXECUTE ON FUNCTION helix_ai.publish_result(uuid, integer, text, text, text, jsonb) TO helix_worker;
GRANT EXECUTE ON FUNCTION helix_ai.get_job_input(uuid, integer) TO helix_worker;
EOSQL

# POSTGRES_HOST_AUTH_METHOD=scram-sha-256 is not enough on its own: the
# official postgres image's entrypoint ALWAYS additionally writes
# `host all all 127.0.0.1/32 trust` and the ::1/128 equivalent ahead of
# the scram rule it adds for `all` -- pg_hba rules are first-match-wins,
# so any TCP connection via loopback still hits trust before ever
# reaching scram, auth method setting notwithstanding. Overwriting
# pg_hba.conf here (the same technique the handoff review's own
# reproduction used to confirm this) closes it: no unconditional trust
# rule survives for any address, local Unix-socket connections excepted
# (those require OS-level access to this container already).
cat > "$PGDATA/pg_hba.conf" <<-EOF
local   all             all                                     trust
host    all             all             all                     scram-sha-256
EOF
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -c "SELECT pg_reload_conf()" >/dev/null
