# Pasta Landing Page

This is the landing page for [pasta-app.com](https://pasta-app.com).

## Deployment

The landing page is automatically deployed to Cloudflare Pages when:
1. Changes are pushed to `landing-page/` directory on `main` branch
2. A new release is created (updates appcast.xml)

### Manual Deployment

```bash
cd landing-page
npx wrangler pages deploy . --project-name=pasta-app
```

## Required Cloudflare Secrets

Add these to your GitHub repository secrets:

- `CLOUDFLARE_API_TOKEN` - API token with Pages:Edit permission
- `CLOUDFLARE_ACCOUNT_ID` - Your Cloudflare account ID

### Creating the API Token

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. Navigate to **My Profile** → **API Tokens**
3. Click **Create Token**
4. Use the **Custom token** template
5. Set permissions:
   - **Account** → **Cloudflare Pages** → **Edit**
6. Click **Continue to summary** → **Create Token**
7. Copy the token value

### Finding Your Account ID

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. Select any domain or go to **Workers & Pages**
3. The Account ID is shown in the right sidebar

## Local Development

```bash
cd landing-page
npm ci
npm run serve      # http://127.0.0.1:4173 (dependency-free static server)
```

Or just open `index.html` in your browser.

## Testing

Everything here runs on Linux/macOS in well under a minute and — apart from
the advisory live probe — needs **no network access**. Requires Node 20+.

```bash
cd landing-page
npm ci
npx playwright install --with-deps chromium   # once

npm test               # contract checks + Playwright smoke suite
npm run test:contract  # appcast.xml / _redirects / _headers only (plain Node, ~1s)
npm run test:e2e       # Playwright smoke suite (Chromium, ~10s)
npm run test:live      # ADVISORY: probes https://pasta-app.com (needs network)
npm run report         # open the last Playwright HTML report
```

### What is covered

| Suite | Files | Checks |
| --- | --- | --- |
| Playwright smoke (`tests/e2e/`) | `landing.spec.ts` | Page renders with title and hero; no console/page errors or failed requests; only the font CDN is contacted; no horizontal overflow at desktop and mobile widths; every **Download** CTA points at a GitHub release (`releases/latest` or a `releases/download/v<x.y.z>/Pasta-<x.y.z>.dmg` URL whose versions agree); GitHub/Releases/Issues links point at the repo; every `href` is well-formed, `#anchors` resolve, `target=_blank` has `rel=noopener`; every `<img>` and icon is served and decodes; `appcast.xml` is served; `lang`, one `h1`, nav/main/footer landmarks, alt text; axe-core WCAG 2.0/2.1 A+AA has zero violations. |
| Appcast contract (`tests/contract/appcast.test.mjs`) | `appcast.xml` | Well-formed XML with the Sparkle namespace; >= 1 item; each item has `sparkle:shortVersionString`, integer `sparkle:version`, parseable `pubDate`, an `https://github.com/crmitchelmore/pasta/releases/download/v<x.y.z>/Pasta-<x.y.z>.dmg` enclosure whose version matches the item, a plausible `length`, and a 64-byte base64 `sparkle:edSignature`; items strictly descending and unique; the top item points at an existing `v*` git tag and is never ahead of the newest tag. |
| Cloudflare config (`tests/contract/cloudflare-config.test.mjs`) | `_redirects`, `_headers` | Non-empty, valid syntax, `/download` -> latest release, security headers on `/*`, short non-immutable cache on `/appcast.xml`. |
| Live probe (`tests/live/`) — **advisory** | live site | `HEAD` of `/`, `/appcast.xml`, `/download` and the top DMG URL respond 200/302 with the expected headers; live appcast top version equals the newest `v*` git tag. |

The Playwright suite serves this directory with `tests/support/static-server.mjs`
and stubs every third-party request, so it can run on a plane.

### Appcast freshness

`release.yml` regenerates `appcast.xml` on every tag and deploys it straight to
Cloudflare **without committing it back**, so the copy in git lags the newest
release. The offline contract test therefore only *warns* when the committed
appcast is behind the newest tag; the live probe is where "did the release
actually publish a fresh feed?" is asserted. Set `APPCAST_REQUIRE_LATEST=1` to
make the offline check strict if the release flow ever starts committing the
appcast. Beware: `deploy-landing-page.yml` redeploys the committed (stale)
appcast whenever `landing-page/**` changes on `main`.

### CI

`.github/workflows/ci.yml` runs three cheap `ubuntu-latest` jobs:

- **Appcast & Cloudflare config contract** — every push and PR.
- **Landing page e2e (Playwright)** — only when `landing-page/**`,
  `scripts/generate-appcast.sh` or `ci.yml` change, or on manual dispatch.
  Uploads `playwright-report/` as an artifact on failure.
- **Landing page live probe (advisory)** — pushes to `main` and manual
  dispatch only; `continue-on-error`, so it can never block a merge.

## Structure

```
landing-page/
├── index.html            # Main landing page
├── appcast.xml           # Sparkle update feed (auto-updated by releases)
├── images/               # Screenshots and assets
├── _headers              # Cloudflare security headers
├── _redirects            # URL redirects
├── wrangler.toml         # Cloudflare configuration
├── package.json          # Test tooling (Playwright, axe-core, fast-xml-parser)
├── playwright.config.ts  # Chromium-only, offline, serves this dir locally
└── tests/
    ├── e2e/              # Playwright smoke suite
    ├── contract/         # appcast.xml / _redirects / _headers checks (node --test)
    ├── live/             # advisory probe of the deployed site
    └── support/          # static server + shared appcast helpers
```
