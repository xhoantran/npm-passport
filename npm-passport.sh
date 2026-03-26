#!/usr/bin/env bash
# ============================================================
# npm-passport.sh
# Downloads npm packages via npmjs.com/package and extracts
# them into a local ./vendor/<package-name>/ folder.
# Use when registry.npmjs.org is blocked by enterprise firewall.
#
# Usage:
#   ./npm-passport.sh <package-name>
#   ./npm-passport.sh <package-name>@<version>
#   ./npm-passport.sh <package-name>[@version] --vendor /path/to/vendor
#
# Examples:
#   ./npm-passport.sh lodash
#   ./npm-passport.sh lodash@4.17.21
#   ./npm-passport.sh @types/node@18.0.0
#   ./npm-passport.sh express --vendor ./lib/vendor
# ============================================================

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helpers ──────────────────────────────────────────────────
info()    { echo -e "${CYAN}[info]${RESET}  $*"; }
success() { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET}  $*"; }
die()     { echo -e "${RED}[error]${RESET} $*" >&2; exit 1; }

# ── Dependency check ─────────────────────────────────────────
require() {
  command -v "$1" &>/dev/null || die "'$1' is required but not installed. Please install it first."
}
require curl
require npm
require node

# ── Parse arguments ──────────────────────────────────────────
[[ $# -lt 1 ]] && die "Usage: $0 <package-name>[@version] [--vendor <dir>]\nExample: $0 lodash@4.17.21 --vendor ./vendor"

INPUT="$1"
shift

# Default vendor directory
VENDOR_DIR="./vendor"

# Parse remaining flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vendor|-v)
      [[ -z "${2:-}" ]] && die "--vendor requires a directory path"
      VENDOR_DIR="$2"
      shift 2
      ;;
    *)
      warn "Unknown argument: $1 (ignoring)"
      shift
      ;;
  esac
done

# Handle scoped packages like @types/node@18.0.0
# Split on the LAST @ that isn't the first character
if [[ "$INPUT" =~ ^(@[^@]+)@(.+)$ ]]; then
  # Scoped package with version: @scope/name@version
  PKG_NAME="${BASH_REMATCH[1]}"
  PKG_VERSION="${BASH_REMATCH[2]}"
elif [[ "$INPUT" =~ ^([^@]+)@(.+)$ ]]; then
  # Unscoped package with version: name@version
  PKG_NAME="${BASH_REMATCH[1]}"
  PKG_VERSION="${BASH_REMATCH[2]}"
else
  # No version specified — fetch latest
  PKG_NAME="$INPUT"
  PKG_VERSION="latest"
fi

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  npm install bypass — via npmjs.com${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
info "Package : ${BOLD}${PKG_NAME}${RESET}"
info "Version : ${BOLD}${PKG_VERSION}${RESET}"
info "Vendor  : ${BOLD}${VENDOR_DIR}${RESET}"
echo ""

# ── Resolve exact version + tarball URL via registry API ─────
# NOTE: We use the npmjs.com/package page CDN path, NOT registry.npmjs.org.
# The package metadata JSON is served from:
#   https://www.npmjs.com/package/<name> (HTML page, blocked sometimes)
# Better: use the public CDN that npmjs.com itself uses for metadata:
#   https://cdn.jsdelivr.net/npm/<pkg>/package.json  (metadata mirror)
# Or: use the registry endpoint that may be on a different hostname
#   https://registry.npmjs.com  (note: .com not .org — often different routing)
#
# Strategy (tries in order until one works):
#   1. registry.npmjs.com (different host from .org, may pass firewall)
#   2. cdn.jsdelivr.net   (popular CDN mirror of npm packages)
#   3. unpkg.com          (another CDN mirror)

TMPDIR_PKG=$(mktemp -d)
trap 'rm -rf "$TMPDIR_PKG"' EXIT

resolve_metadata() {
  local pkg="$1"
  local ver="$2"
  local meta=""

  # URL-encode scoped package name for HTTP requests
  local encoded_pkg="${pkg/@/%40}"
  encoded_pkg="${encoded_pkg//\//%2F}"

  info "Resolving package metadata..."

  # Attempt 1: registry.npmjs.com (different subdomain/host from .org)
  if meta=$(curl -fsSL --max-time 10 "https://registry.npmjs.com/${pkg}" 2>/dev/null); then
    info "  ✓ Reached registry.npmjs.com"
    echo "$meta"
    return 0
  fi
  warn "  ✗ registry.npmjs.com unreachable, trying CDN fallback..."

  # Attempt 2: jsDelivr CDN (serves package.json per version)
  # For full registry metadata we need a different approach via jsDelivr's npm API
  if meta=$(curl -fsSL --max-time 10 "https://data.jsdelivr.com/v1/packages/npm/${pkg}" 2>/dev/null); then
    # jsDelivr returns its own format — convert to something we can parse
    # We'll use it only to discover the resolved version, then build the tarball URL manually
    info "  ✓ Reached data.jsdelivr.com"
    # Extract version list and pick requested or latest
    if [[ "$ver" == "latest" ]]; then
      RESOLVED_VERSION=$(echo "$meta" | node -e "
        let d=''; process.stdin.on('data',c=>d+=c).on('end',()=>{
          try {
            const j=JSON.parse(d);
            const tags=j.tags||{};
            console.log(tags.latest || j.versions?.[0]?.version || '');
          } catch(e){ console.log(''); }
        });
      ")
    else
      RESOLVED_VERSION="$ver"
    fi
    echo "JSDELIVR:${RESOLVED_VERSION}"
    return 0
  fi
  warn "  ✗ data.jsdelivr.com unreachable, trying unpkg..."

  # Attempt 3: unpkg.com — fetch package.json to get version
  if meta=$(curl -fsSL --max-time 10 "https://unpkg.com/${pkg}@${ver}/package.json" 2>/dev/null); then
    info "  ✓ Reached unpkg.com"
    RESOLVED_VERSION=$(echo "$meta" | node -e "
      let d=''; process.stdin.on('data',c=>d+=c).on('end',()=>{
        try { console.log(JSON.parse(d).version||''); } catch(e){ console.log(''); }
      });
    ")
    echo "UNPKG:${RESOLVED_VERSION}"
    return 0
  fi

  die "Could not reach any npm metadata source. Check your network/proxy settings."
}

# ── Resolve metadata ─────────────────────────────────────────
META_RESULT=$(resolve_metadata "$PKG_NAME" "$PKG_VERSION")

# ── Determine download URL ────────────────────────────────────
TARBALL_URL=""
RESOLVED_VERSION=""

if echo "$META_RESULT" | grep -q "^JSDELIVR:"; then
  RESOLVED_VERSION="${META_RESULT#JSDELIVR:}"
  [[ -z "$RESOLVED_VERSION" ]] && die "Could not resolve version for '$PKG_NAME'"
  # jsDelivr serves tarballs at: https://registry.npmjs.org/<pkg>/-/<pkg>-<ver>.tgz
  # But .org is blocked. Use jsDelivr's own CDN tarball proxy instead:
  # https://cdn.jsdelivr.net/npm/<pkg>@<ver>  (no tarball, just files)
  # Fall through to unpkg for actual tarball download
  warn "Using unpkg for tarball download (jsDelivr doesn't proxy full tarballs)..."
  TARBALL_URL="https://unpkg.com/${PKG_NAME}@${RESOLVED_VERSION}/${PKG_NAME}-${RESOLVED_VERSION}.tgz"
  # Actually unpkg doesn't serve tarballs either. Use their CDN + repack approach below.
  DOWNLOAD_METHOD="repack"

elif echo "$META_RESULT" | grep -q "^UNPKG:"; then
  RESOLVED_VERSION="${META_RESULT#UNPKG:}"
  [[ -z "$RESOLVED_VERSION" ]] && die "Could not resolve version for '$PKG_NAME'"
  DOWNLOAD_METHOD="repack"

else
  # Full registry metadata received from registry.npmjs.com
  # Parse tarball URL out of the metadata JSON
  RESOLVED_VERSION=$(echo "$META_RESULT" | node -e "
    let d=''; process.stdin.on('data',c=>d+=c).on('end',()=>{
      try {
        const j=JSON.parse(d);
        const ver='${PKG_VERSION}'==='latest' ? j['dist-tags']?.latest : '${PKG_VERSION}';
        console.log(ver||'');
      } catch(e){ console.log(''); }
    });
  ")
  [[ -z "$RESOLVED_VERSION" ]] && die "Could not resolve version '${PKG_VERSION}' for '${PKG_NAME}'"

  TARBALL_URL=$(echo "$META_RESULT" | node -e "
    let d=''; process.stdin.on('data',c=>d+=c).on('end',()=>{
      try {
        const j=JSON.parse(d);
        const ver='${RESOLVED_VERSION}';
        const url=j.versions?.[ver]?.dist?.tarball||'';
        // Rewrite .org to .com if needed
        console.log(url.replace('registry.npmjs.org','registry.npmjs.com'));
      } catch(e){ console.log(''); }
    });
  ")
  DOWNLOAD_METHOD="direct"
fi

success "Resolved version: ${BOLD}${PKG_NAME}@${RESOLVED_VERSION}${RESET}"

# ── Download the tarball ──────────────────────────────────────
TARBALL_FILE="${TMPDIR_PKG}/package.tgz"

if [[ "$DOWNLOAD_METHOD" == "direct" ]] && [[ -n "$TARBALL_URL" ]]; then
  info "Downloading tarball from: $TARBALL_URL"
  if ! curl -fsSL --max-time 60 --progress-bar -o "$TARBALL_FILE" "$TARBALL_URL"; then
    warn "Direct tarball download failed, falling back to repack method..."
    DOWNLOAD_METHOD="repack"
  fi
fi

if [[ "$DOWNLOAD_METHOD" == "repack" ]]; then
  # Repack: download all package files from unpkg.com and create a tarball
  info "Downloading package files from unpkg.com and repacking..."

  REPACK_DIR="${TMPDIR_PKG}/package"
  mkdir -p "$REPACK_DIR"

  # Fetch the file listing from unpkg
  LISTING=$(curl -fsSL --max-time 15 "https://unpkg.com/${PKG_NAME}@${RESOLVED_VERSION}/?meta" 2>/dev/null) || \
    die "Could not fetch file listing from unpkg.com for ${PKG_NAME}@${RESOLVED_VERSION}"

  # Extract file paths from the JSON listing
  FILE_PATHS=$(echo "$LISTING" | node -e "
    let d=''; process.stdin.on('data',c=>d+=c).on('end',()=>{
      try {
        const walk=(node,base='')=>{
          if(node.type==='file') return [base+'/'+node.path.replace(/^\//,'')];
          return (node.files||[]).flatMap(f=>walk(f,base));
        };
        const j=JSON.parse(d);
        walk(j).forEach(p=>console.log(p.replace(/^\/\//,'/')));
      } catch(e){ process.exit(1); }
    });
  ") || die "Failed to parse unpkg file listing"

  TOTAL=$(echo "$FILE_PATHS" | wc -l | tr -d ' ')
  info "Downloading ${TOTAL} files..."

  COUNT=0
  while IFS= read -r fpath; do
    [[ -z "$fpath" ]] && continue
    local_path="${REPACK_DIR}${fpath}"
    mkdir -p "$(dirname "$local_path")"
    curl -fsSL --max-time 30 \
      -o "$local_path" \
      "https://unpkg.com/${PKG_NAME}@${RESOLVED_VERSION}${fpath}" 2>/dev/null || \
      warn "  Could not download: $fpath (skipping)"
    COUNT=$((COUNT + 1))
    printf "\r  ${CYAN}Progress:${RESET} %d / %d" "$COUNT" "$TOTAL"
  done <<< "$FILE_PATHS"
  echo ""

  # Ensure package.json exists
  [[ -f "${REPACK_DIR}/package.json" ]] || \
    curl -fsSL -o "${REPACK_DIR}/package.json" \
      "https://unpkg.com/${PKG_NAME}@${RESOLVED_VERSION}/package.json" || \
    die "Could not download package.json"

  # Create tarball
  info "Creating tarball..."
  (cd "$TMPDIR_PKG" && tar -czf package.tgz package/) || die "Failed to create tarball"
fi

# ── Verify tarball ────────────────────────────────────────────
[[ -f "$TARBALL_FILE" ]] || die "Tarball not found at expected path"
TARBALL_SIZE=$(du -sh "$TARBALL_FILE" | cut -f1)
success "Tarball ready (${TARBALL_SIZE}): $TARBALL_FILE"

# ── Extract into vendor folder ────────────────────────────────
# Scoped packages (@scope/name) go into vendor/@scope/name/
# to match how node_modules handles them.
DEST_DIR="${VENDOR_DIR}/${PKG_NAME}"

info "Extracting into: ${BOLD}${DEST_DIR}${RESET}"

# Remove previous install of same package if present
if [[ -d "$DEST_DIR" ]]; then
  warn "Removing existing: $DEST_DIR"
  rm -rf "$DEST_DIR"
fi

mkdir -p "$DEST_DIR"

# npm tarballs always contain a top-level "package/" directory — strip it
tar -xzf "$TARBALL_FILE" -C "$DEST_DIR" --strip-components=1

# Verify extraction worked
[[ -f "${DEST_DIR}/package.json" ]] || die "Extraction failed — package.json not found in ${DEST_DIR}"

EXTRACTED_SIZE=$(du -sh "$DEST_DIR" | cut -f1)

echo ""
echo -e "${GREEN}${BOLD}✓ Successfully vendored ${PKG_NAME}@${RESOLVED_VERSION}${RESET}"
info "Location : ${BOLD}${DEST_DIR}${RESET} (${EXTRACTED_SIZE})"
echo ""
echo -e "${CYAN}To use in your code:${RESET}"
# Suggest require path based on whether it's a scoped pkg or not
echo -e "  const pkg = require('${DEST_DIR}');"
echo ""
