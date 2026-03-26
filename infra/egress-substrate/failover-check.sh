#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Client-Side Connectivity Check
#
# Run on your device to verify the egress substrate is working.
# Tests: Tailscale status → egress IP → region → OpenAI reachability → DNS
#
# Usage: ./failover-check.sh [--auto]
#   --auto: switch to backup exit node if primary is down
# =============================================================================

AUTO=false
[[ "${1:-}" == "--auto" ]] && AUTO=true

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
T=10  # curl timeout

echo "=== Egress Substrate — Client Check ==="
echo ""
FAILURES=0

# --- Tailscale ---
echo "--- Tailscale ---"
if command -v tailscale &>/dev/null; then
    TS_STATUS=$(tailscale status 2>/dev/null || echo "")
    if [[ -n "$TS_STATUS" ]]; then
        ok "Tailscale connected"
        EXIT_INFO=$(echo "$TS_STATUS" | grep -i "exit" || echo "")
        if [[ -n "$EXIT_INFO" ]]; then
            ok "Exit node: $EXIT_INFO"
        else
            warn "No exit node active"
            ((FAILURES++)) || true
        fi
    else
        fail "Tailscale not connected"
        ((FAILURES++)) || true
    fi
else
    warn "Tailscale not installed — checking WireGuard"
    if command -v wg &>/dev/null && wg show 2>/dev/null | grep -q "interface"; then
        ok "WireGuard active (fallback path)"
    else
        fail "No tunnel active"
        ((FAILURES++)) || true
    fi
fi

# --- Egress IP ---
echo ""
echo "--- Egress Identity ---"
IP=$(curl -4 -s --max-time $T ifconfig.me 2>/dev/null || echo "")
if [[ -n "$IP" ]]; then
    ok "Egress IP: $IP"
    GEO=$(curl -s --max-time $T "http://ip-api.com/json/$IP?fields=countryCode,city,isp" 2>/dev/null || echo "")
    CC=$(echo "$GEO" | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
    ISP=$(echo "$GEO" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
    if [[ "$CC" == "US" ]]; then
        ok "Region: US ($ISP)"
    else
        fail "Region: $CC — NOT US"
        ((FAILURES++)) || true
    fi
else
    fail "Cannot reach ifconfig.me"
    ((FAILURES++)) || true
fi

# --- OpenAI ---
echo ""
echo "--- OpenAI Reachability ---"
API=$(curl -s -o /dev/null -w "%{http_code}" --max-time $T \
    "https://api.openai.com/v1/models" -H "Authorization: Bearer sk-probe" 2>/dev/null || echo "000")
case "$API" in
    401)     ok "OpenAI API: reachable (401 = endpoint accessible)" ;;
    200)     ok "OpenAI API: reachable" ;;
    403)     fail "OpenAI API: 403 (geo-blocked or IP flagged)"; ((FAILURES++)) || true ;;
    000)     fail "OpenAI API: network failure"; ((FAILURES++)) || true ;;
    *)       warn "OpenAI API: HTTP $API" ;;
esac

WEB=$(curl -s -o /dev/null -w "%{http_code}" --max-time $T "https://chatgpt.com" 2>/dev/null || echo "000")
case "$WEB" in
    200|301|302|307) ok "ChatGPT web: reachable" ;;
    403)             fail "ChatGPT web: 403 (IP flagged)"; ((FAILURES++)) || true ;;
    000)             fail "ChatGPT web: unreachable"; ((FAILURES++)) || true ;;
    *)               warn "ChatGPT web: HTTP $WEB" ;;
esac

# --- DNS ---
echo ""
echo "--- DNS ---"
DNS=$(dig +short +time=5 whoami.akamai.net 2>/dev/null || echo "")
if [[ -n "$DNS" ]]; then
    ok "DNS responding: $DNS"
else
    warn "DNS slow or failing"
fi

# --- Verdict ---
echo ""
echo "--- Result ---"
if [[ $FAILURES -eq 0 ]]; then
    ok "All checks passed"
elif [[ $FAILURES -ge 2 && "$AUTO" == true ]]; then
    fail "$FAILURES checks failed — switching to backup"
    if command -v tailscale &>/dev/null; then
        tailscale set --exit-node=us-egress-backup
        sleep 3
        NEW_IP=$(curl -4 -s --max-time $T ifconfig.me 2>/dev/null || echo "unknown")
        ok "Switched to backup exit node. New egress IP: $NEW_IP"
    else
        fail "Cannot auto-switch without Tailscale. Manual: activate backup WireGuard config."
    fi
else
    warn "$FAILURES check(s) failed"
    [[ "$AUTO" == false ]] && warn "Run with --auto to enable failover"
fi
