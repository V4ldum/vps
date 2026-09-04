#!/bin/bash

if [ "$EUID" -ne 0 ]
then
    echo "Must be run as root"
    exit 1;
fi

# ----------------------
# Setup DNS64 for IPv4 only targets

# Create resolved config
mkdir -p /etc/systemd/resolved.conf.d/
cat > /etc/systemd/resolved.conf.d/dns64.conf <<'EOF'
[Resolve]
# Germany
DNS=2a01:4f8:c2c:123f::1
# Netherland
DNS=2a00:1098:2b::1
# UK
DNS=2a00:1098:2c::1
# Finland
DNS=2a01:4f9:c010:3f02::1
# USA
DNS=2a01:4ff:f0:9876::1
Domains=~ghcr.io ~github.com ~githubusercontent.com ~k0s.sh ~k0sproject.io
EOF

# Restart resolved
systemctl restart systemd-resolved
resolvectl flush-caches
