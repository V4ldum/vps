# Step 1

```bash
curl -s https://raw.githubusercontent.com/V4ldum/vps/refs/heads/main/dns.sh | bash
```

# Step 2

```bash
cd ~
git clone https://github.com/V4ldum/vps >/dev/null
vps/provision.sh
```

# Step 3

```bash
vps/deploy.sh
rm -rf vps
```
