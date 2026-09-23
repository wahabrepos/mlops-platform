# Multi-stage: the Go toolchain is ~800MB and has no business in a running
# container. Only the compiled binary crosses the stage boundary.
FROM golang:1.27-alpine AS build

WORKDIR /src

# go.mod first, as its own layer. Dependencies change far less often than
# source, so this layer stays cached across ordinary code edits.
COPY go.mod ./
RUN go mod download

COPY . .

ARG VERSION=dev
# CGO_ENABLED=0 produces a static binary with no libc dependency, which is
# what makes a minimal runtime image possible at all.
RUN CGO_ENABLED=0 go build \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/dataset-api ./services/dataset-api/cmd/api

FROM alpine:3.20

# ca-certificates for outbound TLS; wget is here solely for HEALTHCHECK.
RUN apk add --no-cache ca-certificates wget \
 && adduser -D -u 65532 app \
 && mkdir -p /data && chown app:app /data

COPY --from=build /out/dataset-api /usr/local/bin/dataset-api

# Running as root in a container buys nothing and costs a finding in any
# security review. /data is pre-created owned by this uid so that a mounted
# named volume inherits writable ownership rather than root's.
USER app
VOLUME ["/data"]
EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=5 \
  CMD wget -qO- http://localhost:8080/healthz >/dev/null 2>&1 || exit 1

ENTRYPOINT ["dataset-api"]
