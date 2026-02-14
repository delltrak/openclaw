#!/usr/bin/env bash
# pi3b-install.sh - Complete OpenClaw installation for Raspberry Pi 3B+
#
# Supports: DietPi, Raspberry Pi OS Lite, Ubuntu Server (aarch64)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/.../scripts/pi3b-install.sh | bash
#   # OR
#   bash scripts/pi3b-install.sh
#
# Environment variables (optional, set before running):
#   OPENCLAW_BRANCH=main              # Git branch to install
#   OPENCLAW_DIR=/opt/openclaw        # Installation directory
#   OPENAI_API_KEY=sk-...             # For vector memory embeddings
#   ANTHROPIC_API_KEY=sk-ant-...      # For the main LLM model
#   OPENCLAW_CHANNEL=telegram         # Which channel to configure (telegram|whatsapp)
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
OPENCLAW_BRANCH="${OPENCLAW_BRANCH:-main}"
OPENCLAW_DIR="${OPENCLAW_DIR:-/opt/openclaw}"
OPENCLAW_CONFIG_DIR="${HOME}/.openclaw"
OPENCLAW_REPO="https://github.com/nicholasgriffintn/openclaw.git"
NODE_MAJOR=22
REQUIRED_RAM_MB=800  # Minimum with swap

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

# ─── Pre-flight checks ──────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     OpenClaw Installer for Raspberry Pi 3B+         ║"
echo "║     DietPi / Pi OS Lite / Ubuntu Server             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# Check architecture
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" ]]; then
  err "This installer requires 64-bit ARM (aarch64)."
  err "Your architecture: $ARCH"
  err "Please install a 64-bit OS image."
  exit 1
fi
log "Architecture: $ARCH"

# Check RAM
TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
TOTAL_SWAP_MB=$(free -m | awk '/Swap:/ {print $2}')
TOTAL_AVAILABLE=$((TOTAL_RAM_MB + TOTAL_SWAP_MB))
if [[ "$TOTAL_AVAILABLE" -lt "$REQUIRED_RAM_MB" ]]; then
  warn "Only ${TOTAL_AVAILABLE}MB RAM+swap available (recommended: ${REQUIRED_RAM_MB}MB)"
  warn "Will attempt to set up swap during installation."
fi
log "RAM: ${TOTAL_RAM_MB}MB + Swap: ${TOTAL_SWAP_MB}MB"

# Detect OS
if [ -f /boot/dietpi/.version ]; then
  OS_TYPE="dietpi"
elif [ -f /etc/rpi-issue ]; then
  OS_TYPE="pios"
elif grep -qi ubuntu /etc/os-release 2>/dev/null; then
  OS_TYPE="ubuntu"
else
  OS_TYPE="debian"
fi
log "OS detected: $OS_TYPE"

# ─── Step 1: System preparation ─────────────────────────────────────────────
echo ""
info "Step 1/8: Preparing system..."

# Swap setup
if [[ "$TOTAL_SWAP_MB" -lt 1024 ]]; then
  info "Setting up 2GB swap..."
  if command -v zramctl &>/dev/null; then
    # Prefer zram (DietPi, modern kernels)
    sudo modprobe zram 2>/dev/null || true
    if [ -e /dev/zram0 ]; then
      sudo zramctl /dev/zram0 --size 2G --algorithm lz4 2>/dev/null || true
      sudo mkswap /dev/zram0 2>/dev/null || true
      sudo swapon -p 100 /dev/zram0 2>/dev/null || true
      log "zram swap enabled (2GB, lz4)"
    fi
  else
    # Fallback to swapfile
    if [ ! -f /swapfile ]; then
      sudo fallocate -l 2G /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
      sudo chmod 600 /swapfile
      sudo mkswap /swapfile
      sudo swapon /swapfile
      if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
      fi
      log "Swap file enabled (2GB)"
    fi
  fi
fi

# GPU memory
for cfg in /boot/config.txt /boot/firmware/config.txt; do
  if [ -f "$cfg" ] && ! grep -q 'gpu_mem=16' "$cfg"; then
    echo 'gpu_mem=16' | sudo tee -a "$cfg" > /dev/null
    log "GPU memory set to 16MB (reboot required)"
  fi
