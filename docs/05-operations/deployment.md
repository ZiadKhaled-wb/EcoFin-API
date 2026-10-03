# Deployment (Q01 · EC-103)

How the API gets from `main` to a running server, and how to roll it back.

## Overview

```
GitHub: push to main
  └─ CI (typecheck, lint, test)
       └─ Deploy (development)                      .github/workflows/deploy-dev.yml
            1. migrate  supabase db push            -> Supabase "EcoFin-Development"
            2. build    docker image                -> ghcr.io/<owner>/ecofin-api:sha-<commit>
            3. deploy   ssh deploy@VM ecofin-deploy -> pull, switch, wait for healthy
            4. smoke    GET https://<API_DOMAIN>/health

Azure VM (/opt/ecofin, docker compose)
  caddy :80/:443  -- HTTPS with a Let's Encrypt certificate, renewed automatically
    └─ api :3001  -- the image above (not published to the internet)
```

| Environment | API host | Database | Web |
|---|---|---|---|
| development | Azure VM (`20.56.139.170`) | Supabase `EcoFin-Development` | Vercel Preview |
| production | not set up yet (see "Production" below) | Supabase `EcoFin` | Vercel Production |

Without a domain, the API uses the free name `<vm-ip>.sslip.io`
(for example `20.56.139.170.sslip.io`), which resolves to the VM's IP. Switch to a
real domain later by re-running `setup.sh` with the new name and updating `API_DOMAIN`.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the API image (type-check + esbuild bundle, runs as `node`) |
| `deploy/vm/setup.sh` | One-time VM setup (Docker, firewall, `deploy` user, `/opt/ecofin`) |
| `deploy/vm/deploy.sh` | Release script, installed as `/usr/local/bin/ecofin-deploy` |
| `deploy/vm/compose.yml` | Caddy + API containers |
| `deploy/vm/Caddyfile` | HTTPS and reverse proxy |
| `deploy/vm/api.env.example` | Template for `/opt/ecofin/api.env` (API settings and secrets) |
| `.github/workflows/deploy-dev.yml` | Migrate, build, deploy, smoke test |

## One-time setup

### 1. Azure (VM owner)
The Network Security Group must allow inbound **22** (from the admins' IPs), **80** and **443** (from anywhere).
A static public IP is recommended, otherwise the IP changes after a stop/start.

### 2. A deploy key for GitHub Actions
Separate from any personal key. It can only run `ecofin-deploy` on the VM.

```bash
ssh-keygen -t ed25519 -N "" -C "github-actions-deploy@ecofin" -f ecofin_ci_deploy
```

`ecofin_ci_deploy.pub` goes to the VM (step 3), `ecofin_ci_deploy` goes to GitHub (step 5).
Delete both local files once they are stored.

### 3. Prepare the VM
From the API repo root, with the admin key:

```bash
scp -i <admin-key> -r deploy/vm <admin>@<vm-ip>:~/ecofin-vm
ssh -i <admin-key> <admin>@<vm-ip> "sudo bash ~/ecofin-vm/setup.sh <vm-ip>.sslip.io \"$(cat ecofin_ci_deploy.pub)\""
```

Re-run the same two commands whenever `deploy/vm/*` changes.

### 4. API settings on the VM
```bash
ssh -i <admin-key> <admin>@<vm-ip>
sudo -u deploy nano /opt/ecofin/api.env
```
Fill `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` from the
**EcoFin-Development** project, and `FRONTEND_URL` with the Vercel development URL.
The file stays on the VM (mode 600) and is never committed.

### 5. GitHub: environment `development`
Repository → Settings → Environments → **development**:

| Kind | Name | Value |
|---|---|---|
| Secret | `VM_SSH_KEY` | contents of `ecofin_ci_deploy` (private key) |
| Secret | `VM_SSH_KNOWN_HOSTS` | output of `ssh-keyscan -t ed25519 <vm-ip>` |
| Secret | `SUPABASE_DB_URL` | EcoFin-Development **Session pooler** connection string (Supabase → Connect), password percent-encoded. GitHub runners have no IPv6, so the direct `db.<ref>.supabase.co` host does not work. |
| Variable | `VM_HOST` | `<vm-ip>` |
| Variable | `API_DOMAIN` | `<vm-ip>.sslip.io` |

The image is pushed to GitHub Packages (`ghcr.io`). The workflow's own `GITHUB_TOKEN`
is passed to the VM for each pull, so no registry password is stored on the VM.

### 6. Vercel (web)
Preview / development environment variables of the web project:
`VITE_API_URL=https://<API_DOMAIN>`, `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` (EcoFin-Development).
`FRONTEND_URL` on the VM must be the exact web origin, because CORS allows one origin.

## Everyday use

- **Deploy:** merge to `main`. CI passes → migrations → image → VM → smoke test.
- **Rebuild main by hand:** Actions → *Deploy (development)* → Run workflow (leave the tag empty).
- **Roll back:** Actions → *Deploy (development)* → Run workflow with `image_tag` = an earlier
  tag (`sha-xxxxxxx`, listed in the VM's `releases.log` or in GitHub Packages).
  Migrations are not run on a rollback; migrations must stay backward compatible
  (add columns and tables, don't rename or drop in the same release).
- **Automatic rollback:** if a new release does not become healthy within ~2 minutes,
  `ecofin-deploy` switches back to the previous image and the workflow fails.

### On the VM
```bash
sudo -u deploy ecofin-deploy status     # containers + last releases
sudo -u deploy ecofin-deploy logs       # last 200 API log lines
cd /opt/ecofin && sudo -u deploy docker compose logs -f caddy
```

## Production (not set up yet)
Same files, a second environment: a production host, a GitHub environment
`production` (with required reviewers) holding the production secrets and
`SUPABASE_DB_URL` of the **EcoFin** project, and a workflow that deploys an
already-tested image tag. Production deploy = run that workflow with the tag.

## Troubleshooting

| Symptom | Check |
|---|---|
| `ssh: connect ... timed out` | NSG rule for port 22 / VM running / IP changed |
| Caddy has no certificate | Ports 80 and 443 open in the NSG; `API_DOMAIN` resolves to the VM |
| API container restarts | `ecofin-deploy logs`: usually a missing or invalid value in `api.env` |
| Browser CORS error | `FRONTEND_URL` in `api.env` must equal the web origin exactly |
| Migrate job fails to connect | Use the Session pooler URL, percent-encode the password |
