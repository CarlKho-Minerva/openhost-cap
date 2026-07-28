#!/bin/sh
# Supervises the three bundled services (MariaDB, MinIO, Caddy) and then execs
# Cap's Next.js server in the foreground. Cap itself runs DB migrations and
# creates + policies the S3 bucket on boot, so this script only has to stand up
# the backends, wire the environment, and wait for them to be ready.
set -eu

log() { echo "[openhost-cap] $*"; }

APP_DATA="${OPENHOST_APP_DATA_DIR:-/data/app_data/cap}"
ARCHIVE="${OPENHOST_APP_ARCHIVE_DIR:-/data/app_archive/cap}"
mkdir -p "$APP_DATA" "$ARCHIVE/minio" /run/mysqld

# --- One-time, persisted secrets (stable across restarts; live on backed-up app_data) ---
SECRETS="$APP_DATA/secrets.env"
if [ ! -f "$SECRETS" ]; then
  log "generating persistent secrets"
  umask 077
  gen() { node -e "console.log(require('crypto').randomBytes($1).toString('hex'))"; }
  {
    echo "NEXTAUTH_SECRET=$(gen 32)"
    echo "DATABASE_ENCRYPTION_KEY=$(gen 32)"
    echo "MYSQL_PASSWORD=$(gen 18)"
    echo "MINIO_ROOT_USER=cap$(gen 4)"
    echo "MINIO_ROOT_PASSWORD=$(gen 24)"
    echo "MEDIA_SERVER_WEBHOOK_SECRET=$(gen 32)"
  } > "$SECRETS"
fi
# shellcheck disable=SC1090
set -a; . "$SECRETS"; set +a

# --- MariaDB (MySQL-compatible) on 127.0.0.1:3306, data on app_data ---
DATADIR="$APP_DATA/mysql"
if [ ! -d "$DATADIR/mysql" ]; then
  log "initializing MariaDB data dir"
  mariadb-install-db --user=root --datadir="$DATADIR" \
    --auth-root-authentication-method=normal --skip-test-db >/dev/null 2>&1
fi
log "starting MariaDB"
mariadbd --user=root --datadir="$DATADIR" \
  --socket=/run/mysqld/mysqld.sock \
  --bind-address=127.0.0.1 --port=3306 --skip-name-resolve \
  --innodb-buffer-pool-size=256M --max-connections=200 &
MYSQL_PID=$!

log "waiting for MariaDB"
for _ in $(seq 1 60); do
  mariadb-admin --socket=/run/mysqld/mysqld.sock -uroot ping >/dev/null 2>&1 && break
  sleep 1
done

log "ensuring database + application user"
mariadb --socket=/run/mysqld/mysqld.sock -uroot <<SQL
CREATE DATABASE IF NOT EXISTS cap CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'cap'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
ALTER USER 'cap'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON cap.* TO 'cap'@'%';
FLUSH PRIVILEGES;
SQL

# --- MinIO (S3 API) on 127.0.0.1:9000, blobs on app_archive ---
log "starting MinIO"
export MINIO_ROOT_USER MINIO_ROOT_PASSWORD
minio server "$ARCHIVE/minio" \
  --address 127.0.0.1:9000 --console-address 127.0.0.1:9090 >/dev/null 2>&1 &
MINIO_PID=$!

log "waiting for MinIO"
for _ in $(seq 1 60); do
  wget -q -O /dev/null http://127.0.0.1:9000/minio/health/ready && break
  sleep 1
done

# --- Cap web environment ---
# Public host the OpenHost router serves this app at, e.g. cap.<zone-domain>.
CAP_PUBLIC_HOST="${OPENHOST_APP_NAME}.${OPENHOST_ZONE_DOMAIN}"
export CAP_PUBLIC_HOST
export DATABASE_URL="mysql://cap:${MYSQL_PASSWORD}@127.0.0.1:3306/cap"
export WEB_URL="https://${CAP_PUBLIC_HOST}"
export NEXTAUTH_URL="https://${CAP_PUBLIC_HOST}"
export NEXTAUTH_SECRET DATABASE_ENCRYPTION_KEY MEDIA_SERVER_WEBHOOK_SECRET
export CAP_AWS_BUCKET="cap"
export CAP_AWS_REGION="us-east-1"
export CAP_AWS_ACCESS_KEY="${MINIO_ROOT_USER}"
export CAP_AWS_SECRET_KEY="${MINIO_ROOT_PASSWORD}"
# Presigned URLs handed to the browser sign against the public host; server-side
# reads use the loopback endpoint. See README "How storage + share links work".
export S3_PUBLIC_ENDPOINT="https://${CAP_PUBLIC_HOST}"
export S3_INTERNAL_ENDPOINT="http://127.0.0.1:9000"
export S3_PATH_STYLE="true"
export NODE_ENV="production"

# --- Caddy front proxy on :8080 (the single routed port) ---
log "starting Caddy front proxy"
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 &
CADDY_PID=$!

term() { kill "$MYSQL_PID" "$MINIO_PID" "$CADDY_PID" 2>/dev/null || true; }
trap term TERM INT

# --- Cap web (foreground). Runs migrations + S3 bucket setup itself on boot. ---
log "starting Cap web — it will run DB migrations and create the S3 bucket"
cd /app
exec env HOSTNAME=0.0.0.0 PORT=3000 node apps/web/server.js
