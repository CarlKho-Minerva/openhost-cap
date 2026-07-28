#!/bin/sh
# Supervises the bundled services (MySQL 8, MinIO, Caddy) and then execs Cap's
# Next.js server in the foreground. Cap runs its own DB migrations and creates +
# policies the S3 bucket on boot, so this script just stands up the backends,
# wires the environment, and waits for them to be ready.
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

# --- MySQL 8 on 127.0.0.1:3306, data on app_data ---
DATADIR="$APP_DATA/mysql8"
mkdir -p "$DATADIR"
chown -R mysql:mysql "$DATADIR" /run/mysqld
if [ ! -d "$DATADIR/mysql" ]; then
  log "initializing MySQL 8 data dir"
  mysqld --initialize-insecure --datadir="$DATADIR" --user=mysql
fi
log "starting MySQL"
mysqld --user=mysql --datadir="$DATADIR" \
  --socket=/run/mysqld/mysqld.sock --pid-file=/run/mysqld/mysqld.pid \
  --bind-address=127.0.0.1 --port=3306 --skip-name-resolve \
  --innodb-buffer-pool-size=256M --max-connections=200 &
MYSQL_PID=$!

log "waiting for MySQL socket"
for _ in $(seq 1 90); do
  mysqladmin --socket=/run/mysqld/mysqld.sock -uroot ping >/dev/null 2>&1 && break
  sleep 1
done

log "ensuring database + application user"
# mysql_native_password so the app's plain TCP connection authenticates without TLS
# (MySQL 8 defaults to caching_sha2, which the mysql2 driver rejects over 127.0.0.1).
mysql --socket=/run/mysqld/mysqld.sock -uroot <<SQL
CREATE DATABASE IF NOT EXISTS cap CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'cap'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
ALTER USER 'cap'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON cap.* TO 'cap'@'%';
FLUSH PRIVILEGES;
SQL

log "waiting for MySQL TCP (as app user)"
for _ in $(seq 1 60); do
  mysql --protocol=tcp -h127.0.0.1 -P3306 -ucap -p"${MYSQL_PASSWORD}" -e "SELECT 1" cap >/dev/null 2>&1 && break
  sleep 1
done

# --- MinIO (S3 API) on 127.0.0.1:9000, blobs on app_archive ---
log "starting MinIO"
export MINIO_ROOT_USER MINIO_ROOT_PASSWORD
minio server "$ARCHIVE/minio" \
  --address 127.0.0.1:9000 --console-address 127.0.0.1:9090 >/dev/null 2>&1 &
MINIO_PID=$!

log "waiting for MinIO"
for _ in $(seq 1 60); do
  curl -fsS -o /dev/null http://127.0.0.1:9000/minio/health/ready && break
  sleep 1
done

# --- Cap web environment ---
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
export NEXT_SHARP_PATH="/app/node_modules/sharp"

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
