# Stable Egress Substrate

Infrastructure module that absorbs travel/network variability before it reaches
the application session layer (ChatGPT, API endpoints, research tools).

## Design Invariants

| Held constant | Varies |
|---------------|--------|
| Egress IP & region | User physical location |
| Transport behavior | Local network quality |
| Client config across devices | Hotel/airport/carrier constraints |
| Recovery path after failure | Censorship / UDP reachability |
| Operational simplicity | Packet loss conditions |

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Layer 5: Operational Hygiene                    │
│  unattended-upgrades, minimal surface, drift ctrl│
├─────────────────────────────────────────────────┤
│  Layer 4: Failover                               │
│  primary (us-east) ←→ backup (us-west)           │
│  client auto-reconnect, health probe             │
├─────────────────────────────────────────────────┤
│  Layer 3: Endpoint Consistency                   │
│  unified config across Mac/Win/iOS/Android       │
│  same DNS, same kill-switch, same reconnect      │
├─────────────────────────────────────────────────┤
│  Layer 2: Transport                              │
│  WireGuard (UDP) primary                         │
│  TCP fallback via wstunnel for hostile networks   │
├─────────────────────────────────────────────────┤
│  Layer 1: Egress Identity                        │
│  persistent US IP, clean reputation              │
│  provider: AWS Lightsail or DigitalOcean         │
└─────────────────────────────────────────────────┘
```

## Quick Start

```bash
# 1. Provision primary + backup nodes
./provision.sh

# 2. Generate client configs for all devices
./gen-client-configs.sh <client-name>

# 3. Deploy health monitor
./deploy-healthcheck.sh
```

## File Index

| File | Purpose |
|------|---------|
| `provision.sh` | Server bootstrap (WireGuard + hardening + TCP fallback) |
| `gen-client-configs.sh` | Deterministic client config generation |
| `deploy-healthcheck.sh` | Health probe + failover trigger |
| `wg-server.conf.template` | Server WireGuard template |
| `wg-client.conf.template` | Client WireGuard template |
| `wstunnel.service` | TCP fallback systemd unit |
| `failover-check.sh` | Periodic health check script |
| `harden.sh` | OS hardening (firewall, SSH, auto-updates) |
