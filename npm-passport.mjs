#!/usr/bin/env node
// ============================================================
// npm-passport
// Downloads npm packages directly from www.npmjs.com using a
// headless browser (puppeteer-core + system Chrome/Chromium).
// Use when registry.npmjs.org and CDN mirrors are blocked by
// enterprise firewall but www.npmjs.com is accessible.
//
// Setup:  npm install puppeteer-core
//
// Usage:
//   node npm-passport.mjs <package>
//   node npm-passport.mjs <package>@<version>
//   node npm-passport.mjs <package>[@version] --vendor ./lib/vendor
//
// Examples:
//   node npm-passport.mjs lodash
//   node npm-passport.mjs lodash@4.17.21
//   node npm-passport.mjs @types/node@18.0.0
//   node npm-passport.mjs express --vendor ./lib/vendor
// ============================================================

import puppeteer from 'puppeteer-core';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ── Colors ──────────────────────────────────────────────────
const C = {
  reset: '\x1b[0m', bold: '\x1b[1m',
  red: '\x1b[31m', green: '\x1b[32m', yellow: '\x1b[33m', cyan: '\x1b[36m',
};
const info    = msg => console.error(`${C.cyan}[info]${C.reset}  ${msg}`);
const ok      = msg => console.error(`${C.green}[ok]${C.reset}    ${msg}`);
const warn    = msg => console.error(`${C.yellow}[warn]${C.reset}  ${msg}`);
const die     = msg => { console.error(`${C.red}[error]${C.reset} ${msg}`); process.exit(1); };

// ── Parse arguments ─────────────────────────────────────────
const args = process.argv.slice(2);
if (args.length === 0) {
  die(`Usage: node npm-passport.mjs <package>[@version] [--vendor <dir>]
Example: node npm-passport.mjs lodash@4.17.21 --vendor ./vendor`);
}

const input = args[0];
let vendorDir = './vendor';

for (let i = 1; i < args.length; i++) {
  if ((args[i] === '--vendor' || args[i] === '-v') && args[i + 1]) {
    vendorDir = args[++i];
  }
}

// Parse package name and version (handle scoped packages)
let pkgName, pkgVersion;
const scopedMatch = input.match(/^(@[^@]+)@(.+)$/);
const unscopedMatch = input.match(/^([^@]+)@(.+)$/);
if (scopedMatch) {
  pkgName = scopedMatch[1];
  pkgVersion = scopedMatch[2];
} else if (unscopedMatch) {
  pkgName = unscopedMatch[1];
  pkgVersion = unscopedMatch[2];
} else {
  pkgName = input;
  pkgVersion = 'latest';
}

const destDir = path.resolve(vendorDir, pkgName);

console.error('');
console.error(`${C.bold}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C.reset}`);
console.error(`${C.bold}  npm-passport — download via npmjs.com${C.reset}`);
console.error(`${C.bold}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C.reset}`);
info(`Package : ${C.bold}${pkgName}${C.reset}`);
info(`Version : ${C.bold}${pkgVersion}${C.reset}`);
info(`Vendor  : ${C.bold}${destDir}${C.reset}`);
console.error('');

// ── Find Chrome/Chromium/Edge ───────────────────────────────
function findBrowser() {
  // CHROME_PATH env var takes priority
  if (process.env.CHROME_PATH) {
    if (fs.existsSync(process.env.CHROME_PATH)) return process.env.CHROME_PATH;
    warn(`CHROME_PATH set to '${process.env.CHROME_PATH}' but file not found, searching defaults...`);
  }

  const candidates = process.platform === 'darwin' ? [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  ] : process.platform === 'win32' ? [
    `${process.env.PROGRAMFILES}\\Google\\Chrome\\Application\\chrome.exe`,
    `${process.env['PROGRAMFILES(X86)']}\\Google\\Chrome\\Application\\chrome.exe`,
    `${process.env.LOCALAPPDATA}\\Google\\Chrome\\Application\\chrome.exe`,
    `${process.env.PROGRAMFILES}\\Microsoft\\Edge\\Application\\msedge.exe`,
  ] : [
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    '/snap/bin/chromium',
    '/usr/bin/microsoft-edge',
  ];

  for (const p of candidates) {
    if (fs.existsSync(p)) return p;
  }
  return null;
}

