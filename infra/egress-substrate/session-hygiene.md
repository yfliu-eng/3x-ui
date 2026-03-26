# Session Stability — Operational Procedures

This layer is separate from the network layer. Its purpose is to reduce
signals that trigger OpenAI's anomaly detection.

## What OpenAI monitors (from their public documentation)

- Unusual login locations or device changes
- Use of VPN / proxy / Private Relay
- Sudden changes in usage patterns
- Multiple concurrent sessions

## Invariants to maintain

1. **One primary device** for ChatGPT use
   - Same browser, same profile, same cookies
   - Do not rotate between 3 laptops across 3 countries in one day

2. **One browser profile**
   - Dedicated browser profile (e.g., Chrome Profile "Work")
   - Do not clear cookies frequently
   - Do not use incognito mode for regular sessions

3. **2FA enabled**
   - Authenticator app, not SMS (SMS changes with travel SIM)

4. **No concurrent sessions**
   - One device logged in at a time
   - Log out of secondary devices before traveling

5. **Fixed egress IP** (handled by the network layer)
   - The network module keeps egress identity constant
   - This is the most impactful factor: platform sees same IP regardless of your location

## Convergence procedure on anomaly

If you get a suspicious activity warning or access block:

1. Stop using all devices except your primary
2. Verify egress IP: `curl ifconfig.me` → should be your fixed US IP
3. If IP is wrong: re-pin exit node
   - Tailscale: `tailscale set --exit-node=us-egress-primary`
   - WireGuard: disconnect, reconnect primary config
4. Clear the single browser profile's cookies for openai.com only
5. Log in fresh from the primary device, primary browser, through the fixed exit
6. If still blocked: temporarily disable VPN/exit node (per OpenAI's own troubleshooting advice),
   log in from a clean US network, then re-enable once the session is established

## What this module cannot do

- It cannot make a flagged IP unflagged
- It cannot override OpenAI's supported-country restrictions
- It cannot prevent detection of VPN use entirely
  (OpenAI can detect datacenter IPs; residential IPs reduce this signal)
- It can only reduce variance — it cannot eliminate risk

## IP reputation note

Datacenter IPs (Lightsail, DigitalOcean) are more likely to be flagged than
residential IPs. If repeated 403s occur:
- Try a different VPS provider or request a new IP
- Consider a residential proxy as the egress layer (higher cost, better reputation)
- AWS Lightsail and DigitalOcean IPs are generally acceptable, but specific
  IP ranges may be flagged if previously abused by other users
