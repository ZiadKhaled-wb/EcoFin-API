# Monitoring (Q02, D35)

Errors go to **Sentry** (API and website), uptime is watched by **UptimeRobot**. Both are off until you add the keys below; nothing in the repo holds a key.

## 1. Sentry (about 10 minutes, once)
1. Go to https://sentry.io/signup/ and create a free account (Developer plan). Pick the data region you prefer (EU is fine).
2. Create an organization if asked (e.g. `ecotech`).
3. **Projects -> Create Project -> Node.js / Express**, name it `ecofin-api`, alert frequency "Alert me on every new issue", **Create**. Skip the setup wizard (the code is already in).
4. **Projects -> Create Project -> React**, name it `ecofin-web`, same alert setting, **Create**.
5. For each project: **Settings -> Projects -> <project> -> Client Keys (DSN)** and copy the DSN (`https://...ingest...sentry.io/...`). A DSN is not a password (browsers see the web one), but keep it out of git anyway.
6. **Settings -> Projects -> <project> -> Security & Privacy**: turn **Data Scrubber** and **Use Default Scrubbers** on, and **Prevent Storing of IP Addresses** on (defence in depth; the SDKs already send none).

## 2. Put the keys in place
**API (dev VM):**
```bash
ssh -i <admin-key> <admin>@<vm-ip>
sudo -u deploy nano /opt/ecofin/api.env
```
Add two lines, save, then redeploy (Actions -> *Deploy (development)* -> Run workflow) so the container restarts with them:
```
SENTRY_DSN=<ecofin-api DSN>
SENTRY_ENVIRONMENT=development
```
**Website (Vercel):** project `eco-fin-web` -> Settings -> Environment Variables -> add `VITE_SENTRY_DSN` = `<ecofin-web DSN>` and `VITE_SENTRY_ENVIRONMENT` = `development` for Production and Preview, then Deployments -> latest -> Redeploy (Vite reads them at build time).

## 3. Check it works (the Q02 "Done when")
Log in on the website as a shop owner, open the browser console (F12) and run:
```js
const { state } = JSON.parse(localStorage.getItem('ecofin-auth'));
await fetch('https://<API_DOMAIN>/api/monitoring/test-error', { method: 'POST', headers: { Authorization: 'Bearer ' + state.accessToken, 'x-org-id': state.orgId } }).then((r) => r.json());
```
(or call it from the Swagger page `/docs` with your token). The answer is a 500 with `error.requestId`. In Sentry -> Issues (project `ecofin-api`) a `MonitoringTestError` appears within a minute; its tags show the same `requestId`, the shop (`orgId`), `route`, `release` (`sha-<commit>`) and `environment`. Search `requestId:<id>` to find it. Resolve the issue afterwards.

## 4. UptimeRobot (about 5 minutes, once)
1. https://uptimerobot.com -> Register (free plan).
2. **+ New monitor** -> HTTP(s) -> name `EcoFin API (dev)`, URL `https://<API_DOMAIN>/health`, interval 5 minutes. Under "Advanced" add keyword monitoring if you like: keyword `"status":"ok"` must exist. Alert contact: your email.
3. **+ New monitor** -> HTTP(s) -> `EcoFin Web (dev)`, URL `https://eco-fin-web.vercel.app`, 5 minutes.
4. Optional: a public status page with both monitors.

## What alerts you
| Event | Where | Tags to search |
|---|---|---|
| API 5xx | Sentry `ecofin-api` | `requestId`, `orgId`, `route`, `path`, `code` |
| Browser crash / API 5xx seen by a user | Sentry `ecofin-web` | `requestId` (same as the API's), `source:api`, `status` |
| Job in the failed list | Sentry `ecofin-api` | `problem:job.dead`, `jobType`, `jobId`, `orgId` |
| Ledger cache mismatch | Sentry `ecofin-api` | `problem:ledger.mismatch`, `orgId`, `count` |
| API or site down | UptimeRobot email | - |

The request id also finds the API log line: `ecofin-deploy logs` on the VM, search the id.