done

# Disable unnecessary services
for svc in bluetooth avahi-daemon triggerhappy ModemManager cups; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    sudo systemctl disable --now "$svc" 2>/dev/null || true
  fi
done
log "Unnecessary services disabled"

# ─── Step 2: Install system dependencies ─────────────────────────────────────
echo ""
info "Step 2/8: Installing system dependencies..."

sudo apt-get update -qq

# Build essentials for native addons (sharp, node-pty, sqlite-vec)
sudo apt-get install -y -qq \
  build-essential \
  python3 \
  git \
  curl \
  ca-certificates \
  gnupg

log "System dependencies installed"

# ─── Step 3: Install Node.js 22 LTS ─────────────────────────────────────────
echo ""
info "Step 3/8: Installing Node.js ${NODE_MAJOR}..."

if command -v node &>/dev/null; then
  CURRENT_NODE=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
  if [[ "$CURRENT_NODE" -ge "$NODE_MAJOR" ]]; then
    log "Node.js $(node --version) already installed"
  else
    warn "Node.js v${CURRENT_NODE} found, upgrading to v${NODE_MAJOR}..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
    sudo apt-get install -y -qq nodejs
  fi
else
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
  sudo apt-get install -y -qq nodejs
fi

log "Node.js: $(node --version)"
log "npm: $(npm --version)"

# ─── Step 4: Install pnpm ───────────────────────────────────────────────────
echo ""
info "Step 4/8: Installing pnpm..."

if ! command -v pnpm &>/dev/null; then
  npm install -g pnpm
fi
log "pnpm: $(pnpm --version)"

# ─── Step 5: Clone/update OpenClaw ──────────────────────────────────────────
echo ""
info "Step 5/8: Installing OpenClaw..."

if [ -d "$OPENCLAW_DIR/.git" ]; then
  info "Existing installation found, updating..."
  cd "$OPENCLAW_DIR"
  git fetch origin "$OPENCLAW_BRANCH"
  git checkout "$OPENCLAW_BRANCH"
  git pull origin "$OPENCLAW_BRANCH"
else
  info "Fresh install from $OPENCLAW_REPO (branch: $OPENCLAW_BRANCH)..."
  sudo mkdir -p "$(dirname "$OPENCLAW_DIR")"
  sudo chown "$USER:$USER" "$(dirname "$OPENCLAW_DIR")"
  git clone --depth 1 --branch "$OPENCLAW_BRANCH" "$OPENCLAW_REPO" "$OPENCLAW_DIR"
  cd "$OPENCLAW_DIR"
fi

log "Repository ready at $OPENCLAW_DIR"

# ─── Step 6: Build OpenClaw ─────────────────────────────────────────────────
echo ""
info "Step 6/8: Building OpenClaw (this takes a few minutes on Pi)..."

cd "$OPENCLAW_DIR"

# Install dependencies
pnpm install --frozen-lockfile 2>/dev/null || pnpm install
log "Dependencies installed"

# Build TypeScript
pnpm build
log "TypeScript build complete"

# Build UI (optional but useful for local web interface)
pnpm ui:build 2>/dev/null || warn "UI build skipped (non-critical)"

log "OpenClaw build complete"

# ─── Step 7: Configure OpenClaw ─────────────────────────────────────────────
echo ""
info "Step 7/8: Configuring OpenClaw..."

mkdir -p "$OPENCLAW_CONFIG_DIR"

# Install optimized Pi config
if [ -f "$OPENCLAW_DIR/pi3b-openclaw-config.json" ]; then
  if [ -f "$OPENCLAW_CONFIG_DIR/openclaw.json" ]; then
    cp "$OPENCLAW_CONFIG_DIR/openclaw.json" "$OPENCLAW_CONFIG_DIR/openclaw.json.bak"
    warn "Existing config backed up to openclaw.json.bak"
  fi
  cp "$OPENCLAW_DIR/pi3b-openclaw-config.json" "$OPENCLAW_CONFIG_DIR/openclaw.json"
  log "Pi-optimized config installed"
