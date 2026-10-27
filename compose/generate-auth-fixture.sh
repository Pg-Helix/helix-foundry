#!/bin/sh
# Generates compose/auth-fixture.json: the local-only, opaque-token ->
# (principal, tenant) mapping cortex-api authenticates against when
# CORTEX_AUTH_PROFILE=local-fixture (ADR-0007 decision 1, helix-atlas).
# Never committed (see .gitignore). Safe to re-run: leaves an existing
# file alone unless --force is passed, same convention as generate-env.sh.
#
# At least two principals share one tenant and one principal sits in a
# second tenant -- the minimum the Workflow 2 acceptance suite needs to
# exercise same-tenant-denied vs cross-tenant-denied vs positive-control
# access, without the suite itself inventing tokens the service was
# never told about.
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FIXTURE_FILE="$DIR/auth-fixture.json"

if [ -f "$FIXTURE_FILE" ] && [ "${1:-}" != "--force" ]; then
    echo "generate-auth-fixture.sh: $FIXTURE_FILE already exists (use --force to regenerate)" >&2
    exit 0
fi

random_token() {
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
}

TOKEN_ALICE=$(random_token)
TOKEN_BOB=$(random_token)
TOKEN_CAROL=$(random_token)

cat > "$FIXTURE_FILE" <<EOF
{
  "$TOKEN_ALICE": {"principal": "alice", "tenant": "acme"},
  "$TOKEN_BOB": {"principal": "bob", "tenant": "acme"},
  "$TOKEN_CAROL": {"principal": "carol", "tenant": "globex"}
}
EOF
chmod 600 "$FIXTURE_FILE"
echo "generate-auth-fixture.sh: wrote $FIXTURE_FILE"
