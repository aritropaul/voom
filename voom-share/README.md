# Voom Self-Host Worker

The sharing backend for [Voom](https://github.com/aritropaul/voom) — a single
Cloudflare Worker that stores recordings in R2, metadata in D1, and serves the
share/embed pages. Always free, and you own the data.

## One-click deploy

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/aritropaul/voom/tree/main/voom-share)

This clones the worker into your GitHub, **auto-provisions a fresh D1 database and
R2 bucket in your account**, and deploys it (with auto-redeploy on push). The
worker creates its own database schema on first request — no migrations to run.

### Set your secret

Voom authenticates with a shared secret. Either:

- **During deploy:** when the flow prompts for secrets, set `API_SECRET`, or
- **After deploy:** Worker → **Settings → Variables and Secrets** → add a
  **Secret** named `API_SECRET`.

Generate a strong value:

```sh
openssl rand -hex 32
```

### Connect Voom

In Voom: **Settings → Sharing → Self-Host**, paste your worker URL
(`https://voom-share.<your-subdomain>.workers.dev`) and the `API_SECRET` you set.

## Manual deploy

```sh
npm install
npx wrangler secret put API_SECRET   # paste your generated value
npx wrangler deploy                  # provisions D1 + R2 on first deploy
```

## Maintainer note

Two configs live here on purpose:

- **`wrangler.jsonc`** — ID-less bindings, for the Deploy button and fresh
  self-hosters. `wrangler` prefers JSON config, so a bare `wrangler deploy` uses
  this one and provisions *new* resources.
- **`wrangler.toml`** — the maintainer's existing worker with real resource IDs.
  Deploy it only with **`npm run deploy`** (`wrangler deploy --config wrangler.toml`).
  Never run a bare `wrangler deploy` against the maintainer's setup.

## What's here

| Path | What |
|------|------|
| `src/index.js` | The worker — API, share page (`/s/:code`), video stream (`/v/:code`), embed |
| `web/` | Astro source for the share/embed pages; `web/dist` is the prebuilt output served via the `ASSETS` binding |
| `wrangler.jsonc` | ID-less bindings so Cloudflare provisions fresh D1 + R2 for self-hosters |
| `schema.sql`, `migrations/` | Reference schema; the worker applies it automatically at runtime |

## License

MIT, same as Voom.
