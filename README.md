# openhost-cap

[Cap](https://github.com/CapSoftware/cap) — the open-source Loom — packaged as a
**single self-contained [OpenHost](https://github.com/imbue-openhost) app**.
Record your screen in the browser, get a shareable link, and keep every byte on
your own compute. No desktop app, no third-party database, no external S3. Finally!!

## What's in the box

One rootless container runs four processes; all data stays on the instance disk:

```
OpenHost router (TLS + owner auth)
        │  https://cap.<your-zone>
        ▼
  ┌─────────────────────────────────────────────┐
  │ Caddy  :8080   (front proxy)                 │
  │   /cap/*  ─▶ MinIO  :9000  (S3 API, loopback)│──▶ /data/app_archive   video blobs
  │   /*      ─▶ Cap    :3000  (Next.js)         │
  │ MySQL 8  :3306 (loopback)                    │──▶ /data/app_data      database + secrets
  └─────────────────────────────────────────────┘
```

- **Cap web** — the official `ghcr.io/capsoftware/cap-web` app artifacts, run on a
  glibc base. Records in-browser via `getDisplayMedia`/`MediaRecorder`, converts to
  MP4 client-side, uploads to S3.
- **MySQL 8** — the database Cap officially targets (its migrations use JSON-function
  generated columns that MariaDB rejects). Cap runs its own migrations on boot.
- **MinIO** — S3-compatible object store for the videos. Cap creates + policies the
  bucket on boot.
- **Caddy** — fronts both on the single routed port and fixes the presigned-URL host
  so share links play for logged-out viewers.

## Deploy

```bash
# One-time: install + log in the OpenHost CLI
uv tool install "oh @ git+https://github.com/imbue-openhost/openhost.git#subdirectory=compute_space_cli"
oh instance login

# Deploy (first build takes a few minutes — it downloads MinIO + builds the image)
oh app deploy https://github.com/CarlKho-Minerva/openhost-cap --name cap --wait
oh app logs cap --follow
```

Or from the dashboard: **Deploy New App** → paste this repo URL.

Update after pushing changes:

```bash
oh app reload cap --update --wait
```

## First login

There are two gates, both one-time (sessions persist afterwards):

1. **Zone login** — the OpenHost router redirects you to your zone's login. Sign in as
   the space owner. This is what keeps the app private to you.
2. **Cap login** — Cap has its own email login on top. Enter your email; since no email
   provider is configured, Cap prints the 6-digit code to the container logs instead of
   emailing it. Grab it with:

   ```bash
   oh app logs cap | grep "Code:" | tail -1
   ```

Then, on the onboarding screens, click **"Skip to dashboard"** and start recording in the
browser — no desktop app needed.

> **Nicer login (optional):** set `RESEND_API_KEY` + `RESEND_FROM_DOMAIN` in `entrypoint.sh`
> to have Cap email the code instead of logging it. The log-code path is a fine default for
> a single-owner instance since you rarely re-auth.

## Self-hosting notes (Pro, onboarding, desktop app)

Cap's cloud product (cap.so) has Pro tiers, per-seat billing, and a desktop app. **None of
that applies to a self-hosted build**, and it's not a limitation you're working around —
it's how Cap is designed:

- **Everything is unlocked.** `userIsPro()` returns `true` whenever the build isn't Cap
  Cloud (`NEXT_PUBLIC_IS_CAP` unset), so all "Pro" features are on and the billing/upgrade
  UI is compiled out of the dashboard entirely.
- **The onboarding "Upgrade to Pro / custom domain / invite team / Download Cap" cards are
  upstream cloud copy.** They appear once during first-run onboarding and don't apply here
  (you're already on your own domain; you don't need the desktop app). Click **"Skip to
  dashboard"** — they don't come back.
- **Record in the browser.** The dashboard's recorder uses `getDisplayMedia`/`MediaRecorder`,
  converts to MP4 client-side, and uploads to the bundled MinIO. (A future improvement could
  make onboarding self-host-aware upstream — a good contribution back to Cap.)

## How storage + share links work

Cap hands the browser **presigned** S3 URLs. Server-side, Cap talks to MinIO on
`http://127.0.0.1:9000`; for the browser it signs against the public origin
(`S3_PUBLIC_ENDPOINT=https://cap.<zone>`, path-style → `.../cap/<key>`). Caddy proxies
`/cap/*` to MinIO and pins the upstream `Host` to the signed host so SigV4 validation
passes. The `/cap/`, `/s/`, `/embed/` and playback API prefixes are listed in
`openhost.toml`'s `public_paths`, so anonymous visitors can watch shared videos.

## Data & backups

| Path | Contents | Backed up |
|------|----------|-----------|
| `/data/app_data/cap` | MySQL 8 data + persisted secrets | yes |
| `/data/app_archive/cap` | MinIO video blobs | archive tier (upgradable to S3) |
| `/data/app_temp_data/cap` | in-flight upload scratch | no |

Secrets (`NEXTAUTH_SECRET`, `DATABASE_ENCRYPTION_KEY`, DB + MinIO credentials) are
generated once on first boot and persisted to `app_data`.

## Not included in v1

- **Server-side transcoding / HLS / Loom import** (Cap's `media-server`). Browser
  recordings convert to MP4 client-side and play via presigned S3, so record → share →
  view works without it. The trade-off is a short client-side conversion delay after you
  stop recording (the "bit of latency"). Add the Bun/FFmpeg sidecar later for HLS + faster
  finalization.
- **Owner SSO bridge.** A future improvement can auto-provision the Cap account from
  `OPENHOST_OWNER_USERNAME` and skip the one-time magic-code login.

## License

Cap is licensed under **AGPL-3.0**. This packaging (Dockerfile, entrypoint, Caddyfile,
manifest) is provided under **AGPL-3.0-or-later** to match. Running this over a network
carries AGPL's obligation to offer corresponding source — see the upstream repo and this
one.
