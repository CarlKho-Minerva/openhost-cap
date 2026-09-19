# Reliability

What breaks, what now catches it, and how to reload without taking the app down.

Live app: `https://cap.carl.selfhost.imbue.com` on the OpenHost zone
`carl.selfhost.imbue.com`. CLI: `~/.local/bin/oh`.

## Failure modes

### 1. The archive bind goes stale and every upload 503s, silently

The worst one, and the reason this document exists. On 2026-09-15 the container's
bind of the JuiceFS archive (`/data/app_archive/cap`) was found dead with
"Transport endpoint is not connected". The host mount was fine; only containers
started before the host remount kept a bind to a dead FUSE connection. MinIO
carried on serving `/minio/health/live` with 200, so nothing looked wrong, while
every segment upload got a 503. Best estimate is that it had been broken since
about 09-09, roughly six days. The rotated container log for 09-14 and 09-15 has
164 and 1779 storage-error lines respectively.

The old `/_healthz` was a literal `respond "ok" 200` in the Caddyfile. It was
green for the whole outage.

**Now caught by:** the deep health loop (`healthcheck.sh`). Each pass does a real
write, read-back and delete on the archive directory, which fails instantly on a
stale bind, plus a real S3 PUT/GET/DELETE through MinIO (`s3probe.js`). Three
consecutive failures flip `/_healthz` to 503. Twenty consecutive failures, about
ten minutes, exit the container so podman restarts it, which is the known remedy.

**Also caught by:** `lifeos/openhost_storage_probe.py` on the Mac, every 30
minutes, which does the same thing from outside and auto-reloads a stale bind.
That stays. Two independent detectors is the point: the probe cannot run when the
Mac is asleep or when SSH times out, which it did on 2026-09-17.

### 2. A rebuild fails because an upstream download rotted

`oh app reload` is a full rebuild, so any loose download in the Dockerfile can
take a running app down. This already happened once: `dl.min.io` started
returning 410 Gone for the pinned MinIO binary. Fixed in `01589f4` by copying
from a quay.io image digest.

Two more of the same shape were still in the file and are now fixed:

| What | Before | After |
|---|---|---|
| cap-web | ghcr image, index digest | unchanged |
| cap-media-server | ghcr image, index digest | unchanged |
| MinIO | quay.io image, digest | unchanged |
| Caddy 2.8.4 | GitHub release tarball over `curl`, no checksum | `docker.io/library/caddy` pinned by index digest |
| Node 24 | `curl https://deb.nodesource.com/setup_24.x \| bash -`, unpinned script, unpinned 24.x package | `docker.io/library/node:24-bookworm-slim` pinned by index digest |
| MySQL 8, ffmpeg | Ubuntu archive via apt | unchanged. The distro archive is the one source here that does not rot; pinning exact package versions would break on the next point release instead |
| `sharp@0.34.5` | npm at build time | unchanged. Exact version, but it still needs the npm registry. The only remaining build step that depends on a live third-party network service |

### 3. A child process dies and the container keeps serving half an app

`entrypoint.sh` started five long-lived children and then waited on only one of
them, Cap's Next server. If mysqld, MinIO, the media-server or Caddy had died,
the container would have stayed up, `/_healthz` would have stayed 200, and
OpenHost would have had no reason to think anything was wrong. Same silent shape
as failure mode 1.

**Now caught by:** a `wait -n` supervisor loop at the bottom of `entrypoint.sh`.
Any supervised child exiting logs `FATAL: supervised child '<name>' (pid N)
exited with code C` and takes the container down non-zero. This is why the script
is `#!/bin/bash` now: Ubuntu's `/bin/sh` is dash, which has no `wait -n`.

The one background job that is expected to finish, the OpenHost owner seed, is
not in the supervised set, so the loop ignores it and keeps waiting.

### 4. Cap Desktop silently restarts a recording under a new id

When an upload keeps failing, the desktop app gives up, starts a new recording
with a new video id, and deletes the old one. Nothing in the server can prevent
this. The local bundles survive at
`~/Library/Application Support/so.cap.desktop/recordings/`; recovery is
`cat init.mp4 segment_*.m4s` per track, mux with `ffmpeg -c copy`, then
`python3 ~/CODELocalProjects/lifeos/cap_upload.py <mp4> <thumb.jpg> "<name>"`.

