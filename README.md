# npm-passport

Download npm packages directly from **www.npmjs.com** when `registry.npmjs.org` (and CDN mirrors like unpkg, jsdelivr) are blocked by enterprise firewall.

Uses `puppeteer` with a bundled Chromium to bypass Cloudflare bot protection on npmjs.com, then downloads package files via the undocumented Code tab API.

## Prerequisites

- **Node.js** (v18+)

## Setup

```bash
git clone <this-repo>
cd npm-passport
npm install
```

This installs `puppeteer` which includes a bundled Chromium — no system browser needed.

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

## How it works

1. Launches a headless Chromium via `puppeteer`
2. Navigates to `www.npmjs.com/package/<name>` (passes Cloudflare challenge)
3. Fetches the file index from `/package/<name>/v/<version>/index` (the API behind the "Code" tab)
4. Downloads each file from `/package/<name>/file/<hash>`
5. Writes files to the vendor directory
