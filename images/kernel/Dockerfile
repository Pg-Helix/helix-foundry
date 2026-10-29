# Phase 1 local-stack image (RFC-0005, helix-atlas): upstream PostgreSQL
# with the helix extension built and installed, not a source fork. Build
# context is a helix-kernel checkout (see compose/docker-compose.yml).
#
# Ownership hardening (ADR-0006) happens at container startup, not build
# time, via compose/initdb/*.sql bind-mounted at
# /docker-entrypoint-initdb.d (not COPYed here: Docker can't COPY from
# outside this image's build context, and those scripts are owned by
# helix-foundry's compose/, not this helix-kernel checkout) -- CREATE
# EXTENSION itself must still run once the cluster exists, which init
# scripts are the standard postgres-image hook for.
ARG PG_MAJOR=17
# pgvector pinned at an exact released tag (ADR-0007, Workflow 2 C3 dense
# retrieval) -- never `master`/`latest`, so this image is reproducible from
# this Dockerfile alone months later, not whatever pgvector happened to
# contain on build day.
ARG PGVECTOR_TAG=v0.8.0

FROM postgres:${PG_MAJOR} AS builder
ARG PG_MAJOR
RUN apt-get update -qq && apt-get install -y -qq build-essential postgresql-server-dev-${PG_MAJOR} git ca-certificates >/dev/null
WORKDIR /build
COPY . .
RUN make && make install

FROM postgres:${PG_MAJOR} AS pgvector-builder
ARG PG_MAJOR
ARG PGVECTOR_TAG
RUN apt-get update -qq && apt-get install -y -qq build-essential postgresql-server-dev-${PG_MAJOR} git ca-certificates >/dev/null
RUN git clone --branch "${PGVECTOR_TAG}" --depth 1 https://github.com/pgvector/pgvector.git /build-pgvector
WORKDIR /build-pgvector
# OPTFLAGS="" disables pgvector's default -march=native: a binary tuned
# to the exact build-time CPU can segfault under PostgreSQL's JIT (LLVM
# re-targets/inlines it) even on a nominally identical container image --
# reproduced locally (CREATE EXTENSION vector segfaulting the backend)
# and fixed by this exact documented pgvector workaround for container
# builds, not a version or platform problem.
RUN make OPTFLAGS="" && make OPTFLAGS="" install

FROM postgres:${PG_MAJOR}
ARG PG_MAJOR
COPY --from=builder /usr/lib/postgresql/${PG_MAJOR}/lib/helix.so /usr/lib/postgresql/${PG_MAJOR}/lib/helix.so
COPY --from=builder /usr/share/postgresql/${PG_MAJOR}/extension/helix* /usr/share/postgresql/${PG_MAJOR}/extension/
COPY --from=pgvector-builder /usr/lib/postgresql/${PG_MAJOR}/lib/vector.so /usr/lib/postgresql/${PG_MAJOR}/lib/vector.so
COPY --from=pgvector-builder /usr/share/postgresql/${PG_MAJOR}/extension/vector* /usr/share/postgresql/${PG_MAJOR}/extension/
# The single canonical ownership-reassignment script (ADR-0006 decision
# 1) -- this build context IS a helix-kernel checkout, so this is a
# same-repo COPY, not a cross-repo one. compose/initdb/01-install.sh
# runs it after CREATE EXTENSION, instead of this image or that script
# keeping its own separate copy of the same object list.
COPY sql/post_install_ownership.sql /post_install_ownership.sql
