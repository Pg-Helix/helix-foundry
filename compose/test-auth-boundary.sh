#!/bin/sh
# Proves the stack's actual authentication/authorization boundary against
# a real client with the same network reachability a worker has -- not
# just that the YAML says scram-sha-256. Runs psql via `docker compose
# exec` into the postgres container itself, always connecting over TCP
# (-h 127.0.0.1, never the Unix socket) so it is subject to the exact
# same pg_hba `host ... scram-sha-256` rule the `worker` service's own
# TCP connection is -- not a host-installed psql client, which this
# workspace's host doesn't have, and not relying on the published port
# or any platform-specific container-to-host networking.
#
# Assumes the stack is already up (docker compose up --build -d) with
# compose/.env present. Exits nonzero on the first unmet expectation.
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$DIR/.env"
COMPOSE="docker compose -f $DIR/docker-compose.yml"

fail=0

psql_as() {
    user=$1 password=$2; shift 2
    $COMPOSE exec -T -e PGPASSWORD="$password" postgres \
        psql -X -q -h 127.0.0.1 -U "$user" -d postgres -v ON_ERROR_STOP=1 "$@"
}

expect_fail() {
    label=$1; shift
    if "$@" >/tmp/auth_boundary_out.log 2>&1; then
        echo "FAIL: $label (expected to fail, succeeded)"
        cat /tmp/auth_boundary_out.log
        fail=1
    else
        echo "ok: $label"
    fi
}

expect_ok() {
    label=$1; shift
    if "$@" >/tmp/auth_boundary_out.log 2>&1; then
        echo "ok: $label"
    else
        echo "FAIL: $label (expected to succeed, failed)"
        cat /tmp/auth_boundary_out.log
        fail=1
    fi
}

# --- Wrong/missing credentials fail ---
expect_fail "wrong admin password rejected" psql_as postgres "deliberately-wrong" -c "SELECT 1"
expect_fail "wrong worker password rejected" psql_as helix_worker "deliberately-wrong" -c "SELECT 1"
expect_fail "wrong app password rejected" psql_as helix_app "deliberately-wrong" -c "SELECT 1"
expect_fail "wrong cortex_api password rejected" psql_as helix_cortex_api "deliberately-wrong" -c "SELECT 1"
expect_fail "missing password rejected" $COMPOSE exec -T postgres psql -X -q -h 127.0.0.1 -U helix_worker -d postgres -c "SELECT 1"

# --- Correct credentials work ---
expect_ok "correct admin password accepted" psql_as postgres "$HELIX_ADMIN_PASSWORD" -c "SELECT 1"
expect_ok "correct worker password accepted" psql_as helix_worker "$HELIX_WORKER_PASSWORD" -c "SELECT 1"
expect_ok "correct app password accepted" psql_as helix_app "$HELIX_APP_PASSWORD" -c "SELECT 1"
expect_ok "correct cortex_api password accepted" psql_as helix_cortex_api "$HELIX_CORTEX_API_PASSWORD" -c "SELECT 1"

# --- The worker, authenticated correctly, still cannot escalate ---
expect_fail "worker cannot SET ROLE helix_app" psql_as helix_worker "$HELIX_WORKER_PASSWORD" -c "SET ROLE helix_app"
expect_fail "worker cannot SET ROLE helix_owner" psql_as helix_worker "$HELIX_WORKER_PASSWORD" -c "SET ROLE helix_owner"
expect_fail "worker cannot SET ROLE helix_cortex_api" psql_as helix_worker "$HELIX_WORKER_PASSWORD" -c "SET ROLE helix_cortex_api"
expect_fail "worker cannot read helix_ai.source directly" psql_as helix_worker "$HELIX_WORKER_PASSWORD" -c "SELECT * FROM helix_ai.source"
expect_fail "worker cannot read helix_ai.derived_value directly" psql_as helix_worker "$HELIX_WORKER_PASSWORD" -c "SELECT * FROM helix_ai.derived_value"

# --- cortex_api (ADR-0007) can read helix_ai for retrieval but holds
# none of the worker's publish-side privileges -- the two processes'
# credentials must not overlap in either direction. ---
expect_fail "cortex_api cannot SET ROLE helix_worker" psql_as helix_cortex_api "$HELIX_CORTEX_API_PASSWORD" -c "SET ROLE helix_worker"
expect_fail "cortex_api cannot SET ROLE helix_owner" psql_as helix_cortex_api "$HELIX_CORTEX_API_PASSWORD" -c "SET ROLE helix_owner"
expect_fail "cortex_api cannot call claim_job" psql_as helix_cortex_api "$HELIX_CORTEX_API_PASSWORD" -c "SELECT helix_ai.claim_job('no-such-model')"
expect_fail "cortex_api cannot call publish_result" psql_as helix_cortex_api "$HELIX_CORTEX_API_PASSWORD" -c "SELECT helix_ai.publish_result('00000000-0000-0000-0000-000000000000'::uuid, 1, 'x', 'x', 'x', '{}'::jsonb)"
expect_fail "cortex_api cannot call get_job_input" psql_as helix_cortex_api "$HELIX_CORTEX_API_PASSWORD" -c "SELECT helix_ai.get_job_input('00000000-0000-0000-0000-000000000000'::uuid, 1)"
expect_ok "cortex_api can read helix_ai.status" psql_as helix_cortex_api "$HELIX_CORTEX_API_PASSWORD" -c "SELECT * FROM helix_ai.status LIMIT 0"

# --- A throwaway application table proves the worker has zero
# application-table privilege, not just zero helix_ai privilege. ---
psql_as helix_app "$HELIX_APP_PASSWORD" -c "DROP TABLE IF EXISTS public.auth_boundary_probe" >/dev/null
psql_as helix_app "$HELIX_APP_PASSWORD" -c "CREATE TABLE public.auth_boundary_probe (id int PRIMARY KEY, body text)"
psql_as helix_app "$HELIX_APP_PASSWORD" -c "INSERT INTO public.auth_boundary_probe VALUES (1, 'secret')"
expect_fail "worker cannot read an application table" psql_as helix_worker "$HELIX_WORKER_PASSWORD" -c "SELECT * FROM public.auth_boundary_probe"
expect_fail "worker cannot mutate an application table" psql_as helix_worker "$HELIX_WORKER_PASSWORD" -c "UPDATE public.auth_boundary_probe SET body = 'tampered'"
psql_as helix_app "$HELIX_APP_PASSWORD" -c "DROP TABLE public.auth_boundary_probe" >/dev/null

exit $fail
