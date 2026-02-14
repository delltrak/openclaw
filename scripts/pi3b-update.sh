#!/usr/bin/env bash
# pi3b-update.sh - OpenClaw updater for Raspberry Pi 3B+
#
# Usage:
#   openclaw-update              # Update to latest on current branch
#   openclaw-update --branch dev # Switch to different branch
#   openclaw-update --check      # Check for updates without installing
#   openclaw-update --rollback   # Rollback to previous version
#
# Cron example (auto-update every night at 3am):
#   0 3 * * * /usr/local/bin/openclaw-update --auto >> /var/log/openclaw-update.log 2>&1
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
OPENCLAW_DIR="${OPENCLAW_DIR:-/opt/openclaw}"
OPENCLAW_CONFIG_DIR="${HOME}/.openclaw"
SERVICE_NAME="openclaw"
LOCK_FILE="/tmp/openclaw-update.lock"
LOG_FILE="/var/log/openclaw-update.log"
MAX_RETRIES=3
RETRY_DELAY=5

# ─── Security ───────────────────────────────────────────────────────────────
# Trusted GPG key fingerprints (add your key here)
# Get yours with: gpg --list-keys --keyid-format long
# Example: TRUSTED_GPG_KEYS=("ABCD1234EFGH5678" "IJKL9012MNOP3456")
TRUSTED_GPG_KEYS=()

# Trusted GitHub usernames (commits must be authored by one of these)
# Only enforced if non-empty
TRUSTED_AUTHORS=()

# Require signed commits? (true = block unsigned commits)
REQUIRE_SIGNED_COMMITS=false

# File patterns that should NEVER change (blocks update if modified)
BLOCKED_PATTERNS=(
  "\.env$"
  "credentials"
  "\.pem$"
  "\.key$"
)

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $(date '+%H:%M:%S') $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $(date '+%H:%M:%S') $*"; }
err()  { echo -e "${RED}[✗]${NC} $(date '+%H:%M:%S') $*" >&2; }
info() { echo -e "${BLUE}[i]${NC} $(date '+%H:%M:%S') $*"; }

# ─── Argument parsing ────────────────────────────────────────────────────────
ACTION="update"
TARGET_BRANCH=""
AUTO_MODE=false
SKIP_SECURITY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --check)         ACTION="check"; shift ;;
    --rollback)      ACTION="rollback"; shift ;;
    --branch)        TARGET_BRANCH="$2"; shift 2 ;;
    --auto)          AUTO_MODE=true; shift ;;
    --skip-security) SKIP_SECURITY=true; shift ;;
    --help|-h)
      echo "Usage: openclaw-update [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --check           Check for updates without installing"
      echo "  --rollback        Rollback to previous version"
      echo "  --branch X        Switch to branch X and update"
      echo "  --auto            Non-interactive mode (for cron)"
      echo "  --skip-security   Skip security checks (NOT recommended)"
      echo "  --help            Show this help"
      echo ""
      echo "Security:"
      echo "  Configure TRUSTED_AUTHORS, TRUSTED_GPG_KEYS, and"
      echo "  REQUIRE_SIGNED_COMMITS at the top of this script."
      exit 0
      ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Lock ────────────────────────────────────────────────────────────────────
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE")
  if kill -0 "$LOCK_PID" 2>/dev/null; then
    err "Another update is running (PID $LOCK_PID). Exiting."
    exit 1
  else
    warn "Stale lock file found, removing."
    rm -f "$LOCK_FILE"
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# ─── Validation ──────────────────────────────────────────────────────────────
if [ ! -d "$OPENCLAW_DIR/.git" ]; then
  err "OpenClaw not found at $OPENCLAW_DIR"
  err "Run pi3b-install.sh first."
  exit 1
fi

cd "$OPENCLAW_DIR"

CURRENT_BRANCH=$(git branch --show-current)
CURRENT_COMMIT=$(git rev-parse --short HEAD)
CURRENT_DATE=$(git log -1 --format='%ci' HEAD)

info "Current: branch=$CURRENT_BRANCH commit=$CURRENT_COMMIT"
info "Date: $CURRENT_DATE"

