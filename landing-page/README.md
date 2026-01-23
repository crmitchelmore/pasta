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
# Install dependencies (optional, for serving)
npm install -g serve

# Serve locally
serve .
```

Or just open `index.html` in your browser.

## Structure

```
landing-page/
├── index.html      # Main landing page
├── appcast.xml     # Sparkle update feed (auto-updated by releases)
├── images/         # Screenshots and assets
├── _headers        # Cloudflare security headers
├── _redirects      # URL redirects
└── wrangler.toml   # Cloudflare configuration
```