The fix is upstream of this: make uploads not fail, and notice within minutes
when they do.

### 5. Nothing recorded who opened a share link

Container stdout is truncated on every restart, so "did anyone open this link"
was unanswerable a day later.

**Now caught by:** Caddy writes a JSON access log for `/s/*`, `/embed/*` and
`/api/playlist*` to `$OPENHOST_APP_DATA_DIR/access/shares.log`, rolled at 10 MB,
5 kept. It records User-Agent, Referer and `X-Openhost-Is-Owner` so Carl's own
views are separable from a visitor's. Cookies, Authorization and the
signature-bearing query parameters are dropped. It lives on `app_data`, so it
survives reloads and is backed up.

### 6. Known-broken, not fixed here

- **Server-side transcription never runs.** 31 occurrences in the current log of
  `Failed to queue transcription ... "Missing necessary environment variables"`,
  for example videoId `p7r92pk0cbjp7v4` at 2026-09-16T19:21:34Z. It needs a
  transcription provider the self-host build has no config for. Uploads and
  playback are unaffected.
- **Log noise.** `[auth] trusted-proxy sign-in is ENABLED` is printed on every
  authenticated request: 4856 of 11722 lines in the current log. It buries real
  errors and should be moved to a once-at-boot warning in the fork.
- **`S3Error / NotFound / 404`** blocks, 83 in the current log, are Cap probing
  for objects that do not exist (subtitle and variant files). Benign.
- **Caddy `aborting with incomplete response ... broken pipe`** on `/cap/*`, 65
  in the current log, is a video player seeking or closing mid-range-request.
  Benign, and comes from real viewers.

## Headroom, as measured 2026-09-19

Manifest grants 4096 MB and 2.0 cores.

- `memory.current` 1.86 GiB, `memory.peak` 3.74 GiB of the 4.00 GiB cap
  (93%), `memory.events` oom_kill **0**. The peak is mostly reclaimable page
  cache from the 22-clip upload burst, not anonymous memory: resident set across
  all five children is about 1.3 GiB (next-server 566 MB, mysqld 459 MB, minio
  153 MB, bun 97 MB, caddy 18 MB). Not urgent, but there is no room to add a
  sixth heavyweight process.
- CPU: 209 throttled periods out of 2,183,083. Effectively none.
- Disk: `app_data` 200 MB, `app_temp_data` 6.0 MB, `app_archive` 28 GB of a 1 PB
  JuiceFS volume. Host disk `/dev/sda1` 93G of 150G used, 65%.
- **Temp uploads do get cleaned.** `/data/app_temp_data/cap/cap-media-server` is
  empty and no file under the temp dir is older than two days; the media-server
  removes its own scratch. The only large things there are the platform's own
  rotated `container.log` files. No reaper needed.
- All five children have been up continuously since 2026-09-15 21:10. No
  restarts, no OOM kills.

## Diagnose in three commands

```sh
# 1. Is the deep check happy, and if not, why? (the body is the reason)
oh app ssh cap 'curl -s -o /dev/null -w "%{http_code} " http://127.0.0.1:8080/_healthz; cat /run/cap-health/status'

# 2. Is the archive bind alive and are all five children up?
oh app ssh cap 'df -h /data/app_archive/cap; ps -eo pid,etime,rss,comm --sort=pid'

# 3. What has actually gone wrong lately? (skip the trusted-proxy noise)
oh app logs cap | grep -v "trusted-proxy sign-in" | tail -50
```

Who opened a link:

```sh
oh app ssh cap 'tail -200 /data/app_data/cap/access/shares.log' \
  | python3 -c 'import sys,json;[print(r["request"]["uri"], r["request"]["headers"].get("User-Agent"), r["request"]["headers"].get("X-Openhost-Is-Owner")) for r in map(json.loads, sys.stdin)]'
```

## Reload procedure

A reload is a full rebuild. `oh app reload --wait` **exits 0 even when the build
fails**, so the status check afterwards is not optional.

### Pre-flight

1. `git -C openhost-cap status` is clean and the branch is pushed.
2. Nobody is mid-upload: `oh app logs cap | tail -20` shows no
   `Getting presigned URL for part` in the last minute.
