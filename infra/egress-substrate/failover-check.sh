#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Layer 4: Client-Side Failover Check
#
# Run this on your LOCAL machine (Mac/Linux) to test connectivity
# and switch between primary/backup if needed.
#
# Usage: ./failover-check.sh [--auto]
#   --auto: automatically switch to backup if primary is down
# =============================================================================

AUTO_SWITCH=false
[[ "${1:-}" == "--auto" ]] && AUTO_SWITCH=true

PRIMARY_CONF="primary"   # WireGuard tunnel name
BACKUP_CONF="backup"     # WireGuard tunnel name
TIMEOUT=10

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo "=== Egress Substrate — Connectivity Check ==="
echo ""

# --- Check 1: WireGuard interface ---
echo "--- WireGuard Status ---"
if command -v wg &>/dev/null; then
    ACTIVE_IF=$(wg show 2>/dev/null | head -1 | awk '{print $2}' || echo "")
    if [[ -n "$ACTIVE_IF" ]]; then
        ok "WireGuard active: $ACTIVE_IF"
        LATEST_HANDSHAKE=$(wg show "$ACTIVE_IF" latest-handshakes 2>/dev/null | awk '{print $2}')
        if [[ -n "$LATEST_HANDSHAKE" && "$LATEST_HANDSHAKE" != "0" ]]; then
            AGE=$(( $(date +%s) - LATEST_HANDSHAKE ))
            if [[ $AGE -lt 180 ]]; then
                ok "Last handshake: ${AGE}s ago (healthy)"
            else
                warn "Last handshake: ${AGE}s ago (stale — may indicate connectivity issue)"
            fi
        else
            fail "No handshake recorded"
        fi
    else
        fail "No active WireGuard interface"
    fi
else
    fail "WireGuard not installed"
fi

# --- Check 2: Egress IP ---
echo ""
echo "--- Egress Identity ---"
EGRESS_IP=$(curl -4 -s --max-time "$TIMEOUT" ifconfig.me 2>/dev/null || echo "")
if [[ -n "$EGRESS_IP" ]]; then
    ok "Egress IP: $EGRESS_IP"
    # Check if it looks like a US IP (rough geo check)
    GEO=$(curl -s --max-time "$TIMEOUT" "http://ip-api.com/json/$EGRESS_IP?fields=country,countryCode,isp" 2>/dev/null || echo "")
    if [[ -n "$GEO" ]]; then
        COUNTRY=$(echo "$GEO" | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4)
        ISP=$(echo "$GEO" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
        if [[ "$COUNTRY" == "US" ]]; then
            ok "Region: US ($ISP)"
        else
            warn "Region: $COUNTRY — NOT in US target region"
        fi
    fi
else
    fail "Cannot determine egress IP (network down?)"
fi

# --- Check 3: OpenAI reachability ---
echo ""
echo "--- Service Reachability ---"
OPENAI_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
    "https://api.openai.com/v1/models" \
    -H "Authorization: Bearer sk-test" 2>/dev/null || echo "000")

case "$OPENAI_STATUS" in
    401) ok "OpenAI API: reachable (auth rejected = endpoint accessible)" ;;
    200) ok "OpenAI API: reachable" ;;
    403) fail "OpenAI API: 403 Forbidden (possibly geo-blocked or IP flagged)" ;;
    000) fail "OpenAI API: unreachable (network failure)" ;;
    *)   warn "OpenAI API: HTTP $OPENAI_STATUS (unexpected)" ;;
esac

CHATGPT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
    "https://chatgpt.com" 2>/dev/null || echo "000")

case "$CHATGPT_STATUS" in
    200|301|302) ok "ChatGPT web: reachable (HTTP $CHATGPT_STATUS)" ;;
    403)         fail "ChatGPT web: 403 (IP may be flagged)" ;;
    000)         fail "ChatGPT web: unreachable" ;;
    *)           warn "ChatGPT web: HTTP $CHATGPT_STATUS" ;;
esac

# --- Check 4: DNS leak test ---
echo ""
echo "--- DNS Leak Check ---"
DNS_SERVER=$(dig +short +time=5 whoami.akamai.net 2>/dev/null || echo "")
if [[ -n "$DNS_SERVER" ]]; then
    ok "DNS resolver responding: $DNS_SERVER"
else
    warn "DNS resolution slow or failing"
fi

# --- Failover decision ---
echo ""
echo "--- Failover Status ---"

# Count failures
FAILURES=0
[[ -z "$EGRESS_IP" ]] && ((FAILURES++)) || true
[[ "$OPENAI_STATUS" == "000" || "$OPENAI_STATUS" == "403" ]] && ((FAILURES++)) || true
[[ -z "$ACTIVE_IF" ]] && ((FAILURES++)) || true

if [[ $FAILURES -eq 0 ]]; then
    ok "All checks passed — system nominal"
elif [[ $FAILURES -ge 2 ]]; then
    fail "Multiple failures detected ($FAILURES/3)"
    if [[ "$AUTO_SWITCH" == true ]]; then
        warn "Auto-failover: switching to backup..."
        # Platform-specific tunnel switch
        if [[ "$(uname)" == "Darwin" ]]; then
            # macOS: use wg-quick or WireGuard app CLI
            wg-quick down "$PRIMARY_CONF" 2>/dev/null || true
            wg-quick up "$BACKUP_CONF" 2>/dev/null && ok "Switched to backup tunnel" || fail "Backup activation failed"
        else
            wg-quick down "$PRIMARY_CONF" 2>/dev/null || true
            wg-quick up "$BACKUP_CONF" 2>/dev/null && ok "Switched to backup tunnel" || fail "Backup activation failed"
        fi
    else
        warn "Run with --auto to enable automatic failover"
        warn "Manual: disconnect primary, connect backup tunnel"
    fi
else
    warn "Partial degradation ($FAILURES/3 checks failed)"
fi
