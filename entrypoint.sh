#!/bin/sh
# Supervises the bundled services (MySQL 8, MinIO, media-server, Caddy) and then
# runs Cap's Next.js server. Cap runs its own DB migrations and creates +
# policies the S3 bucket on boot, so this script just stands up the backends,
# wires the environment, and waits for them to be ready.
set -eu

log() { echo "[openhost-cap] $*"; }

APP_DATA="${OPENHOST_APP_DATA_DIR:-/data/app_data/cap}"
ARCHIVE="${OPENHOST_APP_ARCHIVE_DIR:-/data/app_archive/cap}"
APP_TEMP="${OPENHOST_APP_TEMP_DIR:-/data/app_temp_data/cap}"
mkdir -p "$APP_DATA" "$ARCHIVE/minio" "$APP_TEMP" /run/mysqld

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

# Public host the router serves this app at, e.g. cap.<zone-domain>. Needed by
# both Caddy and the app.
CAP_PUBLIC_HOST="${OPENHOST_APP_NAME}.${OPENHOST_ZONE_DOMAIN}"
export CAP_PUBLIC_HOST

# --- MySQL 8 on 127.0.0.1:3306, data on app_data ---
DATADIR="$APP_DATA/mysql8"
mkdir -p "$DATADIR" /var/lib/mysql-files
# Ubuntu's mysqld config sets secure_file_priv=/var/lib/mysql-files; the -core
# package doesn't create it, so make it (and the datadir/socket dir) exist + owned.
chown -R mysql:mysql "$DATADIR" /run/mysqld /var/lib/mysql-files
if [ ! -d "$DATADIR/mysql" ]; then
  log "initializing MySQL 8 data dir"
  mysqld --initialize-insecure --datadir="$DATADIR" --user=mysql --innodb-use-native-aio=0
fi
log "starting MySQL"
mysqld --user=mysql --datadir="$DATADIR" \
  --socket=/run/mysqld/mysqld.sock --pid-file=/run/mysqld/mysqld.pid \
  --bind-address=127.0.0.1 --port=3306 --skip-name-resolve \
  --innodb-use-native-aio=0 --innodb-buffer-pool-size=256M --max-connections=200 &
MYSQL_PID=$!

log "waiting for MySQL socket"
ok=0
for _ in $(seq 1 120); do
  mysqladmin --socket=/run/mysqld/mysqld.sock -uroot ping >/dev/null 2>&1 && { ok=1; break; }
  sleep 1
done
[ "$ok" = 1 ] || { log "FATAL: MySQL did not start (socket never became ready)"; exit 1; }

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
ok=0
for _ in $(seq 1 60); do
  mysql --protocol=tcp -h127.0.0.1 -P3306 -ucap -p"${MYSQL_PASSWORD}" -e "SELECT 1" cap >/dev/null 2>&1 && { ok=1; break; }
  sleep 1
done
[ "$ok" = 1 ] || { log "FATAL: MySQL TCP not reachable as app user"; exit 1; }

# --- MinIO (S3 API) on 127.0.0.1:9000, blobs on app_archive ---
log "starting MinIO"
export MINIO_ROOT_USER MINIO_ROOT_PASSWORD
# Logs left on stdout/stderr on purpose so storage failures surface in `oh app logs`.
minio server "$ARCHIVE/minio" \
  --address 127.0.0.1:9000 --console-address 127.0.0.1:9090 &
MINIO_PID=$!

log "waiting for MinIO"
ok=0
for _ in $(seq 1 60); do
  curl -fsS -o /dev/null http://127.0.0.1:9000/minio/health/ready && { ok=1; break; }
  sleep 1
done
[ "$ok" = 1 ] || { log "FATAL: MinIO did not become ready"; exit 1; }

# --- Media-server (Bun + FFmpeg) on 127.0.0.1:3456 — transcoding, HLS, thumbnails, Loom import ---
log "starting media-server"
# exec in the subshell so MS_PID is bun itself (killable on shutdown). Temp/scratch
# for in-flight transcodes goes to app_temp_data, not the ephemeral container FS.
( cd /opt/media-server && exec env PORT=3456 TMPDIR="$APP_TEMP" \
  MEDIA_SERVER_WEBHOOK_SECRET="$MEDIA_SERVER_WEBHOOK_SECRET" \
  bun run src/index.ts ) &
MS_PID=$!

log "waiting for media-server"
ok=0
for _ in $(seq 1 60); do
  curl -fsS -o /dev/null http://127.0.0.1:3456/health && { ok=1; break; }
  sleep 1
done
[ "$ok" = 1 ] || { log "FATAL: media-server did not become ready"; exit 1; }

# --- Cap web environment ---
export DATABASE_URL="mysql://cap:${MYSQL_PASSWORD}@127.0.0.1:3306/cap"
export WEB_URL="https://${CAP_PUBLIC_HOST}"
export NEXTAUTH_URL="https://${CAP_PUBLIC_HOST}"
export NEXTAUTH_SECRET DATABASE_ENCRYPTION_KEY MEDIA_SERVER_WEBHOOK_SECRET
# Point Cap at the bundled media-server. The webhook URL is Cap's own origin; the
# media-server calls back to /api/webhooks/media-server/progress with the shared secret.
export MEDIA_SERVER_URL="http://127.0.0.1:3456"
export MEDIA_SERVER_WEBHOOK_URL="http://127.0.0.1:3000"
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
export HOSTNAME="0.0.0.0"
export PORT="3000"
export NEXT_SHARP_PATH="/app/node_modules/sharp"
# Cap's durable-workflow engine (Vercel Workflow SDK) dispatches steps by self-calling
# this base URL. Pin it to the in-container Next port, else it resolves to the
# host-mapped port (unreachable inside the container) and Loom import / transcription
# / AI workflows fail with ECONNREFUSED.
export WORKFLOW_LOCAL_BASE_URL="http://127.0.0.1:3000"

# --- Cap web. Runs migrations + S3 bucket setup itself on boot. ---
log "starting Cap web — it will run DB migrations and create the S3 bucket"
cd /app
node apps/web/server.js &
APP_PID=$!

# --- Caddy front proxy on :8080, started LAST so the router's health check only goes
#     green once every backend (MySQL, MinIO, media-server) and Cap have started.
#     Logs left on stderr on purpose — a proxy that fails to start should be loud.
log "starting Caddy front proxy"
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

# Graceful shutdown: on SIGTERM (container stop / reload) stop Cap, then cleanly
# shut MySQL down so InnoDB flushes before the runtime SIGKILLs us, then the rest.
graceful_stop() {
  log "signal received — shutting down"
  kill "$APP_PID" 2>/dev/null || true
  mysqladmin --socket=/run/mysqld/mysqld.sock -uroot shutdown 2>/dev/null || true
  kill "$MINIO_PID" "$MS_PID" "$CADDY_PID" 2>/dev/null || true
  exit 0
}
trap graceful_stop TERM INT

# Block on Cap; if it exits on its own (e.g. crash), propagate the code so the
# container restarts instead of hanging.
wait "$APP_PID"
code=$?
log "Cap web exited (code $code)"
exit "$code"
