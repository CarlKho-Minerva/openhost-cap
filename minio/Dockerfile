# syntax=docker.io/docker/dockerfile:1
#
# MinIO server, built from source at a pinned release. MinIO stopped publishing
# public images (quay.io and Docker Hub both answer 401 since 2026-10), and
# dl.min.io returns 410 for archived binaries, so the wrapper can no longer pull
# a prebuilt MinIO. Same release the zone has run since 2026-09-15.
#
# Cross-compiled on the build platform (CGO off), so arm64 needs no emulation.

FROM --platform=$BUILDPLATFORM docker.io/library/golang@sha256:1a6d4452c65dea36aac2e2d606b01b4a029ec90cc1ae53890540ce6173ea77ac AS build
ARG MINIO_TAG=RELEASE.2025-09-07T16-13-09Z
ARG MINIO_COMMIT=07c3a429bfed433e49018cb0f78a52145d4bedeb
ARG TARGETOS
ARG TARGETARCH
ENV GOTOOLCHAIN=auto
RUN git clone --filter=blob:none --branch "$MINIO_TAG" https://github.com/minio/minio /src \
 && cd /src \
 && test "$(git rev-parse HEAD)" = "$MINIO_COMMIT"
WORKDIR /src
# gen-ldflags wants the release time in UTC; this reproduces the official
# "RELEASE.2025-09-07T16-13-09Z" version string.
ARG MINIO_RELEASE_TIME=2025-09-07T16:13:09Z
RUN ldflags="$(go run buildscripts/gen-ldflags.go "$MINIO_RELEASE_TIME")" \
 && CGO_ENABLED=0 GOOS="$TARGETOS" GOARCH="$TARGETARCH" \
    go build -tags kqueue -trimpath -ldflags "$ldflags" -o /out/minio .

FROM scratch
COPY --from=build /out/minio /usr/bin/minio
ENTRYPOINT ["/usr/bin/minio"]
