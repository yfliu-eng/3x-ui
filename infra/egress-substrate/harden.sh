#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Layer 5: Operational Hygiene — OS Hardening
#
# Minimal-surface hardening for egress nodes.
# Principle: this machine does ONE thing (route traffic). Nothing else.
# =============================================================================

log() { echo -e "\033[0;32m[+]\033[0m $*"; }
warn() { echo -e "\033[0;33m[!]\033[0m $*"; }

[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }

# --- Firewall: only allow what's needed ---
log "Configuring firewall..."
apt-get install -y -qq ufw

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH (restrict to key-auth only — see below)
ufw allow 22/tcp comment "SSH"

# WireGuard
ufw allow 51820/udp comment "WireGuard"

# wstunnel TCP fallback
ufw allow 443/tcp comment "wstunnel-TCP-fallback"

ufw --force enable
log "Firewall: only SSH(22/tcp), WG(51820/udp), wstunnel(443/tcp) open"

# --- SSH hardening ---
log "Hardening SSH..."
SSHD_CONF="/etc/ssh/sshd_config"

# Disable password auth (key-only)
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONF"
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONF"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONF"
sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/' "$SSHD_CONF"

systemctl restart sshd
log "SSH: password auth disabled, root login key-only, max 3 auth tries"

# --- Automatic security updates ---
log "Enabling unattended security upgrades..."
apt-get install -y -qq unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
log "Unattended security upgrades enabled"

# --- Fail2ban for SSH ---
log "Installing fail2ban..."
apt-get install -y -qq fail2ban

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
EOF

systemctl enable fail2ban
systemctl restart fail2ban
log "fail2ban: SSH brute-force protection active"

# --- Disable unnecessary services ---
log "Disabling unnecessary services..."
for svc in apache2 nginx postfix cups avahi-daemon; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl stop "$svc"
        systemctl disable "$svc"
        log "Disabled: $svc"
    fi
done

# --- Kernel hardening ---
log "Applying kernel hardening..."
cat > /etc/sysctl.d/99-hardening.conf <<EOF
# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Ignore ICMP broadcast
net.ipv4.icmp_echo_ignore_broadcasts = 1

# SYN flood protection
net.ipv4.tcp_syncookies = 1

# Log martian packets
net.ipv4.conf.all.log_martians = 1

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Keep IP forwarding (required for WireGuard NAT)
net.ipv4.ip_forward = 1
EOF

sysctl -p /etc/sysctl.d/99-hardening.conf
log "Kernel hardening applied"

# --- Summary ---
echo ""
echo "=========================================="
echo " Hardening complete"
echo "  Firewall:     UFW (22/tcp, 51820/udp, 443/tcp)"
echo "  SSH:          Key-only, max 3 tries"
echo "  fail2ban:     Active on SSH"
echo "  Auto-updates: Security patches"
echo "  Surface:      Minimal (no web server, no mail)"
echo "=========================================="
