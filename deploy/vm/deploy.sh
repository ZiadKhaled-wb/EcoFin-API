#!/usr/bin/env bash
# EcoFin release script. Installed by setup.sh as /usr/local/bin/ecofin-deploy
# (owned by root) and run as the `deploy` user.
#
# The CI deploy key can run ONLY this script: its authorized_keys entry has
# command="/usr/local/bin/ecofin-deploy", so the requested action arrives in
# $SSH_ORIGINAL_COMMAND and the registry token arrives on stdin.
#
#   deploy <image-ref> <registry-user>   pull, switch, wait for healthy, else roll back
#   status                               containers and the last releases
#   logs                                 last 200 API log lines
#
# An admin on the VM can run the same actions:  sudo -u deploy ecofin-deploy status
set -Eeuo pipefail

APP_DIR=/opt/ecofin
cd "$APP_DIR"

read -r -a args <<< "${SSH_ORIGINAL_COMMAND:-$*}"
action="${args[0]:-}"

current_image() { sed -n 's/^API_IMAGE=//p' .env; }
set_image()     { sed -i "s|^API_IMAGE=.*|API_IMAGE=$1|" .env; }

wait_healthy() {
    local id status
    for _ in $(seq 1 40); do
        id="$(docker compose ps -q api 2>/dev/null || true)"
        status="$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null || echo starting)"
        case "$status" in
            healthy)   return 0 ;;
            unhealthy) return 1 ;;
        esac
        sleep 3
    done
    return 1
}

case "$action" in
    status)
        docker compose ps
        echo "--- last releases"
        tail -n 10 releases.log 2>/dev/null || echo "(none yet)"
        exit 0
        ;;
    logs)
        docker compose logs --no-color --tail 200 api
        exit 0
        ;;
    deploy) ;;
    *)
        echo "usage: deploy <image-ref> <registry-user> | status | logs" >&2
        exit 2
        ;;
esac

image="${args[1]:-}"
registry_user="${args[2]:-}"
[[ "$image" =~ ^ghcr\.io/[a-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] || { echo "refusing image reference: '$image'" >&2; exit 2; }
[[ "$registry_user" =~ ^[A-Za-z0-9-]+$ ]] || { echo "refusing registry user: '$registry_user'" >&2; exit 2; }

# The token is short-lived (GitHub Actions GITHUB_TOKEN) and is never written
# to the deploy user's normal Docker config.
IFS= read -r token || true
[ -n "${token:-}" ] || { echo "expected a registry token on stdin" >&2; exit 2; }
DOCKER_CONFIG="$(mktemp -d)"
export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
printf '%s' "$token" | docker login ghcr.io -u "$registry_user" --password-stdin >/dev/null
docker pull --quiet "$image"

previous="$(current_image)"
echo "switching API: '${previous:-none}' -> '$image'"
set_image "$image"
docker compose up -d --remove-orphans

if wait_healthy; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $image" >> releases.log
    docker image prune -af --filter "until=336h" >/dev/null 2>&1 || true
    echo "deployed $image"
    exit 0
fi

echo "new release did not become healthy; last API logs:" >&2
docker compose logs --no-color --tail 80 api >&2 || true
if [ -n "$previous" ] && [ "$previous" != "$image" ]; then
    echo "rolling back to $previous" >&2
    set_image "$previous"
    docker compose up -d --remove-orphans
    if wait_healthy; then echo "rolled back to $previous" >&2; else echo "ROLLBACK ALSO UNHEALTHY - check the VM" >&2; fi
fi
exit 1
