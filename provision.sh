#!/bin/bash

# Called with `install_if_changed FILE << 'EOF'`
# returns 0 if the file was changed, 1 otherwise
function install_if_changed() {
    local target="$1"

    # Create temporary file
    local temp_file
    temp_file=$(mktemp) || exit 1
    cat > "$temp_file"

    # Compare with existing file
    cmp -s "$target" "$temp_file"
    local is_different=$?

    # Install if different
    if [ "$is_different" -ne 0 ]
    then
        local output
        if ! output=$(install -D -m 644 "$temp_file" "$target" 2>&1)
        then
            echo ">> Failed to install $target:"
            echo "$output"
            is_different=0
        fi
    fi

    # Clean up and return
    rm -f "$temp_file"
    [ $is_different -ne 0 ] && return 0 || return 1
}


if [ "$EUID" -ne 0 ]
then
    echo "Must be run as root"
    exit 1;
fi


# cd into the script's directory
cd "$(dirname "$0")" || exit 1
REBOOT_REQUIRED=0

# ----------------------
# Update system
echo "Updating the system and adding necessary software"

apt-get update -y &>/dev/null
apt-get upgrade -y &>/dev/null
apt-get install -y vim sqlite3 tree curl apt-transport-https ca-certificates gnupg &>/dev/null


# ----------------------
# Unattended Updates
echo "Setting up unattended updates"

# Security updates are already applied on Ubuntu Server
# (Hetzner actually enables all updates)

# Enable auto-reboot
install_if_changed /etc/apt/apt.conf.d/52unattended-updates-override <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF

# Confirm auto-reboot
if ! ERROR=$(apt-config dump 2>&1 >/dev/null)
then
    echo ">> Error parsing auto-reboot configuration :"
    echo ">> $ERROR"
    exit 1;
fi

# Change upgrade timer to weekly
NAME="apt-daily-upgrade.timer"
install_if_changed /etc/systemd/system/$NAME.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=Tue 01:00
RandomizedDelaySec=30min
Persistent=true
EOF
UPGRADE_TIMER_CHANGED=$(($? == 0))

# Confirm upgrade timer
ERROR=$(systemd-analyze verify "$NAME" 2>&1 | grep "$NAME")
if [ -n "$ERROR" ]
then
    echo ">> Error parsing upgrade timer :"
    echo ">> $ERROR"
    exit 1;
fi


# ----------------------
# SSH
echo "Hardening up SSH"

install_if_changed /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
Port 2222
EOF
SSH_CONFIG_CHANGED=$(($? == 0))

# Confirm SSH
if ! ERROR=$(sshd -t 2>&1)
then
    echo ">> Error parsing SSH configuration :"
    echo ">> $ERROR"
    exit 1;
fi


# ----------------------
# Tailscale
echo "Setting up Tailscale"

which tailscale &>/dev/null || (curl -fsSL https://tailscale.com/install.sh | sh &>/dev/null)
tailscale up --ssh --accept-dns=false
echo ">> Don't forget to disable key expiry on the dashboard"


# ----------------------
# Firewall
echo "Updating firewall settings"

apt-get install -y ufw &>/dev/null
ufw allow 80/tcp >/dev/null || exit 1
ufw allow 443/tcp >/dev/null || exit 1
ufw allow 2222/tcp >/dev/null || exit 1
ufw default deny incoming >/dev/null || exit 1
ufw default allow outgoing >/dev/null || exit 1
ufw --force enable >/dev/null || exit 1


# ----------------------
# Fail2ban
echo "Setting up fail2ban"

apt-get install -y fail2ban &>/dev/null
systemctl enable fail2ban &>/dev/null

install_if_changed /etc/fail2ban/jail.local < fail2ban/jail.local
FAIL2BAN_CONFIG_CHANGED=$(($? == 0))

# Confirm fail2ban
if ! ERROR=$(fail2ban-client -t 2>&1)
then
    echo ">> Error parsing fail2ban configuration :"
    echo ">> $ERROR"
    exit 1;
fi

# Restart fail2ban
if [ "$FAIL2BAN_CONFIG_CHANGED" -eq 1 ]
then
    echo "Fail2ban config changed, restarting fail2ban"
    systemctl reload-or-restart fail2ban >/dev/null
fi


# ----------------------
# GitHub
echo "Setting up GitHub CLI"

apt-get install -y gh &>/dev/null
ssh-keygen -F github.com >/dev/null || ssh-keyscan -H github.com >> ~/.ssh/known_hosts
if ! gh auth status &>/dev/null
then
    echo "Please authenticate with SSH using the \"VPS\" token:"
    gh auth login
fi


# ----------------------
# Prepare Kubernetes
echo "Preparing for Kubernetes install"

if ! which kubesolo &>/dev/null
then
    # Uninstall docker from the box
    # Kubesolo needs docker to be completely removed before installing kubernetes

    # List all docker adjacent packages installed
    # dpkg -l | grep -iE 'docker|containerd|runc'
    mapfile -t PKGS < <(dpkg-query -W -f='${db:Status-Status} ${binary:Package}\n' \
        | awk '$1=="installed" {print $2}' \
        | grep -iE 'docker|containerd|runc')
    if [ "${#PKGS[@]}" -gt 0 ]
    then
        REBOOT_REQUIRED=1
        apt-get autoremove -y --purge "${PKGS[@]}" &>/dev/null
    fi

    # List all docker adjacent files on the system
    # find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run \) -prune -o \( -iname '*docker*' -o -iname '*containerd*' -o -name 'runc' \) -prune -print 2>/dev/null
    # Some files are false positives
    rm -rf /var/lib/docker /var/lib/containerd /opt/containerd
    rm -f /etc/apt/keyrings/docker.asc /etc/apt/sources.list.d/docker.sources
    apt-get update -y &>/dev/null # Refresh apt cache
    getent group docker >/dev/null && groupdel docker
else
    echo "> Kubesolo is already installed, unsafe to delete docker dependencies"
fi


# ----------------------
# Cleanup and restart

apt-get autoremove --purge -y &>/dev/null
apt-get clean -y &>/dev/null

echo "Finished provisioning"

# Restart SSH
if [ "$SSH_CONFIG_CHANGED" -eq 1 ]
then
    echo "SSH config changed"
    systemctl restart ssh

    read -rp "SSH restarted, please confirm SSH works with the new configuration? (y/N) "
    case "$REPLY" in
        [yY]|[yY][eE][sS]) ;;
        *) {
            echo "Stopping the script, fix the SSH config and reload!";
            echo "Exiting SSH will lock you out of the box";
            exit 1;
        } ;;
    esac
fi

if [ "$REBOOT_REQUIRED" -eq 1 ] || [ -f /var/run/reboot-required ]
then
    # Reboot if needed
    read -rp "Reboot required, are you ready to reboot now? (y/N) "
    case "$REPLY" in
        [yY]|[yY][eE][sS]) reboot ;;
        *) echo ">> Reboot skipped, don't forget to reboot manually!" ;;
    esac
else
    # Restart upgrade timer
    if [ "$UPGRADE_TIMER_CHANGED" -eq 1 ]
    then
        echo "Upgrade timer changed, restarting timer"

        systemctl daemon-reload
        systemctl restart apt-daily-upgrade.timer
    fi
fi
