# Background jobs (F13, D34)

The job worker runs inside every API instance and needs no separate process. Several instances are safe: the database hands each job to one worker and queues each daily job once per shop per local day.

## Settings (API env)
- `JOBS_ENABLED` (default `true`): `false` stops the worker in that process.
- `JOBS_POLL_SECONDS` (default `30`): seconds between ticks.

## Job types
| Type | When | What | On failure |
|---|---|---|---|
| `ledger.reconcile` | daily, 03:00 shop time | F10 check: every cached stock/cash/store-credit balance = its ledger | retried (1, 2, 4, 8 min), dead after 5 attempts; a mismatch is NOT a failure, it's logged at error level |

New job types go in `src/jobs/registry.ts` (handler + optional daily entry).

## Logs
One JSON line per event, `component: "jobs"`, with `jobId`, `jobType`, `orgId`, `attempt`, `worker`:
- `job succeeded` (info), `job failed: will retry` (warn, `retryInSeconds`)
- `job failed for the last time: moved to the failed list` (error)
- `ledger.reconcile: cached balances do not match their ledger` (error, `count`, first 50 `mismatches`)

On the VM: `ssh deploy@<vm> logs` (forced command) and search for `"component":"jobs"`.

## The failed list and recent runs (SQL editor, dev/prod project, read-only)
```sql
-- failed list
SELECT job_type, tenant_slug, attempts, last_error, finished_at
FROM app.v_job_runs WHERE status = 'dead' ORDER BY finished_at DESC LIMIT 50;

-- last 24 hours
SELECT job_type, tenant_slug, status, attempts, run_at, finished_at, last_error
FROM app.v_job_runs WHERE created_at > now() - interval '24 hours' ORDER BY created_at DESC;
```

## Retrying a dead job by hand
Fix the cause first, then queue it again with fresh attempts (service role / SQL editor):
```sql
INSERT INTO public.jobs (organization_id, job_type, payload, max_attempts)
SELECT organization_id, job_type, payload, max_attempts FROM public.jobs WHERE id = '<dead job id>';
```
(A daily job's own run for that day stays dead; the copy has no daily key, so it doesn't block tomorrow's run.)
