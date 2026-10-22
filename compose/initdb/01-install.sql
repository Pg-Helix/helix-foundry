-- Phase 1 local-stack credential separation (RFC-0005, ADR-0006). Demo
-- passwords only -- never reuse these outside a throwaway local Compose
-- stack. Four roles, four separate credentials, exactly RFC-0005's point:
--   helix_owner   NOLOGIN, schema owner -- never held by a running process.
--   helix_worker  the narrow worker role -- held only by the `worker` service.
--   helix_app     seeds/reads demo data -- held only by the demo script,
--                 never by `worker`.
-- (A read-only role for `command`/doctor is not created here: this slice
-- keeps the CLI's existing TCP/config-only doctor unchanged, per the
-- governance note deferring that to a later milestone.)
CREATE ROLE helix_owner NOLOGIN NOSUPERUSER NOBYPASSRLS;
CREATE ROLE helix_worker LOGIN PASSWORD 'demo-worker-only-not-for-prod';
CREATE ROLE helix_app LOGIN PASSWORD 'demo-app-only-not-for-prod';

CREATE EXTENSION helix;

ALTER SCHEMA helix_ai OWNER TO helix_owner;
ALTER TABLE helix_ai.source OWNER TO helix_owner;
ALTER TABLE helix_ai.derived_value OWNER TO helix_owner;
ALTER TYPE helix_ai.pseudo_column_status OWNER TO helix_owner;
ALTER VIEW helix_ai.status OWNER TO helix_owner;
ALTER FUNCTION helix_ai.version() OWNER TO helix_owner;
ALTER FUNCTION helix_ai._source_key_expr(name[], name) OWNER TO helix_owner;
ALTER FUNCTION helix_ai._create_enriched_view(bigint) OWNER TO helix_owner;
ALTER FUNCTION helix_ai.register_source(name, name, text, text, text, integer, text) OWNER TO helix_owner;
ALTER TABLE helix_ai.job OWNER TO helix_owner;
ALTER TYPE helix_ai.publish_outcome OWNER TO helix_owner;
ALTER FUNCTION helix_ai._row_key_jsonb(name[], record) OWNER TO helix_owner;
ALTER FUNCTION helix_ai._tombstone_key(bigint, text, jsonb) OWNER TO helix_owner;
ALTER FUNCTION helix_ai._capture_change() OWNER TO helix_owner;
ALTER FUNCTION helix_ai._ensure_capture_trigger(name, name) OWNER TO helix_owner;
ALTER FUNCTION helix_ai.request_refresh(bigint, jsonb) OWNER TO helix_owner;
ALTER FUNCTION helix_ai.claim_job(text, integer, integer) OWNER TO helix_owner;
ALTER FUNCTION helix_ai.publish_result(uuid, integer, text, text, text, jsonb) OWNER TO helix_owner;
ALTER FUNCTION helix_ai.get_job_input(uuid, integer) OWNER TO helix_owner;

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
GRANT SELECT ON helix_ai.source, helix_ai.derived_value TO helix_app;

GRANT USAGE ON SCHEMA helix_ai TO helix_worker;
GRANT EXECUTE ON FUNCTION helix_ai.claim_job(text, integer, integer) TO helix_worker;
GRANT EXECUTE ON FUNCTION helix_ai.publish_result(uuid, integer, text, text, text, jsonb) TO helix_worker;
GRANT EXECUTE ON FUNCTION helix_ai.get_job_input(uuid, integer) TO helix_worker;
