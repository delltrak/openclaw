#!/usr/bin/env bash
# build-dietpi-image.sh - Build a custom DietPi image for OpenClaw on Pi 3B+
#
# This script downloads the official DietPi image for RPi 3B+ (ARMv8/aarch64)
# and prepares it with OpenClaw pre-configured for minimal RAM usage.
#
# Usage:
#   bash scripts/build-dietpi-image.sh
#
# Requirements:
#   - Linux host (x86_64 or aarch64)
#   - sudo access (for loop mount)
#   - wget, xz-utils, parted
#
# Output:
#   - dietpi-openclaw-pi3b.img (ready to flash with dd or balenaEtcher)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${SCRIPT_DIR}/build/dietpi"
OUTPUT_IMG="${SCRIPT_DIR}/build/dietpi-openclaw-pi3b.img"

DIETPI_URL="https://dietpi.com/downloads/images/DietPi_RPi-ARMv8-Bookworm.7z"
DIETPI_ARCHIVE="${WORK_DIR}/DietPi_RPi-ARMv8-Bookworm.7z"

echo "=== OpenClaw DietPi Image Builder for Pi 3B+ ==="
echo ""

# Check dependencies
for cmd in wget 7z losetup mount umount; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found. Install it first."
    echo "  sudo apt install wget p7zip-full util-linux"
    exit 1
  fi
done

mkdir -p "$WORK_DIR"

# Step 1: Download DietPi
echo "[1/6] Downloading DietPi ARMv8 image..."
if [ ! -f "$DIETPI_ARCHIVE" ]; then
  wget -O "$DIETPI_ARCHIVE" "$DIETPI_URL"
else
  echo "  Already downloaded, skipping."
fi

# Step 2: Extract image
echo "[2/6] Extracting image..."
cd "$WORK_DIR"
7z x -y "$DIETPI_ARCHIVE" "*.img"
DIETPI_IMG=$(ls -1 *.img | head -1)
cp "$DIETPI_IMG" "$OUTPUT_IMG"
echo "  Image: $OUTPUT_IMG"

# Step 3: Mount the image
echo "[3/6] Mounting image for customization..."
LOOP_DEV=$(sudo losetup --find --show --partscan "$OUTPUT_IMG")
MOUNT_DIR="${WORK_DIR}/mnt"
mkdir -p "$MOUNT_DIR"

# DietPi images have 2 partitions: boot (FAT32) + root (ext4)
sudo mount "${LOOP_DEV}p2" "$MOUNT_DIR"
sudo mount "${LOOP_DEV}p1" "$MOUNT_DIR/boot"

# Step 4: Configure DietPi automation
echo "[4/6] Injecting OpenClaw configuration..."

# 4a. DietPi first-run automation (dietpi.txt)
sudo tee "$MOUNT_DIR/boot/dietpi.txt" > /dev/null << 'DIETPI_TXT'
# DietPi-Automation for OpenClaw Pi 3B+
# This runs on first boot without user interaction.

# Language/Locale
AUTO_SETUP_LOCALE=en_US.UTF-8
AUTO_SETUP_KEYBOARD_LAYOUT=us
AUTO_SETUP_TIMEZONE=America/Sao_Paulo

# Network: DHCP on eth0, WiFi configurable
AUTO_SETUP_NET_ETHERNET_ENABLED=1
AUTO_SETUP_NET_WIFI_ENABLED=0
AUTO_SETUP_NET_WIFI_COUNTRY_CODE=BR

# Headless
AUTO_SETUP_HEADLESS=1

# SSH server: Dropbear (lighter than OpenSSH, saves ~5MB)
AUTO_SETUP_SSH_SERVER_INDEX=-1

# Hostname
AUTO_SETUP_NET_HOSTNAME=openclaw-pi

# DietPi user password (change after first boot!)
AUTO_SETUP_GLOBAL_PASSWORD=openclaw

# Disable swap on SD card (we create our own later)
AUTO_SETUP_SWAPFILE_SIZE=0

# GPU memory minimum
AUTO_SETUP_GPU_MEM=16

# Automated first-run: install Node.js
AUTO_SETUP_AUTOMATED=1
AUTO_SETUP_INSTALL_SOFTWARE_ID=9

# Disable unnecessary DietPi features
CONFIG_SERIAL_CONSOLE_ENABLE=0
CONFIG_SOUNDCARD=none
CONFIG_LCDPANEL=none

# Logging: minimal (RAMlog only, no disk logging)
CONFIG_LOG_BACKEND=ramlog
DIETPI_TXT

# 4b. Custom first-run script
sudo mkdir -p "$MOUNT_DIR/var/lib/dietpi/postboot.d"
sudo tee "$MOUNT_DIR/var/lib/dietpi/postboot.d/openclaw-setup.sh" > /dev/null << 'POSTBOOT'
#!/bin/bash
# OpenClaw post-boot setup for DietPi
# This runs once after DietPi first-boot automation completes.
set -euo pipefail

LOG="/var/log/openclaw-setup.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== OpenClaw Setup Starting ==="
echo "Date: $(date)"

# 1. Setup swap (zram - better than file for SD card longevity)
echo "[1/7] Setting up zram swap..."
apt-get install -y zram-tools 2>/dev/null || true
if command -v zramctl &>/dev/null; then
  modprobe zram
  zramctl /dev/zram0 --size 2G --algorithm lz4
  mkswap /dev/zram0
  swapon -p 100 /dev/zram0
  # Persist via rc.local
  cat >> /etc/rc.local << 'ZRAM'
