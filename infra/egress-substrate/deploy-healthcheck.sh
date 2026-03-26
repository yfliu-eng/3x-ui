#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Layer 4: Failover — Health Check Deployment
#
# Installs a periodic health probe that:
# 1. Tests WireGuard tunnel connectivity
# 2. Tests egress IP correctness
# 3. Tests ChatGPT/OpenAI endpoint reachability
# 4. Alerts on degradation (optional: Telegram or email)
# 5. Logs state transitions for post-hoc analysis
#
# Usage: ./deploy-healthcheck.sh [--interval 60] [--telegram-token TOKEN --telegram-chat CHAT_ID]
# =============================================================================

INTERVAL=60  # seconds
TELEGRAM_TOKEN=""
TELEGRAM_CHAT=""
LOG_FILE="/var/log/egress-health.log"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval)        INTERVAL="$2"; shift 2 ;;
        --telegram-token)  TELEGRAM_TOKEN="$2"; shift 2 ;;
        --telegram-chat)   TELEGRAM_CHAT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Install the health check script
cat > /usr/local/bin/egress-healthcheck <<'SCRIPT'
#!/usr/bin/env bash
# Egress Substrate Health Probe

LOG_FILE="/var/log/egress-health.log"
EXPECTED_IP_FILE="/etc/wireguard/.expected_egress_ip"
STATE_FILE="/tmp/egress-health-state"

# Initialize state
[[ ! -f "$STATE_FILE" ]] && echo "healthy" > "$STATE_FILE"
PREV_STATE=$(cat "$STATE_FILE")

timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

check_wg_interface() {
    wg show wg0 &>/dev/null
}

check_egress_ip() {
    local ip
    ip=$(curl -4 -s --max-time 10 ifconfig.me 2>/dev/null)
    if [[ -f "$EXPECTED_IP_FILE" ]]; then
        local expected
        expected=$(cat "$EXPECTED_IP_FILE")
        [[ "$ip" == "$expected" ]]
    else
        [[ -n "$ip" ]]
    fi
}

check_openai_reachable() {
    # Test that we can reach OpenAI's API endpoint (not blocked / geo-restricted)
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
        "https://api.openai.com/v1/models" \
        -H "Authorization: Bearer sk-placeholder" 2>/dev/null)
    # 401 = auth failed but endpoint reachable = good
    # 403 = potentially geo-blocked = bad
    # 000 = network failure = bad
    [[ "$status" == "401" || "$status" == "200" ]]
}

# Run checks
FAILURES=()
check_wg_interface   || FAILURES+=("wg-interface-down")
check_egress_ip      || FAILURES+=("egress-ip-mismatch")
check_openai_reachable || FAILURES+=("openai-unreachable")

if [[ ${#FAILURES[@]} -eq 0 ]]; then
    CURRENT_STATE="healthy"
else
    CURRENT_STATE="degraded:${FAILURES[*]}"
fi

# Log state transitions
if [[ "$CURRENT_STATE" != "$PREV_STATE" ]]; then
    echo "$(timestamp) STATE_CHANGE: $PREV_STATE → $CURRENT_STATE" >> "$LOG_FILE"

    # Alert on degradation
    if [[ "$CURRENT_STATE" != "healthy" ]]; then
        MSG="⚠ Egress substrate degraded: ${FAILURES[*]}"
        echo "$(timestamp) ALERT: $MSG" >> "$LOG_FILE"

        # Telegram alert if configured
        TGTOKEN_FILE="/etc/wireguard/.telegram_token"
        TGCHAT_FILE="/etc/wireguard/.telegram_chat"
        if [[ -f "$TGTOKEN_FILE" && -f "$TGCHAT_FILE" ]]; then
            TG_TOKEN=$(cat "$TGTOKEN_FILE")
            TG_CHAT=$(cat "$TGCHAT_FILE")
            curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                -d chat_id="$TG_CHAT" \
                -d text="$MSG" &>/dev/null || true
        fi
    else
        echo "$(timestamp) RECOVERY: system healthy" >> "$LOG_FILE"
    fi
fi

echo "$CURRENT_STATE" > "$STATE_FILE"

# Periodic heartbeat log (every run, for liveness confirmation)
echo "$(timestamp) PROBE: $CURRENT_STATE" >> "$LOG_FILE"
SCRIPT

chmod +x /usr/local/bin/egress-healthcheck

# Store expected egress IP
PUBLIC_IP=$(curl -4 -s ifconfig.me)
echo "$PUBLIC_IP" > /etc/wireguard/.expected_egress_ip

# Store Telegram config if provided
if [[ -n "$TELEGRAM_TOKEN" && -n "$TELEGRAM_CHAT" ]]; then
    echo "$TELEGRAM_TOKEN" > /etc/wireguard/.telegram_token
    echo "$TELEGRAM_CHAT" > /etc/wireguard/.telegram_chat
    chmod 600 /etc/wireguard/.telegram_token /etc/wireguard/.telegram_chat
    echo "[+] Telegram alerts configured"
fi

# Install systemd timer (more reliable than cron)
cat > /etc/systemd/system/egress-healthcheck.service <<EOF
[Unit]
Description=Egress substrate health probe

[Service]
Type=oneshot
ExecStart=/usr/local/bin/egress-healthcheck
EOF

cat > /etc/systemd/system/egress-healthcheck.timer <<EOF
[Unit]
Description=Run egress health probe every ${INTERVAL}s

[Timer]
OnBootSec=30
OnUnitActiveSec=${INTERVAL}s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now egress-healthcheck.timer

echo "[+] Health check deployed (interval: ${INTERVAL}s)"
echo "[+] Log: $LOG_FILE"
echo "[+] Expected egress IP: $PUBLIC_IP"
