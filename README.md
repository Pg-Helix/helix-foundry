# helix-foundry

Container images, Compose, Helm, IaC, compatibility and platform release manifests.

| | |
|---|---|
| Ownership group | Infrastructure and Reliability |
| Primary form | IaC / tooling |
| Visibility | PUBLIC |
| Status | **Local development stack.** `compose/` brings up PostgreSQL (helix-kernel + pgvector), the Workflow 1 `worker`, and Workflow 2's `cortex-api` and `chunk-worker`, with real SCRAM authentication and separated credentials (ADR-0006/0007, RFC-0005). Mock embeddings by default; `docker-compose.real-embeddings.yml` is an explicit opt-in overlay for a local Ollama/nomic-embed-text profile. Unmerged feature-branch stack -- see helix-labs `MANIFEST.md` for the tested commits. Image publishing/Helm/release manifests are still design only. |

Design source of truth: the private `helix-atlas` repository (`architecture/repos/helix-foundry.md`).
Organization master prompt: PgHelix Organization Master Prompt, 16 Oct 2026.

## The local stack (`compose/`)

```
cd compose
./generate-env.sh          # writes .env with fresh random local credentials (gitignored, never commit it)
docker compose up --build -d
./test-auth-boundary.sh    # proves wrong/missing creds fail, the worker can't escalate or read application tables
```

`cortex-api` needs helix-cortex's schema, which this stack does not apply
by itself. Apply it with helix-cortex's own runner over the bootstrap
admin connection; it `SET ROLE`s into `helix_cortex_owner` for the DDL.
Never use `helix_cortex_api` for this: that runtime role has no `CREATE`
on schema `cortex`, so the DDL fails with `permission denied for schema
cortex`. That role/credential mismatch caused helix-labs' Workflow 2 exit 3.

```
docker compose cp ../../helix-cortex/migrations postgres:/tmp/cortex-migrations
docker compose exec -T -e PGHOST=127.0.0.1 -e PGUSER=postgres -e PGPASSWORD="$HELIX_ADMIN_PASSWORD" \
    postgres sh /tmp/cortex-migrations/migrate.sh      # idempotent: a rerun applies nothing
```

The real local embedding profile is an overlay, never the default:
`docker compose -f docker-compose.yml -f docker-compose.real-embeddings.yml up --build -d`
(adds `ollama` with pinned nomic-embed-text:v1.5 weights, and repoints
`cortex-api` and `chunk-worker` at it). On hosts whose buildx uses Compose's
Bake path with the docker-container driver, set `COMPOSE_BAKE=false`.
Otherwise the out-of-context Dockerfiles under `images/` request
`fs.read` entitlements and the build stops.

Separate credentials, enforced by real `scram-sha-256` auth (not
`trust`): `helix_owner` (NOLOGIN, kernel schema owner, never held by a running
process), `helix_worker` (held only by the worker services -- no
application-table privilege), `helix_app` (seeds/reads demo data, held
only by whatever drives a demo, never by a worker), `helix_cortex_owner`
(NOLOGIN, owns schema `cortex`; migrations act as it via `SET ROLE`),
`helix_cortex_api` (the `cortex-api` runtime credential: DML and TRIGGER, no `CREATE`, not a
member of `helix_cortex_owner`), and the bootstrap admin credential
(`postgres`, for `compose/initdb/01-install.sh` and trusted setup such as
migrations). See `compose/initdb/01-install.sh` for exactly
what each role can and can't do, and `helix-kernel/sql/post_install_ownership.sql`
(COPYed into the image) for the ownership-hardening step that makes
`FORCE ROW LEVEL SECURITY` actually bind.

The acceptance gates that drive this stack live in helix-labs:
`workflow-1/acceptance.sh`, `workflow-2/acceptance.sh`,
`workflow-2/version-change.sh` and `eval/run-eval.sh`. Their shared helper
`workflow-2/lib.sh` applies the migration step above and verifies it.

## Build and test

`docker compose -f compose/docker-compose.yml config` validates the
Compose file; `compose/test-auth-boundary.sh` is this repo's own test
(see above). Image build/Helm/release-manifest tooling beyond the local
stack is not yet implemented.

## License

Not yet decided. The license is an ADR in `helix-atlas`; until it is accepted, no license is granted and all rights are reserved.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
