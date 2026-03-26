# npm-passport

Download npm packages directly from **www.npmjs.com** when `registry.npmjs.org` (and CDN mirrors like unpkg, jsdelivr) are blocked by enterprise firewall.

Uses `puppeteer-core` with your system Chrome/Edge to bypass Cloudflare bot protection on npmjs.com, then downloads package files via the undocumented Code tab API.

## Prerequisites

- **Node.js** (v18+)
- **Chrome, Chromium, or Edge** installed on the system

## Setup

```bash
git clone <this-repo>
cd npm-passport
npm install
```

This installs `puppeteer-core` (~2MB, no browser download — it uses your existing Chrome).

## Usage

```bash
node npm-passport.mjs <package>[@version] [--vendor <dir>]
```

### Examples

```bash
# Latest version
node npm-passport.mjs lodash

# Specific version
node npm-passport.mjs lodash@4.17.21

# Scoped package
node npm-passport.mjs @types/node@18.0.0

# Custom output directory
node npm-passport.mjs express --vendor ./lib/vendor
```

Packages are downloaded to `./vendor/<package-name>/` by default.

## Browser not found?

If you get `No Chrome/Chromium/Edge found`, set the `CHROME_PATH` environment variable:

```bash
# Point to your browser executable
CHROME_PATH=/path/to/chrome node npm-passport.mjs lodash

# Examples:
CHROME_PATH="/usr/bin/chromium" node npm-passport.mjs lodash
CHROME_PATH="C:\Program Files\Google\Chrome\Application\chrome.exe" node npm-passport.mjs lodash
```

Auto-detected locations:
- **macOS**: `/Applications/Google Chrome.app/...`, Chromium, Microsoft Edge
- **Linux**: `/usr/bin/google-chrome`, `/usr/bin/chromium`, `/snap/bin/chromium`, `/usr/bin/microsoft-edge`
- **Windows**: `Program Files\Google\Chrome\...`, `Microsoft\Edge\...`

## How it works

1. Launches a headless Chrome via `puppeteer-core`
2. Navigates to `www.npmjs.com/package/<name>` (passes Cloudflare challenge)
3. Fetches the file index from `/package/<name>/v/<version>/index` (the API behind the "Code" tab)
4. Downloads each file from `/package/<name>/file/<hash>`
5. Writes files to the vendor directory
