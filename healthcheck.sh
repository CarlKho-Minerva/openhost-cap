#!/bin/bash
# Deep health loop. Runs as a background child of entrypoint.sh and is the only
# writer of /run/cap-health/, which Caddy serves as /_healthz:
#
#   /run/cap-health/ok      present  -> Caddy answers 200
#                           absent   -> Caddy answers 503
#   /run/cap-health/status  one line of human-readable detail, served as the body
#
# The old /_healthz was a static `respond "ok" 200` in the Caddyfile. It stayed
# green through the entire 2026-09-15 outage, when the archive bind was dead and
# every upload 503'd for about six days. This version only says ok when the four
# things an upload actually needs all work:
#
#   1. the app_archive bind can take a real write + read-back + delete
#   2. MinIO can do a real S3 PUT/GET/DELETE in the cap bucket (see s3probe.js)
#   3. MySQL answers SELECT 1 over TCP as the app user (the path Cap uses)
#   4. the Next server answers with anything under 500
#
# Cheapness and flap resistance:
#   - one pass every CAP_HEALTH_INTERVAL_S (default 30s), so the endpoint itself
#     is a file read no matter how often it is polled
#   - every step has a hard timeout; nothing here can block forever
#   - during boot the status is "starting" and the ok flag is absent, which is
#     honest: the app is not ready yet
#   - a single failed pass does not flip to unhealthy. It takes
#     CAP_HEALTH_FAIL_STREAK consecutive failures (default 3, so ~90s) to drop
#     the ok flag, which rides out a transient MinIO hiccup or a GC pause
#
# Optional watchdog (CAP_HEALTH_WATCHDOG_STREAK, default 20 -> ~10 minutes):
# after that many consecutive failed passes the loop exits non-zero, which the
# supervisor in entrypoint.sh turns into a container exit. OpenHost runs app
# containers with `--restart=unless-stopped` (compute_space/core/containers.py),
# so an exited container is restarted by podman. Nothing in OpenHost reacts to a
# failing health_check: it is read only by core/diagnostics.py for reporting.
# Restarting the container is exactly the documented remedy for a stale archive
# bind, so this closes the loop the platform does not.

set -u

STATE_DIR="${CAP_HEALTH_DIR:-/run/cap-health}"
OK_FLAG="$STATE_DIR/ok"
STATUS_FILE="$STATE_DIR/status"

INTERVAL_S="${CAP_HEALTH_INTERVAL_S:-30}"
FAIL_STREAK="${CAP_HEALTH_FAIL_STREAK:-3}"
WATCHDOG_STREAK="${CAP_HEALTH_WATCHDOG_STREAK:-20}"
GRACE_S="${CAP_HEALTH_GRACE_S:-180}"

ARCHIVE="${OPENHOST_APP_ARCHIVE_DIR:-/data/app_archive/cap}"

log() { echo "[openhost-cap/health] $*"; }

set_status() { printf '%s\n' "$1" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"; }

# --- individual checks. Each echoes a reason and returns 1 on failure. ---

check_archive() {
    # The direct test for the 2026-09-15 failure mode: a stale FUSE bind fails
    # here immediately with "Transport endpoint is not connected", long before
    # anything HTTP notices.
    local probe payload
    probe="$ARCHIVE/.openhost-healthz-probe.$$"
    payload="healthz $(date -u +%FT%TZ)"
    # shellcheck disable=SC2016  # _P/_V are expanded by the inner shell, on purpose
    if ! timeout 10 env _P="$probe" _V="$payload" sh -c 'printf %s "$_V" > "$_P"' 2>/dev/null; then
        rm -f "$probe" 2>/dev/null
        echo "archive write failed ($ARCHIVE)"; return 1
    fi
    local back
    back="$(timeout 10 cat "$probe" 2>/dev/null)"
    rm -f "$probe" 2>/dev/null
    if [ "$back" != "$payload" ]; then
        echo "archive read-back mismatch ($ARCHIVE)"; return 1
    fi
    return 0
}

check_minio() {
    local out
    if ! out="$(timeout 15 node /usr/local/bin/s3probe.js 2>&1)"; then
        echo "minio: ${out:-no output}"; return 1
    fi
    return 0
}

check_mysql() {
    # MYSQL_PWD rather than -p so the password is not visible in `ps`.
    if ! MYSQL_PWD="${MYSQL_PASSWORD}" timeout 10 mysql --protocol=tcp -h127.0.0.1 -P3306 \
        -ucap --connect-timeout=5 -e "SELECT 1" cap >/dev/null 2>&1; then
        echo "mysql: SELECT 1 over TCP failed"; return 1
    fi
    return 0
}

check_next() {
    # Cap has no health route of its own; "/" 307s for an anonymous caller. Any
    # status under 500 means the Next server is answering, which matches the
    # readiness contract OpenHost's own diagnostics use.
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 http://127.0.0.1:3000/ 2>/dev/null)"
    if [ -z "$code" ] || [ "$code" = "000" ] || [ "$code" -ge 500 ] 2>/dev/null; then
        echo "next: / returned '${code:-no response}'"; return 1
    fi
    return 0
}

check_media_server() {
    if ! curl -fsS -o /dev/null -m 10 http://127.0.0.1:3456/health 2>/dev/null; then
        echo "media-server: /health did not answer"; return 1
    fi
    return 0
}

run_pass() {
    local reason
    for fn in check_archive check_minio check_mysql check_next check_media_server; do
        if ! reason="$($fn)"; then
            echo "$reason"; return 1
        fi
    done
    return 0
}

# --- loop ---

mkdir -p "$STATE_DIR"
rm -f "$OK_FLAG"
set_status "starting"

started_at="$(date +%s)"
streak=0

while :; do
    if reason="$(run_pass)"; then
        if [ ! -e "$OK_FLAG" ]; then
            log "deep check passed - /_healthz is now ok"
        fi
        streak=0
        set_status "ok"
        : > "$OK_FLAG"
    else
        streak=$((streak + 1))
        set_status "FAILING (${streak}x): ${reason}"
        log "deep check FAILED (${streak} in a row): ${reason}"

        if [ "$streak" -ge "$FAIL_STREAK" ] && [ -e "$OK_FLAG" ]; then
            rm -f "$OK_FLAG"
            log "ALERT: /_healthz is now 503 after ${streak} consecutive failures: ${reason}"
        fi

        now="$(date +%s)"
        if [ "$WATCHDOG_STREAK" -gt 0 ] \
           && [ "$streak" -ge "$WATCHDOG_STREAK" ] \
           && [ $((now - started_at)) -gt "$GRACE_S" ]; then
            log "FATAL: ${streak} consecutive deep-check failures (${reason}) - exiting so the container is restarted"
            exit 1
        fi
    fi
    sleep "$INTERVAL_S"
done