# ─── Check for updates ──────────────────────────────────────────────────────
BRANCH="${TARGET_BRANCH:-$CURRENT_BRANCH}"

info "Fetching updates from origin/$BRANCH..."
git fetch origin "$BRANCH" 2>/dev/null || {
  # Retry with backoff
  for i in $(seq 1 $MAX_RETRIES); do
    warn "Fetch failed, retry $i/$MAX_RETRIES in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
    RETRY_DELAY=$((RETRY_DELAY * 2))
    git fetch origin "$BRANCH" 2>/dev/null && break
    if [ "$i" -eq "$MAX_RETRIES" ]; then
      err "Failed to fetch after $MAX_RETRIES retries."
      exit 1
    fi
  done
}

LOCAL_COMMIT=$(git rev-parse HEAD)
REMOTE_COMMIT=$(git rev-parse "origin/$BRANCH")

if [ "$LOCAL_COMMIT" = "$REMOTE_COMMIT" ] && [ -z "$TARGET_BRANCH" ]; then
  log "Already up to date ($CURRENT_COMMIT)"
  exit 0
fi

# Count new commits
NEW_COMMITS=$(git rev-list HEAD..origin/"$BRANCH" --count)
info "Updates available: $NEW_COMMITS new commit(s)"

# Show what changed
echo ""
git log --oneline HEAD..origin/"$BRANCH" | head -20
echo ""

if [ "$ACTION" = "check" ]; then
  log "Check complete. Run 'openclaw-update' to install."
  exit 0
fi

# ─── Rollback ────────────────────────────────────────────────────────────────
if [ "$ACTION" = "rollback" ]; then
  ROLLBACK_FILE="$OPENCLAW_CONFIG_DIR/.last-good-commit"
  if [ ! -f "$ROLLBACK_FILE" ]; then
    err "No rollback point found. Cannot rollback."
    exit 1
  fi
  ROLLBACK_COMMIT=$(cat "$ROLLBACK_FILE")
  info "Rolling back to $ROLLBACK_COMMIT..."

  git checkout "$ROLLBACK_COMMIT"
  pnpm install --frozen-lockfile 2>/dev/null || pnpm install
  pnpm build

  sudo systemctl restart "$SERVICE_NAME"
  log "Rolled back to $ROLLBACK_COMMIT and restarted."
  exit 0
fi

# ─── Security verification ───────────────────────────────────────────────────
if [ "$SKIP_SECURITY" = true ]; then
  warn "Security checks SKIPPED (--skip-security flag)"
else
info "Running security checks..."

# Check 1: Verify commit signatures (if required)
if [ "$REQUIRE_SIGNED_COMMITS" = true ]; then
  UNSIGNED_COMMITS=$(git log --format='%H %G?' HEAD..origin/"$BRANCH" | grep -v ' G$' | grep -v ' U$' || true)
  if [ -n "$UNSIGNED_COMMITS" ]; then
    err "SECURITY: Unsigned commits detected!"
    echo "$UNSIGNED_COMMITS" | while read -r hash status; do
      err "  $hash (signature: $status)"
    done
    err "All commits must be GPG-signed. Aborting update."
    err "To disable: set REQUIRE_SIGNED_COMMITS=false in update script."
    exit 1
  fi
  log "All commits are GPG-signed"
fi

