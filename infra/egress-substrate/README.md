# Stable Egress Substrate

Infrastructure module that absorbs travel/network variability before it reaches
the application session layer (ChatGPT, OpenAI API, research tools).

This module reduces variance. It does not change platform boundaries.
OpenAI's supported-region rules and anomaly detection remain as-is.

## Invariants vs Variables

| Held constant (invariant) | Absorbs variation in |
|---------------------------|---------------------|
| Egress IP and region | User physical location |
| Transport behavior | Local network quality (UDP/TCP/blocked) |
| Client config across devices | Hotel / airport / carrier constraints |
| Recovery path after failure | Packet loss, censorship, reachability |
| Session identity | Device / browser / account signals |

## System Decomposition

```
Terminal device
  └→ Tailscale client (control + relay plane)
       └→ US primary exit node ← fixed static/reserved IPv4
            └→ [failover] US backup exit node (same region)

Data plane:  WireGuard (always)
Control:     Tailscale coordination server
Relay:       DERP (when UDP path is blocked — hotel/airport/corporate)
Fallback:    Raw WireGuard configs (if Tailscale dependency is unacceptable)
```

## Three Layers

### Layer 1: Fixed Egress Identity
- One persistent US IPv4 address
- Lightsail: $5/mo IPv4 bundle + attached static IP (survives stop/start)
- DigitalOcean: Droplet + Reserved IP (reassignable for automated failover)

### Layer 2: Travel Network Adaptation
- Tailscale exit node (preferred): WireGuard data plane + DERP relay fallback
- Any device that can make an HTTPS connection can tunnel through DERP
- Raw WireGuard (low-dependency backup): no relay, fails on UDP-hostile networks
- Client fixed to `--exit-node=<primary-name>`, never `--exit-node=auto`

### Layer 3: Session Stability
- One primary device, one browser profile, 2FA enabled
- No concurrent sessions from multiple locations
- On anomaly: converge to single-device + single-exit + single-profile
- Network layer stability reduces session-layer drift

## Deployment Variants

### Variant A: Lightsail Single Node (minimal)
```bash
ssh root@<lightsail-ip>
./provision-lightsail.sh
```
- $5/mo, manual failover, static IP attached via AWS console
- Best for: starting point, single-user, cost-sensitive

### Variant B: DigitalOcean Dual Node (resilient)
```bash
ssh root@<primary-ip>
./provision-do.sh --role primary --reserved-ip <reserved-ip>
ssh root@<backup-ip>
./provision-do.sh --role backup --reserved-ip <reserved-ip>
```
- ~$8-10/mo, Reserved IP moves between nodes on failure
- Best for: travel-dependent user, needs IP continuity across node failures

## File Index

| File | Purpose |
|------|---------|
| `provision-lightsail.sh` | Variant A: single Lightsail node + Tailscale exit node |
| `provision-do.sh` | Variant B: DigitalOcean node + Reserved IP handling |
| `setup-tailscale-client.sh` | Device onboarding (Mac/Linux/iOS/Android instructions) |
| `setup-wg-fallback.sh` | Raw WireGuard fallback config (no Tailscale dependency) |
| `deploy-healthcheck.sh` | Server-side health probe + alerting |
| `failover-check.sh` | Client-side connectivity verification |
| `harden.sh` | OS hardening (firewall, SSH, auto-updates) |
| `session-hygiene.md` | Session-layer operational procedures |
