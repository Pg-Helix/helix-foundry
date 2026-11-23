#!/bin/sh
# Phase 1 local-stack credential separation (RFC-0005, ADR-0006). A
# shell script, not a plain .sql file: docker-entrypoint-initdb.d runs
# executable .sh scripts with the container's environment available, so
# HELIX_WORKER_PASSWORD/HELIX_APP_PASSWORD (set via Compose from the
# gitignored .env -- see generate-env.sh, never hardcoded or committed)
# can be substituted into the role-creation statements. Six roles, six
# separate credentials (five LOGIN, one NOLOGIN), exactly RFC-0005's point:
#   helix_owner        NOLOGIN, kernel extension owner -- never held by a
#                      running process.
#   helix_worker       the narrow worker role -- held only by the `worker`
#                      service.
#   helix_app          seeds/reads demo data -- held only by the demo
#                      script, never by `worker`.
#   helix_cortex_owner NOLOGIN, cortex schema owner -- never held by a
#                      running process either; cortex's own migrations
#                      (helix-cortex/migrations/migrate.sh) apply as this
#                      role via SET ROLE from a trusted connection, not a
#                      standing credential.
#   helix_cortex_api   serves the HTTP ingestion/retrieval API (ADR-0007,
#                      Workflow 2) with ordinary DML + the specific TRIGGER
#                      grant register_source's caller-privilege check
#                      needs -- never ownership, never
#                      claim_job/publish_result/get_job_input, same
#                      privilege boundary RFC-0003 draws for the embedding
#                      worker itself.
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
-- Two DISTINCT cortex credentials, not one (handoff review 2026-10-30,
-- finding #9): helix_cortex_owner owns the cortex schema/tables outright
-- and is who migrations run as (migrations/migrate.sh, via SET ROLE);
-- helix_cortex_api is the credential the running HTTP service actually
-- holds, with only the specific DML/trigger privileges it needs (below)
-- -- never ownership. helix_cortex_api is also never made a MEMBER of
-- helix_cortex_owner, so it cannot SET ROLE into it: a compromised or
-- buggy running process cannot ALTER TABLE/DROP POLICY/disable RLS on
-- its own schema, which plain NOSUPERUSER/NOBYPASSRLS alone would not
-- have prevented while it was still the schema's owner.
CREATE ROLE helix_cortex_owner NOLOGIN NOSUPERUSER NOBYPASSRLS;
CREATE ROLE helix_cortex_api LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '$HELIX_CORTEX_API_PASSWORD';

CREATE EXTENSION helix;
-- pgvector (ADR-0007, Workflow 2 C3): created once, database-wide; the
-- vector type and its distance operators are then usable by any role
-- without a further per-role grant, same as any other built-in type.
CREATE EXTENSION vector;
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
-- Same requirement, for cortex.chunk (ADR-0007), now created by
-- helix_cortex_owner (migrations/migrate.sh), not helix_cortex_api:
-- register_source's _ensure_capture_trigger runs as helix_owner and
-- needs TRIGGER on a table it doesn't own.
ALTER DEFAULT PRIVILEGES FOR ROLE helix_cortex_owner GRANT SELECT, TRIGGER ON TABLES TO helix_owner;
-- helix_cortex_api is the RUNTIME credential: ordinary DML plus TRIGGER
-- on every table helix_cortex_owner's migrations create from here on --
-- TRIGGER specifically because register_source's own caller-privilege
-- check (ADR-0006 decision 2) is against whichever role actually calls
-- it, which is helix_cortex_api itself (cortex-api's own request
-- handling), not helix_cortex_owner. Never CREATE: this role cannot add
-- or drop objects in its own schema.
ALTER DEFAULT PRIVILEGES FOR ROLE helix_cortex_owner GRANT SELECT, INSERT, UPDATE, DELETE, TRIGGER ON TABLES TO helix_cortex_api;

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

-- cortex's schema is owned by helix_cortex_owner, NOT by the runtime
-- helix_cortex_api credential (ADR-0007 decision/handoff review finding
-- #9, this milestone): migrations/migrate.sh applies cortex's own
-- schema DDL as helix_cortex_owner (via SET ROLE from a trusted
-- connection, never as a standing login credential the running service
-- holds). helix_cortex_api only gets USAGE on the schema plus the
-- specific DML/TRIGGER table grants above (ALTER DEFAULT PRIVILEGES) --
-- it reads helix_ai directly for dense retrieval (casting
-- derived_value's jsonb inline to pgvector's vector type, decision 4 --
-- never a persisted second copy of the embedding) and the known-
-- residual status-view grant gap this role closes narrowly rather than
-- widening PUBLIC. It never receives claim_job/publish_result/
-- get_job_input -- RunOnce's claim/embed/publish loop runs only in the
-- worker process, under helix_worker's own separate credential.
CREATE SCHEMA cortex AUTHORIZATION helix_cortex_owner;
GRANT USAGE ON SCHEMA cortex TO helix_cortex_api;
GRANT USAGE ON SCHEMA helix_ai TO helix_cortex_api;
GRANT SELECT ON helix_ai.source, helix_ai.derived_value, helix_ai.status TO helix_cortex_api;
-- register_source's _create_enriched_view runs as helix_owner and
-- creates cortex.chunk_ai IN the cortex schema -- caught by actually
-- registering cortex.chunk end to end, not just reading the grants:
-- table-level SELECT/TRIGGER (above) is not schema-level USAGE/CREATE.
GRANT USAGE, CREATE ON SCHEMA cortex TO helix_owner;
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
