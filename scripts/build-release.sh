#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(node -p "require('./package.json').version")
RELEASE_NAME="nanoclaw-v${VERSION}"
TMPDIR=$(mktemp -d)
STAGE="${TMPDIR}/${RELEASE_NAME}"

echo "==> Building bundle..."
node esbuild.config.mjs

echo "==> Staging release ${RELEASE_NAME}..."
mkdir -p "${STAGE}/dist" "${STAGE}/container" "${STAGE}/setup"

# Bundle output
cp dist/index.js dist/index.js.map "${STAGE}/dist/"

# Container build context (agent images)
cp -r container/ "${STAGE}/container/"

# Setup wizard (runs via tsx at install time)
cp -r setup/ "${STAGE}/setup/"

# Install script
cp install.sh "${STAGE}/"

# Env template
cp .env.example "${STAGE}/"

# Minimal package.json — only runtime deps that can't be bundled
cat > "${STAGE}/package.json" <<PKGJSON
{
  "name": "nanoclaw",
  "version": "${VERSION}",
  "type": "module",
  "main": "dist/index.js",
  "scripts": {
    "start": "node dist/index.js",
    "setup": "npx tsx setup/index.ts"
  },
  "dependencies": {
    "better-sqlite3": "^11.8.1",
    "pino": "^9.6.0",
    "pino-pretty": "^13.0.0",
    "tsx": "^4.19.0"
  },
  "engines": {
    "node": ">=20"
  }
}
PKGJSON

# Build tarball
echo "==> Creating tarball..."
tar -czf "${RELEASE_NAME}.tar.gz" -C "${TMPDIR}" "${RELEASE_NAME}"
rm -rf "${TMPDIR}"

SIZE=$(du -h "${RELEASE_NAME}.tar.gz" | cut -f1)
echo "==> Done: ${RELEASE_NAME}.tar.gz (${SIZE})"
