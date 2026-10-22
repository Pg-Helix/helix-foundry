# C1 worker image. Build context is a helix-cortex checkout (see
# compose/docker-compose.yml).
FROM golang:1.26 AS builder
WORKDIR /build
COPY . .
RUN CGO_ENABLED=0 go build -o /cortex ./cmd/cortex

FROM gcr.io/distroless/static-debian12
COPY --from=builder /cortex /cortex
ENTRYPOINT ["/cortex"]