3. Record the rollback point: `oh app status cap` prints the deployed git sha.
   Write it down.
4. Confirm the pinned digests still resolve, so the rebuild cannot fail on a
   fetch:
   ```sh
   for ref in \
     ghcr.io/carlkho-minerva/cap-web@sha256:a6808d48... \
     ghcr.io/capsoftware/cap-media-server@sha256:43587203... \
     quay.io/minio/minio@sha256:14cea493... \
     docker.io/library/caddy@sha256:226d1f05... \
     docker.io/library/node@sha256:2fe369e9... ; do
     echo "$ref"; done   # then pull each, or trust the digest and accept a rebuild retry
   ```
5. `caddy validate --config Caddyfile --adapter caddyfile` and
   `shellcheck -s bash entrypoint.sh healthcheck.sh` both pass locally.

### Reload

```sh
oh app reload cap --update --wait
oh app status cap        # MUST say "running". Anything else is a failed build.
```

### Post-flight

All five must pass. `$H=https://cap.carl.selfhost.imbue.com`.

```sh
H=https://cap.carl.selfhost.imbue.com
V=edjfs9smpcbwvhy   # a known-good video id

# 1. share page is 200
curl -s -o /dev/null -w '/s 200? %{http_code}\n' "$H/s/$V"

# 2. playlist 302s to a playable mp4
curl -s -o /dev/null -w '/api/playlist 302? %{http_code} -> %{redirect_url}\n' \
  "$H/api/playlist?videoId=$V&videoType=mp4"
#    then follow it and confirm bytes come back:
curl -sL -o /dev/null -w 'mp4 bytes: %{size_download} type: %{content_type}\n' \
  "$H/api/playlist?videoId=$V&videoType=mp4"

# 3. a real S3 round trip, in-container, writes and deletes one tiny object
oh app ssh cap 'set -a; . /data/app_data/cap/secrets.env; set +a; \
  CAP_AWS_ACCESS_KEY=$MINIO_ROOT_USER CAP_AWS_SECRET_KEY=$MINIO_ROOT_PASSWORD \
  CAP_AWS_BUCKET=cap CAP_AWS_REGION=us-east-1 S3_INTERNAL_ENDPOINT=http://127.0.0.1:9000 \
  node /usr/local/bin/s3probe.js && echo "S3 round trip OK"'

# 4. desktop API still refuses an unauthenticated caller
curl -s -o /dev/null -w '/api/desktop 401? %{http_code}\n' \
  "$H/api/desktop/video/create?recordingMode=desktopMP4&name=x"

# 5. the new healthz is honest and says ok
curl -s -w ' <- %{http_code}\n' "$H/_healthz"     # expect: ok <- 200
```

`/_healthz` is 503 for the first pass or two after a reload while the deep check
runs for the first time. That is correct, not a fault. Give it 60 seconds.

Also worth one look after a reload that touched routing: confirm
`/api/analytics/track` accepts an anonymous POST and that bare `/api/analytics`
still requires the zone login.

### Rollback

Nothing here changes the database or the on-disk layout, so rollback is a code
revert plus a reload.

```sh
cd ~/Downloads/CODELocalProjects/openhost-cap
git revert --no-edit <the bad commit>      # or: git reset --hard 01589f4
git push
oh app reload cap --update --wait
oh app status cap                          # MUST say "running"
```

If the rebuild itself is what is broken and the app will not come up, the
container image from before the reload is gone (a reload rebuilds), so the way
back is always "revert the code and reload again", not "redeploy the old image".
That is why every download in the Dockerfile is pinned: the rollback path runs
through the same build.

## What the platform does, and does not do

Read from the OpenHost source, not guessed:

- `compute_space/core/containers.py` runs every app container with
  `--restart=unless-stopped`. An exited container **is** restarted.
- `health_check` from `openhost.toml` is read only by
  `compute_space/core/diagnostics.py`, which probes it and reports
  `healthy = resp.status_code < 500`. Nothing acts on the result: there is no
  restart, no alert, no traffic removal. An unhealthy app is merely *labelled*
  unhealthy.

That asymmetry is the whole design of the watchdog here: since marking unhealthy
achieves nothing on its own, the container has to remove itself when it is
persistently broken, and the platform's restart policy does the rest.