modprobe zram
zramctl /dev/zram0 --size 2G --algorithm lz4 2>/dev/null
mkswap /dev/zram0 2>/dev/null
swapon -p 100 /dev/zram0 2>/dev/null
ZRAM
fi

# 2. Install Node.js 22 LTS
echo "[2/7] Installing Node.js 22..."
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
echo "  Node.js: $(node --version)"
echo "  npm: $(npm --version)"

# 3. Install pnpm
echo "[3/7] Installing pnpm..."
npm install -g pnpm
echo "  pnpm: $(pnpm --version)"

# 4. Install build tools for native addons
echo "[4/7] Installing build dependencies..."
apt-get install -y build-essential python3 git

# 5. Clone/install OpenClaw
echo "[5/7] Installing OpenClaw..."
OPENCLAW_DIR="/opt/openclaw"
if [ ! -d "$OPENCLAW_DIR" ]; then
  git clone --depth 1 https://github.com/nicholasgriffintn/openclaw.git "$OPENCLAW_DIR"
  cd "$OPENCLAW_DIR"
  pnpm install --frozen-lockfile
fi

# 6. Install OpenClaw config
echo "[6/7] Configuring OpenClaw..."
OPENCLAW_CONFIG_DIR="/root/.openclaw"
mkdir -p "$OPENCLAW_CONFIG_DIR"

# Copy the optimized Pi 3B+ config
if [ -f "$OPENCLAW_DIR/pi3b-openclaw-config.json" ]; then
  cp "$OPENCLAW_DIR/pi3b-openclaw-config.json" "$OPENCLAW_CONFIG_DIR/openclaw.json"
fi

# Environment variables
cat > "$OPENCLAW_CONFIG_DIR/.env" << 'ENVFILE'
# Pi 3B+ DietPi optimizations
OPENCLAW_SKIP_BROWSER_CONTROL_SERVER=1
OPENCLAW_SKIP_CANVAS_HOST=1
OPENCLAW_SKIP_GMAIL_WATCHER=1
OPENCLAW_DISABLE_BONJOUR=1
NODE_OPTIONS=--max-old-space-size=384

# IMPORTANT: Set your API key for vector memory (embeddings)
# Uncomment ONE of the lines below:
# OPENAI_API_KEY=sk-your-key-here
# GOOGLE_API_KEY=your-gemini-key-here
ENVFILE

# 7. Create systemd service
echo "[7/7] Creating systemd service..."
cat > /etc/systemd/system/openclaw.service << 'SVCFILE'
[Unit]
Description=OpenClaw Gateway (DietPi Pi 3B+)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/openclaw
EnvironmentFile=/root/.openclaw/.env

MemoryMax=512M
MemoryHigh=400M
LimitNOFILE=4096
LimitNPROC=128

ExecStart=/usr/bin/node /opt/openclaw/openclaw.mjs gateway --allow-unconfigured
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCFILE

systemctl daemon-reload
systemctl enable openclaw

# Clean up build dependencies to save disk space
echo "Cleaning up..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo ""
echo "=== OpenClaw Setup Complete ==="
echo ""
echo "IMPORTANT: Edit /root/.openclaw/.env and set your API key!"
echo "Then: systemctl start openclaw"
echo ""

# Self-remove this script (one-time setup)
rm -f /var/lib/dietpi/postboot.d/openclaw-setup.sh
POSTBOOT

sudo chmod +x "$MOUNT_DIR/var/lib/dietpi/postboot.d/openclaw-setup.sh"

# 4c. Disable unnecessary kernel modules
sudo tee "$MOUNT_DIR/etc/modprobe.d/openclaw-blacklist.conf" > /dev/null << 'BLACKLIST'
# Disable unused hardware for RAM savings
blacklist bluetooth
blacklist btbcm
blacklist hci_uart
blacklist snd_bcm2835
blacklist snd_pcm
blacklist snd_timer
blacklist snd
blacklist soundcore
blacklist videodev
blacklist v4l2_common
blacklist bcm2835_v4l2
BLACKLIST

# Step 5: Unmount
echo "[5/6] Unmounting image..."
sudo umount "$MOUNT_DIR/boot"
sudo umount "$MOUNT_DIR"
sudo losetup -d "$LOOP_DEV"

# Step 6: Summary
echo "[6/6] Done!"
echo ""
echo "=== Image ready: $OUTPUT_IMG ==="
echo ""
echo "Flash to SD card:"
echo "  sudo dd if=$OUTPUT_IMG of=/dev/sdX bs=4M status=progress"
echo "  # OR use balenaEtcher / Raspberry Pi Imager"
echo ""
echo "First boot:"
echo "  1. Insert SD card into Pi 3B+ and power on"
echo "  2. DietPi will auto-configure (takes ~5-10 min)"
echo "  3. SSH in: ssh root@openclaw-pi (password: openclaw)"
echo "  4. Edit /root/.openclaw/.env and set your API key"
echo "  5. Start OpenClaw: systemctl start openclaw"
echo ""
echo "Expected RAM at idle: ~335 MB total (50 MB OS + 285 MB OpenClaw)"
echo "Free RAM: ~591 MB (64% headroom) + 2 GB zram swap"
