#!/usr/bin/env python3
# Print the host Tailscale's advertised IPv4 subnet-route CIDRs, comma-separated — the ranges a
# `vm --tun-passthrough` guest needs an explicit route for (tailnet peer IPs in 100.64.0.0/10 are
# already reachable via the vmnet NAT). Reads `tailscale status --json` on stdin; prints nothing if
# tailscale is down or advertises no subnet routes. Kept as a file (not inline in the nix-vm shell
# string) because column-0 Python would break the surrounding indented-string formatting.
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

routes = []
for peer in (data.get("Peer") or {}).values():
    for cidr in (peer.get("PrimaryRoutes") or []):
        if ":" in cidr or cidr == "0.0.0.0/0":  # skip IPv6 and the exit-node default route
            continue
        if cidr not in routes:
            routes.append(cidr)

print(",".join(routes))