else
  warn "pi3b-openclaw-config.json not found, using defaults"
fi

# Environment variables
ENV_FILE="$OPENCLAW_CONFIG_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" << 'ENVEOF'
# ─── OpenClaw Pi 3B+ Environment ─────────────────────────────────────────
# REQUIRED: Set at least one LLM provider API key
# ANTHROPIC_API_KEY=sk-ant-your-key-here
# OPENAI_API_KEY=sk-your-key-here

# REQUIRED: Set one for vector memory (remembering users)
# OPENAI_API_KEY=sk-your-key-here
# GOOGLE_API_KEY=your-gemini-key-here

# Pi optimizations (do not change)
OPENCLAW_SKIP_BROWSER_CONTROL_SERVER=1
OPENCLAW_SKIP_CANVAS_HOST=1
OPENCLAW_SKIP_GMAIL_WATCHER=1
OPENCLAW_DISABLE_BONJOUR=1
NODE_OPTIONS=--max-old-space-size=384
ENVEOF
  log "Environment template created at $ENV_FILE"
else
  log "Environment file already exists"
fi

# Apply API keys from environment if provided
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  sed -i "s/^# ANTHROPIC_API_KEY=.*/ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY/" "$ENV_FILE"
  log "Anthropic API key configured"
fi
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  sed -i "s/^# OPENAI_API_KEY=.*/OPENAI_API_KEY=$OPENAI_API_KEY/" "$ENV_FILE"
  log "OpenAI API key configured"
fi

# ─── Step 8: Install systemd service ────────────────────────────────────────
echo ""
info "Step 8/8: Installing systemd service..."

SERVICE_FILE="/etc/systemd/system/openclaw.service"
sudo tee "$SERVICE_FILE" > /dev/null << SVCEOF
[Unit]
Description=OpenClaw Gateway (Pi 3B+ Optimized)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$OPENCLAW_DIR
EnvironmentFile=$OPENCLAW_CONFIG_DIR/.env

# Resource limits for 1GB Pi
MemoryMax=512M
MemoryHigh=400M
LimitNOFILE=4096
LimitNPROC=128

ExecStart=$(which node) $OPENCLAW_DIR/openclaw.mjs gateway --allow-unconfigured
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl daemon-reload
sudo systemctl enable openclaw
log "Systemd service installed and enabled"

# ─── Install update script ──────────────────────────────────────────────────
UPDATER="$OPENCLAW_DIR/scripts/pi3b-update.sh"
if [ -f "$UPDATER" ]; then
  sudo ln -sf "$UPDATER" /usr/local/bin/openclaw-update
  log "Update command installed: openclaw-update"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║             Installation Complete!                   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
log "OpenClaw installed at: $OPENCLAW_DIR"
log "Config at: $OPENCLAW_CONFIG_DIR/openclaw.json"
log "Env at: $OPENCLAW_CONFIG_DIR/.env"
log "Service: openclaw.service"
echo ""

if grep -q '^# ANTHROPIC_API_KEY' "$ENV_FILE" && grep -q '^# OPENAI_API_KEY' "$ENV_FILE"; then
  echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  IMPORTANT: You must configure your API keys!       ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "  Edit: $ENV_FILE"
  echo "  Set ANTHROPIC_API_KEY or OPENAI_API_KEY (for LLM)"
  echo "  Set OPENAI_API_KEY or GOOGLE_API_KEY (for memory)"
  echo ""
fi

echo "Next steps:"
echo "  1. Configure API keys:  nano $OPENCLAW_CONFIG_DIR/.env"
echo "  2. Start OpenClaw:      sudo systemctl start openclaw"
echo "  3. Check status:        sudo systemctl status openclaw"
echo "  4. View logs:           journalctl -u openclaw -f"
echo "  5. Update later:        openclaw-update"
echo ""
echo "Features enabled: thinking (low), vector memory, cron, messaging, coding"
echo "Expected RAM: ~335-550MB (DietPi) or ~370-550MB (Pi OS Lite)"
