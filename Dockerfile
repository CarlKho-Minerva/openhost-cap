# syntax=docker.io/docker/dockerfile:1
#
# Self-contained OpenHost packaging of Cap (https://github.com/CapSoftware/cap).
# Layers a bundled MariaDB (MySQL-compatible) + MinIO (S3 API) + Caddy front-proxy
# onto Cap's official web image, so the whole app runs as ONE rootless container
# with all data on the OpenHost instance's persistent disk. Nothing leaves the box.
#
# Base already contains the built Next.js standalone server at /app/apps/web/server.js,
# with NEXT_PUBLIC_DOCKER_BUILD=true baked in -> the app auto-runs DB migrations and
# creates the S3 bucket on boot (see Cap's apps/web/instrumentation.node.ts).
FROM ghcr.io/capsoftware/cap-web:latest

USER root

# MariaDB server + client, Caddy front proxy, wget/CA for downloads.
RUN apk add --no-cache mariadb mariadb-client caddy wget ca-certificates \
    && mkdir -p /run/mysqld /etc/caddy

# MinIO server binary, matched to the host architecture (VM may be amd64 or arm64).
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64)  MINARCH=amd64 ;; \
      aarch64) MINARCH=arm64 ;; \
      *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    wget -q "https://dl.min.io/server/minio/release/linux-${MINARCH}/minio" -O /usr/local/bin/minio; \
    chmod +x /usr/local/bin/minio; \
    /usr/local/bin/minio --version

COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# The OpenHost router terminates TLS and forwards plain HTTP to this port.
EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
