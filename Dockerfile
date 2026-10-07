# syntax=docker.io/docker/dockerfile:1
#
# Self-contained OpenHost packaging of Cap (https://github.com/CapSoftware/cap).
# Runs the whole open-source Loom as ONE rootless container: Cap's web app +
# bundled MySQL 8 + MinIO (S3 API) + a Caddy front-proxy, all data on the
# instance's persistent disk. Nothing leaves the box.
#
# Cap officially requires MySQL 8 — its migrations use JSON-function GENERATED
# columns that MariaDB rejects — so we run on a glibc base (Ubuntu) with real
# mysql-server, and reuse Cap's prebuilt (pure-JS) web app artifacts rather than
# rebuilding the monorepo from source.

# --- Cap web app: OUR fork's build (CarlKho-Minerva/cap @ carl/selfhost-2026-10) ---
# Built natively (amd64+arm64) by the fork's "Docker Build Web" GitHub Action from
# apps/web/Dockerfile and pushed to ghcr. Differs from upstream CapSoftware/cap only
# by the OpenHost self-host changes: trusted-proxy SSO auto-login (no email code) and
# the "Cap Pro" upsell hidden off Cap Cloud (NEXT_PUBLIC_IS_CAP unset at build).
# Pinned by the multi-arch index digest so a redeploy can't silently change Cap or
# re-run migrations. To update: re-run the Action, then bump this digest deliberately.
FROM ghcr.io/carlkho-minerva/cap-web@sha256:106c9175ae41fa469cd822fc5a5c393ad020f16c7f1b4f6ed232cdb3f553bbb8 AS capweb

# --- Cap's official media-server (Bun + FFmpeg): transcoding, HLS, thumbnails, Loom import ---
# Pinned to the digest that was `:latest` as of 2026-10-06 (built 2026-09-24; see cap-web note above).
FROM ghcr.io/capsoftware/cap-media-server@sha256:261ad94d600b9c71d6772b253e3ba056ed90dc81939c22e3b82cf227d7c7492f AS mediaserver

# --- MinIO, same release as before. dl.min.io started returning 410 Gone for archived
# binaries (2026-09-15), which broke every rebuild; quay.io still serves the image.
# 2026-10-06: quay.io and Docker Hub now answer 401 for MinIO, so the same release
# is built from GitHub source by .github/workflows/build-minio.yml (minio/Dockerfile).
FROM ghcr.io/carlkho-minerva/minio@sha256:efb107d60976e92a1d7d747da3b816208d2d26ece74276aa9c7a2f0c0a6c0f24 AS minio

# --- Caddy 2.8.4. Was a GitHub release tarball fetched at build time with no
# checksum. Same lesson dl.min.io taught: a release asset is a URL, and a URL can
# 404, move, or change. The official multi-arch image, pinned by index digest,
# carries the identical binary for the build architecture with no loose fetch.
FROM docker.io/library/caddy@sha256:226d1f059b75399fe19182893c7184591c07b97afc8dfcf44eeb80c9a77a530f AS caddy

# --- Node 24. Was `curl https://deb.nodesource.com/setup_24.x | bash -`: an
# unpinned shell script piped into root, then whatever 24.x NodeSource happened
# to be serving that day. The most rebuild-fragile step in this file. The
# official Node image, pinned by index digest, is the same upstream build and
# cannot drift. Bookworm glibc 2.36 binaries run on Ubuntu 24.04 (glibc 2.39);
# the direction that breaks is the other one.
FROM docker.io/library/node@sha256:2fe369e969550cde8e867afc3fe370b260140cab4a23d467074295b42163d553 AS node

# --- glibc runtime: MySQL 8 + Node 24 + MinIO + Caddy ---
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# MySQL 8 server/client (core packages avoid the systemd/postinst datadir dance),
# plus tools. mysql-server-core provides /usr/sbin/mysqld; mysql-common creates
# the `mysql` system user.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       mysql-server-core-8.0 mysql-client-core-8.0 mysql-common \
       ffmpeg ca-certificates curl xz-utils tar libstdc++6 \
    && id mysql >/dev/null 2>&1 || (groupadd -r mysql && useradd -r -g mysql -s /usr/sbin/nologin mysql) \
    && rm -rf /var/lib/apt/lists/*

# Node 24 + npm, copied from the pinned official image. /usr/local is effectively
# empty on the Ubuntu base, so this is a clean graft, and it lands before the
# single-binary copies below so nothing overwrites them.
COPY --from=node /usr/local /usr/local
RUN node --version && npm --version

# MinIO server (RELEASE.2025-09-07T16-13-09Z) + Caddy 2.8.4, both from pinned
# multi-arch images, so each copy is already the right architecture and no
# architecture case statement is needed.
COPY --from=minio /usr/bin/minio /usr/local/bin/minio
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
RUN minio --version && caddy version

# Cap's web app (standalone) lives at /app (server at /app/apps/web/server.js).
COPY --from=capweb /app /app

# Next's image optimizer needs a glibc-native sharp (the copied one is musl).
# Installed in its own prefix: running npm in /app prunes every package that
# Next's standalone output hoisted into /app/node_modules (including next itself,
# which is what broke the 2026-10-06 build). NEXT_SHARP_PATH points Next here.
RUN mkdir -p /opt/sharp && cd /opt/sharp \
    && npm install --no-audit --no-fund --no-save sharp@0.34.5 \
    && node -e "require('/opt/sharp/node_modules/sharp'); console.log('sharp glibc OK')" \
    && cd /app/apps/web && node -e "require.resolve('next'); console.log('next resolves OK')"

# Bundled media-server: copy the Bun runtime + the app. Both stages are glibc
# (Debian/Ubuntu), so the native node-av addon is ABI-compatible; it uses the
# system ffmpeg installed above. Runs as a loopback process on :3456.
COPY --from=mediaserver /usr/local/bin/bun /usr/local/bin/bun
COPY --from=mediaserver /app /opt/media-server

COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh
# Deep health check: the loop that keeps /run/cap-health honest, plus the
# dependency-free SigV4 S3 round trip it runs against the bundled MinIO.
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY s3probe.js /usr/local/bin/s3probe.js
RUN chmod +x /entrypoint.sh /usr/local/bin/healthcheck.sh

# The OpenHost router terminates TLS and forwards plain HTTP to this port.
EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