# Check 2: Verify trusted GPG keys (if configured)
if [ ${#TRUSTED_GPG_KEYS[@]} -gt 0 ]; then
  UNTRUSTED=false
  while IFS= read -r line; do
    COMMIT_HASH=$(echo "$line" | awk '{print $1}')
    KEY_ID=$(echo "$line" | awk '{print $2}')
    TRUSTED=false
    for TKEY in "${TRUSTED_GPG_KEYS[@]}"; do
      if [[ "$KEY_ID" == *"$TKEY"* ]]; then
        TRUSTED=true
        break
      fi
    done
    if [ "$TRUSTED" = false ] && [ -n "$KEY_ID" ] && [ "$KEY_ID" != "" ]; then
      err "SECURITY: Commit $COMMIT_HASH signed by untrusted key: $KEY_ID"
      UNTRUSTED=true
    fi
  done < <(git log --format='%H %GK' HEAD..origin/"$BRANCH" | grep -v ' $')
  if [ "$UNTRUSTED" = true ]; then
    err "Aborting: commits signed by keys not in TRUSTED_GPG_KEYS."
    exit 1
  fi
  log "All commit signatures from trusted keys"
fi

# Check 3: Verify trusted authors (if configured)
if [ ${#TRUSTED_AUTHORS[@]} -gt 0 ]; then
  UNTRUSTED_AUTHOR=false
  while IFS= read -r author_email; do
    AUTHOR_TRUSTED=false
    for TAUTHOR in "${TRUSTED_AUTHORS[@]}"; do
      if [[ "$author_email" == *"$TAUTHOR"* ]]; then
        AUTHOR_TRUSTED=true
        break
      fi
    done
    if [ "$AUTHOR_TRUSTED" = false ]; then
      err "SECURITY: Commit by untrusted author: $author_email"
      UNTRUSTED_AUTHOR=true
    fi
  done < <(git log --format='%ae' HEAD..origin/"$BRANCH" | sort -u)
  if [ "$UNTRUSTED_AUTHOR" = true ]; then
    err "Aborting: commits by authors not in TRUSTED_AUTHORS."
    err "Add trusted authors to TRUSTED_AUTHORS in the update script."
    exit 1
  fi
  log "All commits from trusted authors"
fi

# Check 4: Scan for suspicious files in the diff
SUSPICIOUS_FILES=""
while IFS= read -r changed_file; do
  for pattern in "${BLOCKED_PATTERNS[@]}"; do
    if echo "$changed_file" | grep -qE "$pattern"; then
      SUSPICIOUS_FILES="$SUSPICIOUS_FILES\n  $changed_file (matches: $pattern)"
    fi
  done
done < <(git diff --name-only HEAD..origin/"$BRANCH")

if [ -n "$SUSPICIOUS_FILES" ]; then
  err "SECURITY: Suspicious files detected in update!"
  echo -e "$SUSPICIOUS_FILES"
  err ""
  err "These file patterns should never be in a remote update."
  err "This could indicate a compromised repository."
  if [ "$AUTO_MODE" = true ]; then
    err "Auto mode: aborting update. Review manually."
    exit 1
  else
    echo -n "Continue anyway? (y/N): "
    read -r CONTINUE
    if [[ ! "$CONTINUE" =~ ^[Yy] ]]; then
      err "Update cancelled."
      exit 1
    fi
    warn "Continuing at user's request..."
  fi
fi

# Check 5: Detect new post-install scripts or hooks
NEW_SCRIPTS=$(git diff --name-only --diff-filter=A HEAD..origin/"$BRANCH" | grep -E '(\.sh$|hooks/|\.github/|Makefile|postinstall)' || true)
if [ -n "$NEW_SCRIPTS" ]; then
  warn "SECURITY: New executable scripts detected in update:"
  echo "$NEW_SCRIPTS" | while read -r f; do warn "  $f"; done
  if [ "$AUTO_MODE" = true ]; then
    warn "Auto mode: review these files after update."
  else
    echo -n "Review these scripts before continuing? (Y/n): "
    read -r REVIEW
    if [[ ! "$REVIEW" =~ ^[Nn] ]]; then
      for f in $NEW_SCRIPTS; do
        echo ""
        echo "━━━ $f ━━━"
        git show "origin/$BRANCH:$f" 2>/dev/null | head -50
        echo "━━━━━━━━━━"
      done
      echo ""
      echo -n "Proceed with update? (y/N): "
      read -r PROCEED
      if [[ ! "$PROCEED" =~ ^[Yy] ]]; then
        err "Update cancelled."
        exit 1
      fi
    fi
  fi
fi

log "Security checks passed"
fi  # end skip-security check

# ─── Update ──────────────────────────────────────────────────────────────────
info "Updating OpenClaw..."

# Save rollback point
mkdir -p "$OPENCLAW_CONFIG_DIR"
echo "$LOCAL_COMMIT" > "$OPENCLAW_CONFIG_DIR/.last-good-commit"
log "Rollback point saved: $CURRENT_COMMIT"

# Switch branch if requested
if [ -n "$TARGET_BRANCH" ] && [ "$TARGET_BRANCH" != "$CURRENT_BRANCH" ]; then
  info "Switching from $CURRENT_BRANCH to $TARGET_BRANCH..."
  git checkout "$TARGET_BRANCH"
fi

# Pull changes
info "Pulling changes..."
git pull origin "$BRANCH"
NEW_COMMIT=$(git rev-parse --short HEAD)
log "Updated to $NEW_COMMIT"

# Check if dependencies changed
DEPS_CHANGED=false
if git diff "$LOCAL_COMMIT"..HEAD --name-only | grep -q 'package.json\|pnpm-lock.yaml'; then
  DEPS_CHANGED=true
  info "Dependencies changed, reinstalling..."
  pnpm install --frozen-lockfile 2>/dev/null || pnpm install
  log "Dependencies updated"
fi

# Check if source changed (need rebuild)
SRC_CHANGED=false
if git diff "$LOCAL_COMMIT"..HEAD --name-only | grep -qE '^(src/|tsdown\.config|tsconfig)'; then
  SRC_CHANGED=true
  info "Source changed, rebuilding..."
  pnpm build
  log "Build complete"
fi

# Check if UI changed
if git diff "$LOCAL_COMMIT"..HEAD --name-only | grep -q '^ui/'; then
  info "UI changed, rebuilding..."
  pnpm ui:build 2>/dev/null || warn "UI build skipped"
fi

# Check if Pi config changed
CONFIG_CHANGED=false
if git diff "$LOCAL_COMMIT"..HEAD --name-only | grep -q 'pi3b-openclaw-config.json'; then
  CONFIG_CHANGED=true
  warn "Pi config template updated. Review changes:"
  git diff "$LOCAL_COMMIT"..HEAD -- pi3b-openclaw-config.json | head -40
  echo ""
  if [ "$AUTO_MODE" = true ]; then
    warn "Auto mode: config NOT auto-applied. Review manually."
  else
    echo -n "Apply new config? (y/N): "
    read -r APPLY_CONFIG
    if [[ "$APPLY_CONFIG" =~ ^[Yy] ]]; then
      cp "$OPENCLAW_DIR/pi3b-openclaw-config.json" "$OPENCLAW_CONFIG_DIR/openclaw.json"
      log "Config updated"
    else
      info "Config not applied. Apply manually if needed."
    fi
  fi
fi

# Restart service
if [ "$SRC_CHANGED" = true ] || [ "$DEPS_CHANGED" = true ]; then
  info "Restarting OpenClaw service..."
  sudo systemctl restart "$SERVICE_NAME"

  # Wait for service to start
  sleep 3
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "Service restarted successfully"
  else
    err "Service failed to start! Rolling back..."
    git checkout "$LOCAL_COMMIT"
    pnpm install --frozen-lockfile 2>/dev/null || pnpm install
    pnpm build
    sudo systemctl restart "$SERVICE_NAME"
    err "Rolled back to $CURRENT_COMMIT due to startup failure."
    exit 1
  fi
else
  info "No restart needed (only non-code files changed)"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
log "Update complete!"
log "  Before: $CURRENT_COMMIT ($CURRENT_DATE)"
log "  After:  $NEW_COMMIT ($(git log -1 --format='%ci' HEAD))"
log "  Commits: $NEW_COMMITS"
log "  Deps changed: $DEPS_CHANGED"
log "  Source rebuilt: $SRC_CHANGED"
log "  Config changed: $CONFIG_CHANGED"

if [ "$CONFIG_CHANGED" = true ] && [ "$AUTO_MODE" = false ]; then
  warn "Config was updated upstream. Review with:"
  warn "  diff $OPENCLAW_CONFIG_DIR/openclaw.json $OPENCLAW_DIR/pi3b-openclaw-config.json"
fi

echo ""
log "Rollback available: openclaw-update --rollback"
