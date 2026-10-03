#!/usr/bin/env bash
# One-time VM setup for the EcoFin API (Ubuntu 22.04/24.04). Safe to re-run:
# it also re-installs compose.yml, Caddyfile and deploy.sh after they change.
#
#   scp -r deploy/vm <admin>@<vm>:~/ecofin-vm
#   ssh <admin>@<vm> 'sudo bash ~/ecofin-vm/setup.sh <api-domain> "<ci-deploy-public-key>"'
#
# What it does:
#   - installs Docker Engine + compose plugin (Docker's apt repository)
#   - turns on unattended security upgrades, ufw (22, 80, 443), swap on small VMs
#   - creates the `deploy` user; the CI key may run only /usr/local/bin/ecofin-deploy
#   - prepares /opt/ecofin (compose.yml, Caddyfile, .env, api.env)
# It does not change sshd settings, so it cannot lock you out.
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
domain="${1:?usage: setup.sh <api-domain> \"<ci-deploy-public-key>\"}"
ci_pubkey="${2:?usage: setup.sh <api-domain> \"<ci-deploy-public-key>\"}"
[[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "invalid domain: $domain" >&2; exit 1; }
[[ "$ci_pubkey" =~ ^ssh-(ed25519|rsa)\ [A-Za-z0-9+/=]+(\ [^\"]*)?$ ]] || { echo "not an ssh public key" >&2; exit 1; }

src="$(cd "$(dirname "$0")" && pwd)"
app_dir=/opt/ecofin
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = ubuntu ] || echo "warning: written for Ubuntu, found ${ID:-unknown}" >&2
export DEBIAN_FRONTEND=noninteractive

echo "==> packages"
apt-get update -y
apt-get install -y ca-certificates curl ufw unattended-upgrades

echo "==> docker"
if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

echo "==> automatic security updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF

echo "==> swap (only when RAM < 2 GB and no swap yet)"
mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
if [ "$mem_kb" -lt 2097152 ] && ! swapon --show | grep -q .; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "==> firewall (the Azure NSG is the outer firewall; this is the inner one)"
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

echo "==> deploy user"
id deploy >/dev/null 2>&1 || useradd --create-home --shell /bin/bash deploy
usermod -aG docker deploy
install -d -m 0700 -o deploy -g deploy /home/deploy/.ssh
printf 'command="/usr/local/bin/ecofin-deploy",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty %s\n' "$ci_pubkey" \
    > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 0600 /home/deploy/.ssh/authorized_keys

echo "==> /opt/ecofin"
install -m 0755 -o root -g root "$src/deploy.sh" /usr/local/bin/ecofin-deploy
install -d -m 0750 -o deploy -g deploy "$app_dir"
install -m 0644 -o deploy -g deploy "$src/compose.yml" "$src/Caddyfile" "$app_dir/"
if [ ! -f "$app_dir/.env" ]; then
    printf 'API_IMAGE=\nAPI_DOMAIN=%s\n' "$domain" > "$app_dir/.env"
fi
sed -i "s|^API_DOMAIN=.*|API_DOMAIN=$domain|" "$app_dir/.env"
chown deploy:deploy "$app_dir/.env"
chmod 0600 "$app_dir/.env"
if [ ! -f "$app_dir/api.env" ]; then
    install -m 0600 -o deploy -g deploy "$src/api.env.example" "$app_dir/api.env"
fi

echo
echo "Done. Next:"
echo "  1. Fill in the API settings:   sudo -u deploy nano $app_dir/api.env"
echo "  2. Deploy from GitHub Actions (Deploy (development) workflow)."
echo "  3. Check:                     sudo -u deploy ecofin-deploy status"
