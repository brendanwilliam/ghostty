#!/bin/sh
# Checks a Headscale server from outside: DNS, TLS, health, the DERP relay
# and STUN. Read-only. Usage: ./check.sh hs.example.com
set -u

host=${1:?usage: $0 <headscale-hostname>}
failed=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failed=1; }

echo "Checking $host"

ip=$(dig +short A "$host" | tail -n 1)
if [ -n "$ip" ]; then pass "DNS: $host -> $ip"; else fail "DNS: no A record for $host"; fi

expiry=$(echo | openssl s_client -connect "$host:443" -servername "$host" 2>/dev/null \
  | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [ -n "$expiry" ]; then pass "TLS certificate valid until $expiry"; else fail "TLS: no certificate on $host:443"; fi

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$host/health")
if [ "$code" = 200 ]; then pass "Headscale /health"; else fail "Headscale /health returned $code"; fi

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$host/derp/probe")
if [ "$code" = 200 ]; then pass "DERP relay /derp/probe"; else fail "DERP relay /derp/probe returned $code (is derp.server.enabled true?)"; fi

# A STUN binding request (RFC 5389) to udp/3478, as Tailscale clients send
# it (Headscale ignores requests without these attributes): SOFTWARE
# "tailnode", then FINGERPRINT. A reply for our transaction means STUN is
# reachable.
if python3 -I - "$host" <<'EOF'
import binascii, os, socket, struct, sys
host = sys.argv[1]
txn = os.urandom(12)
software = struct.pack("!HH", 0x8022, 8) + b"tailnode"
head = struct.pack("!HHI", 0x0001, len(software) + 8, 0x2112A442) + txn
crc = (binascii.crc32(head + software) ^ 0x5354554E) & 0xFFFFFFFF
req = head + software + struct.pack("!HHI", 0x8028, 4, crc)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
try:
    s.sendto(req, (host, 3478))
    data, _ = s.recvfrom(2048)
except OSError:
    sys.exit(1)
sys.exit(0 if len(data) >= 20 and data[8:20] == txn else 1)
EOF
then pass "STUN on udp/3478"; else fail "STUN: no reply on udp/3478 (firewall?)"; fi

if [ "$failed" = 0 ]; then echo "All checks passed."; else echo "Some checks failed."; fi
exit "$failed"
