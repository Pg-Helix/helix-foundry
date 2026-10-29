# Workflow 2 (ADR-0007) ingestion/retrieval HTTP API image. Build context
# is a helix-cortex checkout (see compose/docker-compose.yml), same as
# images/cortex/Dockerfile's worker build -- a separate binary, same repo.
FROM golang:1.26 AS builder
WORKDIR /build
COPY . .
RUN CGO_ENABLED=0 go build -o /cortex-api ./cmd/cortex-api

FROM gcr.io/distroless/static-debian12
COPY --from=builder /cortex-api /cortex-api
ENTRYPOINT ["/cortex-api"]
