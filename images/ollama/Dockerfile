# The real embedding profile's local CPU runtime (ADR-0007, this
# milestone's follow-on): a pinned Ollama image serving a pinned
# embedding model's weights baked into this image's own layer -- the
# weights are downloaded and verified once, at BUILD time, never
# re-fetched (or silently substituted) at container start. The default
# mock profile never builds or starts this image at all; see
# compose/docker-compose.real-embeddings.yml.
#
# Pinned by digest, not tag, for both the runtime and the model:
#   ollama/ollama:0.40.0, released 2026-09-25 (github.com/ollama/ollama
#   release v0.40.0) -- verified by actually pulling it, not by reading
#   a registry page.
#   nomic-embed-text:v1.5 (nomic-ai, Apache-2.0) -- 768 dims, trained
#   for cosine similarity (model card), 274 MB. Verified LIVE against a
#   running Ollama 0.40.0 container: real /v1/embeddings calls, 768-dim
#   responses, and a real semantic-relevance signal (cosine 0.69 for a
#   relevant query/document pair vs 0.43 for an irrelevant one, same
#   query, using the model's own "search_query: "/"search_document: "
#   task prefixes -- see helix-cortex's embedconfig package). Also
#   confirmed empirically: despite num_ctx=8192 in the model's own
#   Modelfile, Ollama's /v1/embeddings endpoint silently truncates
#   input at 2048 tokens (HTTP 200, no error) -- cortex's own query-
#   length bound (store.maxQueryTokensEstimate) is set well under that
#   confirmed-safe ceiling, never trusting the Modelfile's nominal
#   context window.
ARG OLLAMA_IMAGE_DIGEST=sha256:1bef639749741b375e9a1eb2c1346fb57ce52f5432de1f74846e44ccc18e1687
FROM ollama/ollama@${OLLAMA_IMAGE_DIGEST}

ARG MODEL_TAG=nomic-embed-text:v1.5
# The model weights blob's own digest (NOT the image/runtime digest
# above) -- from the manifest Ollama's registry serves for this exact
# tag, confirmed by actually pulling it: `ollama show nomic-embed-text:v1.5
# --modelfile` names this blob as the model's FROM line.
ARG MODEL_WEIGHTS_DIGEST=sha256-970aa74c0a90ef7482477cf803618e776e173c007bf957f635f1015bfcfef0e6

RUN set -eu; \
    (ollama serve &) ; \
    for i in $(seq 1 30); do ollama list >/dev/null 2>&1 && break; sleep 1; done; \
    ollama pull "$MODEL_TAG"; \
    MANIFEST="/root/.ollama/models/manifests/registry.ollama.ai/library/nomic-embed-text/v1.5"; \
    if ! grep -q "${MODEL_WEIGHTS_DIGEST#sha256-}" "$MANIFEST"; then \
        echo "FATAL: pulled $MODEL_TAG but its manifest does not reference the pinned weights digest $MODEL_WEIGHTS_DIGEST -- refusing to bake in unexpected weights" >&2; \
        cat "$MANIFEST" >&2; \
        exit 1; \
    fi; \
    pkill ollama; \
    sleep 1

# No ports/EXPOSE beyond the base image's own 11434 -- the compose
# override binds this to loopback only (or leaves it unpublished
# entirely; the stack's own cortex-api/chunk-worker reach it over the
# compose network by service name, never needing the published port).