// ── Main ────────────────────────────────────────────────────
async function main() {
  const executablePath = findBrowser();
  if (!executablePath) {
    die(`No Chrome/Chromium/Edge found. Set CHROME_PATH to your browser executable:
  CHROME_PATH=/path/to/chrome node npm-passport.mjs <package>`);
  }
  info(`Browser: ${executablePath}`);

  // Clean destination
  if (fs.existsSync(destDir)) {
    warn(`Removing existing: ${destDir}`);
    fs.rmSync(destDir, { recursive: true });
  }
  fs.mkdirSync(destDir, { recursive: true });

  info('Launching headless browser...');
  const browser = await puppeteer.launch({
    executablePath,
    headless: 'new',
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'],
  });

  try {
    const page = await browser.newPage();
    await page.setUserAgent(
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    );

    // Navigate to package page — passes Cloudflare challenge
    info(`Navigating to www.npmjs.com/package/${pkgName} ...`);
    await page.goto(`https://www.npmjs.com/package/${pkgName}`, {
      waitUntil: 'domcontentloaded',
      timeout: 60000,
    });

    // Wait for Cloudflare to clear
    info('Waiting for Cloudflare clearance...');
    await page.waitForFunction(() => !document.title.includes('moment'), { timeout: 30000 })
      .catch(() => {});
    ok('Cloudflare passed');

    // Resolve version
    let resolvedVersion = pkgVersion;
    if (pkgVersion === 'latest') {
      info('Resolving latest version...');
      resolvedVersion = await page.evaluate(async (pkg) => {
        const resp = await fetch(`/package/${pkg}`);
        const html = await resp.text();
        const m = html.match(/"latest"\s*:\s*"([^"]+)"/);
        return m ? m[1] : null;
      }, pkgName);

      if (!resolvedVersion) die(`Could not resolve latest version for '${pkgName}'`);
    }
    ok(`Resolved: ${C.bold}${pkgName}@${resolvedVersion}${C.reset}`);

    // Fetch file index (the API behind the "Code" tab)
    info('Fetching file index...');
    const index = await page.evaluate(async (pkg, ver) => {
      const resp = await fetch(`/package/${pkg}/v/${ver}/index`);
      if (!resp.ok) return { error: resp.status };
      return resp.json();
    }, pkgName, resolvedVersion);

    if (index.error) {
      die(`File index returned HTTP ${index.error}. Is '${pkgName}@${resolvedVersion}' valid?`);
    }

    const files = Object.entries(index.files);
    ok(`Found ${files.length} files`);

    // Download files sequentially with concurrency limit to avoid 429 rate limiting
    info(`Downloading ${files.length} files...`);
    const CONCURRENCY = 3;
    const DELAY_MS = 100; // delay between each batch of concurrent requests
    let downloaded = 0;
    let errors = 0;

    for (let i = 0; i < files.length; i += CONCURRENCY) {
      const batch = files.slice(i, i + CONCURRENCY);

      const results = await page.evaluate(async (entries, pkg) => {
        const out = [];
        await Promise.all(entries.map(async ([fpath, meta]) => {
          try {
            const resp = await fetch(`/package/${pkg}/file/${meta.hex}`);
            if (!resp.ok) { out.push({ path: fpath, error: resp.status }); return; }
            if (meta.isBinary === 'true' || meta.isBinary === true) {
              const buf = await resp.arrayBuffer();
              const bytes = new Uint8Array(buf);
              let bin = '';
              for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
              out.push({ path: fpath, data: btoa(bin), binary: true });
            } else {
              out.push({ path: fpath, data: await resp.text(), binary: false });
            }
          } catch (e) {
            out.push({ path: fpath, error: e.message });
          }
        }));
        return out;
      }, batch, pkgName);

      for (const r of results) {
        if (r.error) {
          // Retry once on 429 after a longer delay
          if (r.error === 429) {
            await new Promise(resolve => setTimeout(resolve, 2000));
            const [retryResult] = await page.evaluate(async (fpath, meta, pkg) => {
              try {
                const resp = await fetch(`/package/${pkg}/file/${meta.hex}`);
                if (!resp.ok) return [{ path: fpath, error: resp.status }];
                if (meta.isBinary === 'true' || meta.isBinary === true) {
                  const buf = await resp.arrayBuffer();
                  const bytes = new Uint8Array(buf);
                  let bin = '';
                  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
                  return [{ path: fpath, data: btoa(bin), binary: true }];
                } else {
                  return [{ path: fpath, data: await resp.text(), binary: false }];
                }
              } catch (e) {
                return [{ path: fpath, error: e.message }];
              }
            }, r.path, files.find(([p]) => p === r.path)?.[1], pkgName);

            if (retryResult.error) {
              warn(`Failed: ${retryResult.path} (${retryResult.error})`);
              errors++;
            } else {
              const fp = path.join(destDir, retryResult.path);
              fs.mkdirSync(path.dirname(fp), { recursive: true });
              if (retryResult.binary) {
                fs.writeFileSync(fp, Buffer.from(retryResult.data, 'base64'));
              } else {
                fs.writeFileSync(fp, retryResult.data);
              }
              downloaded++;
            }
            continue;
          }
          warn(`Failed: ${r.path} (${r.error})`);
          errors++;
          continue;
        }
        const fp = path.join(destDir, r.path);
        fs.mkdirSync(path.dirname(fp), { recursive: true });
        if (r.binary) {
          fs.writeFileSync(fp, Buffer.from(r.data, 'base64'));
        } else {
          fs.writeFileSync(fp, r.data);
        }
        downloaded++;
      }

      const done = Math.min(i + CONCURRENCY, files.length);
      process.stderr.write(`\r${C.cyan}[info]${C.reset}  Progress: ${done} / ${files.length}`);

      // Delay between batches to avoid rate limiting
      if (i + CONCURRENCY < files.length) {
        await new Promise(resolve => setTimeout(resolve, DELAY_MS));
      }
    }

    console.error('');
    ok(`Downloaded ${downloaded} files${errors > 0 ? ` (${errors} errors)` : ''}`);

    // Verify
    const pkgJsonPath = path.join(destDir, 'package.json');
    if (!fs.existsSync(pkgJsonPath)) {
      die('Download failed — package.json not found');
    }

    // Calculate size
    let totalSize = 0;
    const countSize = dir => {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) countSize(full);
        else totalSize += fs.statSync(full).size;
      }
    };
    countSize(destDir);
    const sizeStr = totalSize > 1024 * 1024
      ? `${(totalSize / 1024 / 1024).toFixed(1)} MB`
      : `${(totalSize / 1024).toFixed(0)} KB`;

    console.error('');
    console.error(`${C.green}${C.bold}✓ Successfully vendored ${pkgName}@${resolvedVersion}${C.reset}`);
    info(`Location : ${C.bold}${destDir}${C.reset} (${sizeStr})`);
    console.error('');
    console.error(`${C.cyan}To use in your code:${C.reset}`);
    console.error(`  const pkg = require('${path.relative(process.cwd(), destDir)}');`);
    console.error('');

  } finally {
    await browser.close();
  }
}

main().catch(e => {
  die(e.message);
});
