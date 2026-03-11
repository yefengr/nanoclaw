#!/usr/bin/env bash
set -euo pipefail

# NanoClaw one-line installer
# Usage: curl -fsSL https://raw.githubusercontent.com/qwibitai/nanoclaw/main/install.sh | bash

NANOCLAW_HOME="${NANOCLAW_HOME:-$HOME/.nanoclaw}"
REPO="qwibitai/nanoclaw"
MIN_NODE=20

# ── helpers ──────────────────────────────────────────────────────────

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

check_command() {
  command -v "$1" >/dev/null 2>&1
}

# ── preflight checks ────────────────────────────────────────────────

info "Checking prerequisites..."

# Node.js
if ! check_command node; then
  error "Node.js is required but not installed. Install Node.js >= ${MIN_NODE} first: https://nodejs.org"
fi

NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
if [ "$NODE_MAJOR" -lt "$MIN_NODE" ]; then
  error "Node.js >= ${MIN_NODE} required (found v$(node -v)). Please upgrade."
fi

# npm
if ! check_command npm; then
  error "npm is required but not installed."
fi

# Container runtime
CONTAINER_RUNTIME=""
if check_command container; then
  CONTAINER_RUNTIME="apple-container"
elif check_command docker; then
  CONTAINER_RUNTIME="docker"
else
  warn "No container runtime found. Install Docker (https://docker.com) or Apple Container (macOS)."
  warn "You can continue installation but agents won't run without a container runtime."
fi

info "Node.js v$(node -p process.versions.node), npm v$(npm -v), container: ${CONTAINER_RUNTIME:-none}"

# ── download release ─────────────────────────────────────────────────

info "Fetching latest release from ${REPO}..."

RELEASE_URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.tar\.gz"' \
  | head -1 \
  | cut -d'"' -f4)

if [ -z "$RELEASE_URL" ]; then
  error "Could not find a release tarball. Check https://github.com/${REPO}/releases"
fi

TMPDIR_DL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_DL"' EXIT

info "Downloading ${RELEASE_URL}..."
curl -fsSL "$RELEASE_URL" -o "${TMPDIR_DL}/nanoclaw.tar.gz"

# ── install ──────────────────────────────────────────────────────────

info "Installing to ${NANOCLAW_HOME}..."
mkdir -p "$NANOCLAW_HOME"

# Extract — strip the top-level directory from the tarball
tar -xzf "${TMPDIR_DL}/nanoclaw.tar.gz" --strip-components=1 -C "$NANOCLAW_HOME"

# Install production dependencies (better-sqlite3 native addon + tsx)
info "Installing dependencies..."
(cd "$NANOCLAW_HOME" && npm install --production 2>&1 | tail -3)

# Create runtime directories
mkdir -p "$NANOCLAW_HOME"/{groups,data,store}

# Copy .env template if not present
if [ ! -f "$NANOCLAW_HOME/.env" ]; then
  cp "$NANOCLAW_HOME/.env.example" "$NANOCLAW_HOME/.env"
  info "Created .env from template — edit it to add your credentials."
fi

# ── create wrapper scripts ───────────────────────────────────────────

mkdir -p "$NANOCLAW_HOME/bin"

cat > "$NANOCLAW_HOME/bin/nanoclaw" <<'WRAPPER'
#!/usr/bin/env bash
export NANOCLAW_HOME="${NANOCLAW_HOME:-$HOME/.nanoclaw}"
exec node "$NANOCLAW_HOME/dist/index.js" "$@"
WRAPPER
chmod +x "$NANOCLAW_HOME/bin/nanoclaw"

cat > "$NANOCLAW_HOME/bin/nanoclaw-setup" <<'SETUP'
#!/usr/bin/env bash
export NANOCLAW_HOME="${NANOCLAW_HOME:-$HOME/.nanoclaw}"
cd "$NANOCLAW_HOME" && exec npx tsx setup/index.ts "$@"
SETUP
chmod +x "$NANOCLAW_HOME/bin/nanoclaw-setup"

# ── done ─────────────────────────────────────────────────────────────

info "NanoClaw installed to ${NANOCLAW_HOME}"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Add to your PATH (add to ~/.bashrc or ~/.zshrc):"
echo ""
echo "     export PATH=\"${NANOCLAW_HOME}/bin:\$PATH\""
echo ""
echo "  2. Run setup to configure channels and authentication:"
echo ""
echo "     nanoclaw-setup"
echo ""
echo "  3. Start NanoClaw:"
echo ""
echo "     nanoclaw"
echo ""
