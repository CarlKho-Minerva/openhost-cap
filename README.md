# openhost-cap

[Cap](https://github.com/CapSoftware/cap) — the open-source Loom — packaged as a
**single self-contained [OpenHost](https://github.com/imbue-openhost) app**.
Record your screen in the browser, get a shareable link, and keep every byte on
your own compute. No signup, no third-party database, no external S3, no upsell. Finally!!

<a href="https://www.loom.com/share/7410eab7eb1b45d4a5f0daca95d444ac">
  <img alt="Watch the demo — deploy Cap on OpenHost, sign in with no code, record + share"
       src="https://cdn.loom.com/sessions/thumbnails/7410eab7eb1b45d4a5f0daca95d444ac-with-play.gif"
       width="640" />
</a>

**[▶ Watch the 3-min demo](https://www.loom.com/share/7410eab7eb1b45d4a5f0daca95d444ac)** — one-click deploy → instant sign-in → record + share, all on your own compute. (Bowei tested it — works great.)

**Owner sign-in is instant.** OpenHost already knows who you are, so this build signs the
compute-space owner straight into Cap — no email code, no signup. First boot also skips
onboarding and hides the "Cap Pro" upsell (self-host has no plans).

## What's in the box

One rootless container runs five processes; all data stays on the instance disk:

```
OpenHost router (TLS + owner auth)
        │  https://cap.<your-zone>
        ▼
  ┌─────────────────────────────────────────────┐
  │ Caddy  :8080   (front proxy)                 │
  │   /cap/*  ─▶ MinIO  :9000  (S3 API, loopback)│──▶ /data/app_archive   video blobs
  │   /*      ─▶ Cap    :3000  (Next.js)         │
  │ MySQL 8      :3306 (loopback)                │──▶ /data/app_data      database + secrets
  │ media-server :3456 (Bun+FFmpeg → HLS)        │──▶ /data/app_temp_data transcode scratch
  └─────────────────────────────────────────────┘
```

- **Cap web** — our fork's build
  ([`carlkho-minerva/cap-web`](https://github.com/CarlKho-Minerva/cap/tree/carl/openhost-selfhost),
  built native amd64+arm64 by the fork's GitHub Action), run on a glibc base. Identical to
  upstream [Cap](https://github.com/CapSoftware/cap) except for two self-host changes:
  trusted-proxy SSO auto-login (owner signs in with no email code) and the "Cap Pro" upsell
  hidden off Cap Cloud. Records in-browser via `getDisplayMedia`/`MediaRecorder`, converts to
  MP4 client-side, uploads to S3.
- **MySQL 8** — the database Cap officially targets (its migrations use JSON-function
  generated columns that MariaDB rejects). Cap runs its own migrations on boot.
- **MinIO** — S3-compatible object store for the videos. Cap creates + policies the
  bucket on boot.
- **Caddy** — fronts both on the single routed port and fixes the presigned-URL host
  so share links play for logged-out viewers.
- **media-server** — Cap's official Bun + FFmpeg service; transcodes recordings to HLS so
  shared videos start fast, and generates thumbnails.

## Deploy

**One click** — from the OpenHost catalog:
**[catalog.carl.selfhost.imbue.com/apps/official/cap](https://catalog.carl.selfhost.imbue.com/apps/official/cap)**

Or with the CLI:

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

## Known limitations / not yet working

- **Loom import** is present (the bundled media-server downloads + transcodes the video),
  but doesn't finalize cleanly on self-host — Cap's import path carries Vercel-cloud
  assumptions (a `@vercel/firewall` rate-limiter that fails closed, and more) that need a
  small cap-web source patch to fully fix.
- **Transcription / AI summaries** (Deepgram + Groq/OpenAI, or your own local Whisper) —
  the pipeline is wired but off; enabling it needs API keys, or the same cap-web source
  patch to point transcription at a self-hosted Whisper.
- **Owner SSO bridge.** A future improvement can auto-provision the Cap account from
  `OPENHOST_OWNER_USERNAME` and skip the one-time magic-code login.

## License

Cap is licensed under **AGPL-3.0**. This packaging (Dockerfile, entrypoint, Caddyfile,
manifest) is provided under **AGPL-3.0-or-later** to match — full text in [`LICENSE`](LICENSE).
Running this over a network carries AGPL's obligation to offer corresponding source: this
repo is linked from the app's `description`, and Cap itself is upstream at
[CapSoftware/cap](https://github.com/CapSoftware/cap).

> **TODO — only if we ever modify Cap itself** (e.g. patching the login flow, Loom import,
> or transcription): once we ship a *modified* Cap, surface the corresponding-source link in
> the app's own footer/UI to satisfy AGPL §13, not just here in the repo.
