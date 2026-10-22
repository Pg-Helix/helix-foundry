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
FROM postgres:${PG_MAJOR} AS builder
ARG PG_MAJOR
RUN apt-get update -qq && apt-get install -y -qq build-essential postgresql-server-dev-${PG_MAJOR} >/dev/null
WORKDIR /build
COPY . .
RUN make && make install

FROM postgres:${PG_MAJOR}
ARG PG_MAJOR
COPY --from=builder /usr/lib/postgresql/${PG_MAJOR}/lib/helix.so /usr/lib/postgresql/${PG_MAJOR}/lib/helix.so
COPY --from=builder /usr/share/postgresql/${PG_MAJOR}/extension/helix* /usr/share/postgresql/${PG_MAJOR}/extension/
# The single canonical ownership-reassignment script (ADR-0006 decision
# 1) -- this build context IS a helix-kernel checkout, so this is a
# same-repo COPY, not a cross-repo one. compose/initdb/01-install.sh
# runs it after CREATE EXTENSION, instead of this image or that script
# keeping its own separate copy of the same object list.
COPY sql/post_install_ownership.sql /post_install_ownership.sql
