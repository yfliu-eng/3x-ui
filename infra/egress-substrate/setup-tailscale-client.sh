#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Device Onboarding: Tailscale Client Setup
#
# Run on each device (Mac/Linux). For iOS/Android, follow printed instructions.
#
# This script:
#   1. Installs Tailscale
#   2. Connects to your tailnet
#   3. Pins exit node to us-egress-primary (NOT auto-select)
#   4. Verifies egress identity
#
# Usage: ./setup-tailscale-client.sh [--authkey tskey-xxx] [--exit-node us-egress-primary]
# =============================================================================

EXIT_NODE="${4:-us-egress-primary}"
TS_AUTHKEY="${2:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

OS="$(uname -s)"

# =============================================================================
# Install Tailscale
# =============================================================================
case "$OS" in
    Linux)
        if ! command -v tailscale &>/dev/null; then
            log "Installing Tailscale (Linux)..."
            curl -fsSL https://tailscale.com/install.sh | sh
        else
            log "Tailscale already installed"
        fi
        ;;
    Darwin)
        if ! command -v tailscale &>/dev/null; then
            log "Installing Tailscale (macOS)..."
            if command -v brew &>/dev/null; then
                brew install --cask tailscale
            else
                err "Install Tailscale from https://tailscale.com/download/mac or via: brew install --cask tailscale"
            fi
        else
            log "Tailscale already installed"
        fi
        ;;
    *)
        err "Unsupported OS: $OS. See platform instructions below."
        ;;
esac

# =============================================================================
# Connect and pin exit node
# =============================================================================
log "Connecting to tailnet..."
if [[ -n "$TS_AUTHKEY" ]]; then
    tailscale up --authkey="$TS_AUTHKEY"
else
    tailscale up
    log "Complete authentication in the browser if prompted"
fi

# Wait for connection
sleep 3

# Pin to the specific exit node — NOT auto-select
# --exit-node=auto:any selects by latency, which changes egress identity.
# We want invariant egress, so we fix to the named primary node.
log "Pinning exit node to: $EXIT_NODE"
tailscale set --exit-node="$EXIT_NODE"

# Verify the exit node is active
sleep 2
EXIT_STATUS=$(tailscale status 2>/dev/null | grep -i "exit node" || echo "")
if [[ -n "$EXIT_STATUS" ]]; then
    log "Exit node active: $EXIT_STATUS"
else
    warn "Exit node may not be active yet. Check: tailscale status"
    warn "Ensure the exit node is approved in Tailscale admin console"
fi

# =============================================================================
# Verify egress identity
# =============================================================================
log "Verifying egress identity..."
EGRESS_IP=$(curl -4 -s --max-time 15 ifconfig.me 2>/dev/null || echo "")
if [[ -n "$EGRESS_IP" ]]; then
    log "Egress IP: $EGRESS_IP"
    GEO=$(curl -s --max-time 10 "http://ip-api.com/json/$EGRESS_IP?fields=countryCode,city,isp" 2>/dev/null || echo "")
    if echo "$GEO" | grep -q '"countryCode":"US"'; then
        log "Region: US confirmed"
    else
        warn "Region may not be US — verify exit node is routing correctly"
    fi
else
    warn "Could not verify egress IP — check network connectivity"
fi

# =============================================================================
# Platform-specific notes
# =============================================================================
echo ""
echo "=========================================="
echo " Device onboarded successfully"
echo ""
echo " Exit node: $EXIT_NODE (fixed, not auto-select)"
echo " Egress IP: ${EGRESS_IP:-pending verification}"
echo ""
echo " Useful commands:"
echo "   tailscale status              — check connection"
echo "   tailscale set --exit-node=$EXIT_NODE  — re-pin exit node"
echo "   tailscale ping $EXIT_NODE     — test latency to exit node"
echo "   curl ifconfig.me              — verify egress IP"
echo ""
echo " If switching to backup:"
echo "   tailscale set --exit-node=us-egress-backup"
echo ""
echo "=========================================="

# =============================================================================
# Instructions for platforms that can't run this script
# =============================================================================
cat <<'PLATFORMS'

--- iOS Setup ---
1. Install Tailscale from App Store
2. Open Tailscale → Log in to your tailnet
3. Go to exit node selector → choose "us-egress-primary"
   IMPORTANT: Do NOT use "Suggested exit node" — it auto-selects by latency
4. Verify: open Safari → ifconfig.me → should show your US IP

--- Android Setup ---
1. Install Tailscale from Play Store
2. Open Tailscale → Log in
3. Tap ⋮ menu → Use exit node → select "us-egress-primary"
4. Verify egress IP in browser

--- Windows Setup ---
1. Install Tailscale from https://tailscale.com/download/windows
2. System tray → Tailscale icon → Exit Nodes → us-egress-primary
3. Verify: PowerShell → curl.exe ifconfig.me

PLATFORMS
