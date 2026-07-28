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

# --- Cap's official prebuilt web app (Next.js standalone; pure JS, portable) ---
FROM ghcr.io/capsoftware/cap-web:latest AS capweb

# --- Cap's official media-server (Bun + FFmpeg): transcoding, HLS, thumbnails, Loom import ---
FROM ghcr.io/capsoftware/cap-media-server:latest AS mediaserver

# --- glibc runtime: MySQL 8 + Node 24 + MinIO + Caddy ---
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# MySQL 8 server/client (core packages avoid the systemd/postinst datadir dance),
# plus tools. mysql-server-core provides /usr/sbin/mysqld; mysql-common creates
# the `mysql` system user.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       mysql-server-core-8.0 mysql-client-core-8.0 mysql-common \
       ffmpeg ca-certificates curl xz-utils tar \
    && id mysql >/dev/null 2>&1 || (groupadd -r mysql && useradd -r -g mysql -s /usr/sbin/nologin mysql) \
    && rm -rf /var/lib/apt/lists/*

# Node 24 (glibc) via NodeSource — matches the version Cap's app was built with.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version

# MinIO server + Caddy, matched to the host architecture.
RUN set -eux; \
    case "$(uname -m)" in x86_64) A=amd64 ;; aarch64) A=arm64 ;; *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;; esac; \
    curl -fsSL "https://dl.min.io/server/minio/release/linux-${A}/archive/minio.RELEASE.2025-09-07T16-13-09Z" -o /usr/local/bin/minio; \
    chmod +x /usr/local/bin/minio; /usr/local/bin/minio --version; \
    curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_linux_${A}.tar.gz" -o /tmp/caddy.tgz; \
    tar -xzf /tmp/caddy.tgz -C /usr/local/bin caddy; rm /tmp/caddy.tgz; caddy version

# Cap's web app (standalone) lives at /app (server at /app/apps/web/server.js).
COPY --from=capweb /app /app

# Next's image optimizer needs a glibc-native sharp (the copied one is musl).
RUN cd /app && npm install --no-audit --no-fund sharp@0.34.5 \
    && node -e "require('sharp'); console.log('sharp glibc OK')"

# Bundled media-server: copy the Bun runtime + the app. Both stages are glibc
# (Debian/Ubuntu), so the native node-av addon is ABI-compatible; it uses the
# system ffmpeg installed above. Runs as a loopback process on :3456.
COPY --from=mediaserver /usr/local/bin/bun /usr/local/bin/bun
COPY --from=mediaserver /app /opt/media-server

COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# The OpenHost router terminates TLS and forwards plain HTTP to this port.
EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
