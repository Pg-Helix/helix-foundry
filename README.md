# helix-foundry

Container images, Compose, Helm, IaC, compatibility and platform release manifests.

| | |
|---|---|
| Ownership group | Infrastructure and Reliability |
| Primary form | IaC / tooling |
| Visibility | PUBLIC |
| Status | **Phase 1 local stack only.** `compose/` brings up PostgreSQL (with the helix-kernel extension built in) and the C1 cortex worker, with real SCRAM authentication and four separated credentials (ADR-0006, RFC-0005) -- not a trust-auth demo. Image build/Helm/release-manifest work beyond this is still design only. |

Design source of truth: the private `helix-atlas` repository (`architecture/repos/helix-foundry.md`).
Organization master prompt: PgHelix Organization Master Prompt, 16 Oct 2026.

## The local stack (`compose/`)

```
cd compose
./generate-env.sh          # writes .env with fresh random local credentials (gitignored, never commit it)
docker compose up --build -d
./test-auth-boundary.sh    # proves wrong/missing creds fail, the worker can't escalate or read application tables
```

Four separate credentials, enforced by real `scram-sha-256` auth (not
`trust`): `helix_owner` (NOLOGIN, schema owner, never held by a running
process), `helix_worker` (held only by the `worker` service -- no
application-table privilege), `helix_app` (seeds/reads demo data, held
only by whatever drives a demo, never by `worker`), and the bootstrap
admin credential (`postgres`, used only by `compose/initdb/01-install.sh`
at container startup). See `compose/initdb/01-install.sh` for exactly
what each role can and can't do, and `helix-kernel/sql/post_install_ownership.sql`
(COPYed into the image) for the ownership-hardening step that makes
`FORCE ROW LEVEL SECURITY` actually bind.

The full acceptance gate (register/update/delete/crash/duplicate-
delivery/cross-tenant scenarios) lives in `helix-labs/workflow-1/acceptance.sh`,
which drives this stack.

## Build and test

`docker compose -f compose/docker-compose.yml config` validates the
Compose file; `compose/test-auth-boundary.sh` is this repo's own test
(see above). Image build/Helm/release-manifest tooling beyond the local
stack is not yet implemented.

## License

Not yet decided. The license is an ADR in `helix-atlas`; until it is accepted, no license is granted and all rights are reserved.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
