#!/bin/bash

if [ "$EUID" -ne 0 ]
then
    echo "Must be run with sudo"
    exit 1;
fi

# Create dns64 interface
cat > /etc/systemd/network/100-dns64.netdev <<'EOF'
[NetDev]
Name=dns64
Kind=dummy
EOF

# Create dns64 network
cat > /etc/systemd/network/100-dns64.network <<'EOF'
[Match]
Name=dns64

[Network]
DNS=2a00:1098:2b::1
DNS=2a00:1098:2c::1
DNS=2a01:4f9:c010:3f02::1
Domains=~ghcr.io ~github.com ~githubusercontent.com
DNSSEC=no
LinkLocalAddressing=no
IPv6AcceptRA=no
ConfigureWithoutCarrier=yes

[Link]
ActivationPolicy=always-up

[DHCP]
UseDNS=no
EOF

# Restart resolved
systemctl restart systemd-resolved
