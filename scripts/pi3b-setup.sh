#!/usr/bin/env bash
# pi3b-setup.sh - OpenClaw optimization script for Raspberry Pi 3B+ (1GB RAM)
# Usage: bash scripts/pi3b-setup.sh
set -euo pipefail

echo "=== OpenClaw Pi 3B+ Optimization Setup ==="
echo ""

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
  echo "ERROR: This script requires 64-bit ARM (aarch64)."
  echo "Your architecture: $ARCH"
  echo "Please install Raspberry Pi OS Lite (64-bit)."
  exit 1
fi

echo "[1/7] Checking swap..."
SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
if [ "$SWAP_TOTAL" -lt 1024 ]; then
  echo "  Setting up 2GB swap file..."
  sudo fallocate -l 2G /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  if ! grep -q '/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  fi
  if ! grep -q 'vm.swappiness=10' /etc/sysctl.conf; then
    echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p
  fi
  echo "  Swap configured: 2GB"
else
  echo "  Swap already sufficient: ${SWAP_TOTAL}MB"
fi

echo ""
echo "[2/7] Reducing GPU memory allocation..."
if [ -f /boot/config.txt ]; then
  if ! grep -q 'gpu_mem=16' /boot/config.txt; then
    echo 'gpu_mem=16' | sudo tee -a /boot/config.txt
    echo "  Set gpu_mem=16 (reboot required)"
  else
    echo "  Already set"
  fi
elif [ -f /boot/firmware/config.txt ]; then
  if ! grep -q 'gpu_mem=16' /boot/firmware/config.txt; then
    echo 'gpu_mem=16' | sudo tee -a /boot/firmware/config.txt
    echo "  Set gpu_mem=16 (reboot required)"
  else
    echo "  Already set"
  fi
else
  echo "  WARN: /boot/config.txt not found, skipping"
fi

echo ""
echo "[3/7] Disabling unnecessary services..."
for svc in bluetooth cups avahi-daemon triggerhappy ModemManager; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    sudo systemctl disable --now "$svc" 2>/dev/null && echo "  Disabled: $svc" || true
  fi
done

echo ""
echo "[4/7] Installing optimized OpenClaw config..."
OPENCLAW_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
mkdir -p "$OPENCLAW_DIR"

CONFIG_FILE="$OPENCLAW_DIR/openclaw.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -f "$CONFIG_FILE" ]; then
  echo "  WARN: $CONFIG_FILE already exists"
  echo "  Backing up to $CONFIG_FILE.bak"
  cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
fi

if [ -f "$SCRIPT_DIR/pi3b-openclaw-config.json" ]; then
  cp "$SCRIPT_DIR/pi3b-openclaw-config.json" "$CONFIG_FILE"
  echo "  Installed optimized config to $CONFIG_FILE"
else
  echo "  WARN: pi3b-openclaw-config.json not found in project root"
  echo "  Please copy it manually to $CONFIG_FILE"
fi

echo ""
echo "[5/7] Setting up environment variables..."
ENV_FILE="$OPENCLAW_DIR/.env"
if [ ! -f "$ENV_FILE" ] || ! grep -q 'OPENCLAW_SKIP_BROWSER_CONTROL_SERVER' "$ENV_FILE"; then
  cat >> "$ENV_FILE" << 'ENVEOF'

# Pi 3B+ optimizations
OPENCLAW_SKIP_BROWSER_CONTROL_SERVER=1
OPENCLAW_SKIP_CANVAS_HOST=1
OPENCLAW_SKIP_GMAIL_WATCHER=1
OPENCLAW_SKIP_CRON=1
OPENCLAW_DISABLE_BONJOUR=1
NODE_OPTIONS=--max-old-space-size=384

# API key para embeddings remotos (memoria vetorial)
# Descomente e configure UMA das opcoes abaixo:
# OPENAI_API_KEY=sk-sua-chave-aqui
# GOOGLE_API_KEY=sua-chave-gemini-aqui
ENVEOF
  echo "  Environment variables added to $ENV_FILE"
  echo ""
  echo "  IMPORTANTE: Edite $ENV_FILE e configure sua API key"
  echo "  para embeddings (OPENAI_API_KEY ou GOOGLE_API_KEY)"
  echo "  A memoria vetorial precisa disso para lembrar do usuario."
else
  echo "  Environment already configured"
fi

echo ""
echo "[6/7] Setting up systemd service..."
SERVICE_FILE="/etc/systemd/system/openclaw-pi.service"
OPENCLAW_BIN=$(which openclaw 2>/dev/null || echo "/usr/local/bin/openclaw")
NODE_BIN=$(which node 2>/dev/null || echo "/usr/bin/node")

if [ ! -f "$SERVICE_FILE" ]; then
  sudo tee "$SERVICE_FILE" > /dev/null << SVCEOF
[Unit]
Description=OpenClaw Gateway (Pi 3B+ Optimized)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME

MemoryMax=512M
MemoryHigh=400M
CPUQuota=80%
LimitNOFILE=4096
LimitNPROC=128

Environment=NODE_OPTIONS=--max-old-space-size=384
Environment=OPENCLAW_SKIP_BROWSER_CONTROL_SERVER=1
Environment=OPENCLAW_SKIP_CANVAS_HOST=1
Environment=OPENCLAW_SKIP_GMAIL_WATCHER=1
Environment=OPENCLAW_SKIP_CRON=1
Environment=OPENCLAW_DISABLE_BONJOUR=1
Environment=NODE_ENV=production

ExecStart=$NODE_BIN $SCRIPT_DIR/openclaw.mjs gateway --allow-unconfigured
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

  sudo systemctl daemon-reload
  echo "  Service installed: openclaw-pi"
  echo "  Enable with: sudo systemctl enable --now openclaw-pi"
else
  echo "  Service already exists"
fi

echo ""
echo "[7/7] Summary"
echo ""
echo "  RAM total: $(free -h | awk '/Mem:/ {print $2}')"
echo "  Swap total: $(free -h | awk '/Swap:/ {print $2}')"
echo "  Architecture: $ARCH"
echo "  Node.js: $(node --version 2>/dev/null || echo 'not installed')"
echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit ~/.openclaw/.env and set OPENAI_API_KEY or GOOGLE_API_KEY"
echo "     (needed for vector memory - remembering users)"
echo "  2. Reboot to apply gpu_mem change: sudo reboot"
echo "  3. After reboot, start OpenClaw: sudo systemctl enable --now openclaw-pi"
echo "  4. Check status: sudo systemctl status openclaw-pi"
echo "  5. View logs: journalctl -u openclaw-pi -f"
echo ""
echo "Features enabled:"
echo "  - Thinking (low): reasoning via remote API (0 MB local)"
echo "  - Vector memory: embeddings via OpenAI/Gemini API (30-80 MB local)"
echo "  - SQLite + sqlite-vec: local vector storage"
echo ""
echo "Expected RAM usage: ~370-550MB (within 1GB + 2GB swap)"
