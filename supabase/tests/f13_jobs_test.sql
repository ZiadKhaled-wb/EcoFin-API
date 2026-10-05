-- F13 background jobs (baseline jobs + app.claim_jobs; migration 20261003130000_f13_jobs.sql).
-- LOCAL / DEV ONLY. Run after `npm run db:reset`:  npm run db:smoke -- supabase/tests/f13_jobs_test.sql
-- db:smoke wraps the file in BEGIN ... ROLLBACK, so it leaves nothing behind.
-- The worker and the two-instance proof are in src/jobs/*.integration.test.ts (RUN_INTEGRATION=1).
-- Expected last line: failed 0.
--   1. claim / succeed / fail: one worker per job, retry later, then the failed list ('dead')
--   2. daily runs: per shop in the shop's time zone, once per local day in any status
--   3. access: service role only; the reconciliation wrapper needs a shop
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE SCHEMA t;
CREATE TABLE t.results (name text, ok boolean, detail text);

CREATE FUNCTION t.expect_error(p_name text, p_sql text, p_pattern text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        INSERT INTO t.results VALUES (p_name, false, 'no error raised');
    EXCEPTION WHEN others THEN
        INSERT INTO t.results VALUES (p_name, SQLERRM ~* p_pattern, SQLERRM);
    END;
END $$;

CREATE FUNCTION t.expect(p_name text, p_ok boolean, p_detail text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
    INSERT INTO t.results VALUES (p_name, p_ok, p_detail);
$$;

-- Nothing else may be due while this file runs (it is all rolled back at the end).
UPDATE public.jobs SET status = 'succeeded', finished_at = now() WHERE status IN ('queued', 'running', 'failed');

-- ---------------------------------------------------------------- fixtures
--   Cairo (UTC+3 in October), Tokyo (UTC+9), New York (UTC-4), a suspended shop, a bad time zone
INSERT INTO organizations (id, tenant_slug, name, plan_key, status, timezone) VALUES
  ('f1300000-0000-0000-0000-0000000000c1', 'f13-cairo',     'F13 Cairo',     'retail', 'active',    'Africa/Cairo'),
  ('f1300000-0000-0000-0000-0000000000a1', 'f13-tokyo',     'F13 Tokyo',     'retail', 'active',    'Asia/Tokyo'),
  ('f1300000-0000-0000-0000-0000000000b1', 'f13-newyork',   'F13 New York',  'retail', 'active',    'America/New_York'),
  ('f1300000-0000-0000-0000-0000000000d1', 'f13-suspended', 'F13 Suspended', 'retail', 'suspended', 'Africa/Cairo'),
  ('f1300000-0000-0000-0000-0000000000e1', 'f13-badzone',   'F13 Bad zone',  'retail', 'active',    'Mars/Olympus');

CREATE FUNCTION t.types() RETURNS text[] LANGUAGE sql AS $$
    SELECT ARRAY['f13.test_flaky', 'f13.test_ok', 'f13.test_long_error', 'f13.test_crash', 'f13.test_daily']
$$;
CREATE FUNCTION t.runs(p_type text, p_org text) RETURNS bigint LANGUAGE sql AS $$
    SELECT count(*) FROM public.jobs WHERE job_type = p_type AND organization_id = p_org::uuid
$$;
CREATE FUNCTION t.business_date(p_type text, p_org text) RETURNS text LANGUAGE sql AS $$
    SELECT string_agg(payload ->> 'businessDate', ',' ORDER BY created_at) FROM public.jobs
    WHERE job_type = p_type AND organization_id = p_org::uuid
$$;

-- ---------------------------------------------------------------- 1. claim, succeed, fail
INSERT INTO public.jobs (id, job_type, payload, max_attempts, run_at) VALUES
  ('f1310000-0000-0000-0000-000000000001', 'f13.test_flaky', '{}', 2, now() - interval '1 minute');

SELECT t.expect('1.1 a due job is claimed: running, attempt 1, locked by the worker',
  (SELECT count(*) = 1 AND bool_and(status = 'running' AND attempts = 1 AND locked_by = 'worker-1')
     FROM public.jobs_claim('worker-1', t.types(), 10)));
SELECT t.expect('1.2 another worker can''t claim it while it runs', NOT EXISTS (SELECT 1 FROM public.jobs_claim('worker-2', t.types(), 10)));
SELECT t.expect('1.3 another worker can''t finish or fail it',
  NOT public.jobs_succeed('f1310000-0000-0000-0000-000000000001', 'worker-2')
  AND public.jobs_fail('f1310000-0000-0000-0000-000000000001', 'worker-2', 'x', interval '0') IS NULL);

SELECT t.expect('1.4 a failed attempt with attempts left is retried later: status failed',
  public.jobs_fail('f1310000-0000-0000-0000-000000000001', 'worker-1', 'ETA timeout', interval '1 hour') = 'failed');
SELECT t.expect('1.5 the retry waits: due in an hour, error kept, not claimable yet',
  (SELECT run_at = now() + interval '1 hour' AND last_error = 'ETA timeout' AND finished_at IS NULL
     FROM public.jobs WHERE id = 'f1310000-0000-0000-0000-000000000001')
  AND NOT EXISTS (SELECT 1 FROM public.jobs_claim('worker-2', t.types(), 10)));

UPDATE public.jobs SET run_at = now() - interval '1 second' WHERE id = 'f1310000-0000-0000-0000-000000000001';
SELECT t.expect('1.6 once due, any worker retries it: attempt 2',
  (SELECT count(*) = 1 AND bool_and(attempts = 2 AND locked_by = 'worker-2') FROM public.jobs_claim('worker-2', t.types(), 10)));
SELECT t.expect('1.7 failing the last attempt puts it in the failed list (dead)',
  public.jobs_fail('f1310000-0000-0000-0000-000000000001', 'worker-2', 'ETA timeout again', interval '0') = 'dead');
SELECT t.expect('1.8 a dead job is finished, keeps its last error and is never claimed again',
  (SELECT finished_at IS NOT NULL AND last_error = 'ETA timeout again'
     FROM public.jobs WHERE id = 'f1310000-0000-0000-0000-000000000001')
  AND NOT EXISTS (SELECT 1 FROM public.jobs_claim('worker-1', t.types(), 10)));
SELECT t.expect('1.9 the support view lists it with the shop, status and error',
  EXISTS (SELECT 1 FROM app.v_job_runs WHERE id = 'f1310000-0000-0000-0000-000000000001'
           AND status = 'dead' AND attempts = 2 AND last_error = 'ETA timeout again'));

INSERT INTO public.jobs (id, job_type, payload, run_at) VALUES
  ('f1310000-0000-0000-0000-000000000002', 'f13.test_ok', '{}', now() - interval '1 minute');
SELECT count(*) FROM public.jobs_claim('worker-1', t.types(), 10);
SELECT t.expect('1.10 the worker holding a job can mark it succeeded',
  public.jobs_succeed('f1310000-0000-0000-0000-000000000002', 'worker-1'));
SELECT t.expect('1.11 a successful run is succeeded and finished',
  (SELECT status = 'succeeded' AND finished_at IS NOT NULL FROM public.jobs WHERE id = 'f1310000-0000-0000-0000-000000000002'));

INSERT INTO public.jobs (id, job_type, payload, run_at) VALUES
  ('f1310000-0000-0000-0000-000000000003', 'f13.test_long_error', '{}', now() - interval '1 minute');
SELECT count(*) FROM public.jobs_claim('worker-1', t.types(), 10);
SELECT public.jobs_fail('f1310000-0000-0000-0000-000000000003', 'worker-1', repeat('e', 5000), interval '1 day');
SELECT t.expect('1.12 an error message is cut to 2,000 characters',
  (SELECT length(last_error) = 2000 FROM public.jobs WHERE id = 'f1310000-0000-0000-0000-000000000003'));

-- A worker that crashed mid-job: after 15 minutes another worker takes the job over.
INSERT INTO public.jobs (id, job_type, payload, run_at, status, attempts, locked_by, locked_at) VALUES
  ('f1310000-0000-0000-0000-000000000004', 'f13.test_crash', '{}', now() - interval '1 hour', 'running', 1,
   'worker-crashed', now() - interval '20 minutes');
SELECT t.expect('1.13 a job stuck in running for 15+ minutes is taken over by another worker',
  (SELECT count(*) = 1 AND bool_and(id = 'f1310000-0000-0000-0000-000000000004' AND attempts = 2)
     FROM public.jobs_claim('worker-1', t.types(), 10)));
SELECT t.expect('1.14 the crashed worker can''t finish it any more',
  NOT public.jobs_succeed('f1310000-0000-0000-0000-000000000004', 'worker-crashed'));

SELECT t.expect_error('1.15 a claim needs a worker id and a sane limit', $$SELECT * FROM public.jobs_claim('', t.types(), 10)$$, 'VALIDATION_FAILED');
SELECT t.expect_error('1.16 a claim limit above 100 is refused', $$SELECT * FROM public.jobs_claim('w', t.types(), 101)$$, 'VALIDATION_FAILED');
SELECT t.expect_error('1.17 a claim needs at least one job type', $$SELECT * FROM public.jobs_claim('w', '{}', 10)$$, 'VALIDATION_FAILED');
INSERT INTO public.jobs (id, job_type, payload, run_at) VALUES
  ('f1310000-0000-0000-0000-000000000005', 'f13.test_unknown', '{}', now() - interval '1 minute');
SELECT t.expect('1.18 a worker never takes a job type it has no handler for',
  NOT EXISTS (SELECT 1 FROM public.jobs_claim('worker-1', t.types(), 10))
  AND (SELECT count(*) = 1 FROM public.jobs_claim('worker-1', ARRAY['f13.test_unknown'], 10)));

-- ---------------------------------------------------------------- 2. daily runs per shop
-- 00:30 UTC on 5 Oct = 03:30 in Cairo, 09:30 in Tokyo, 20:30 on 4 Oct in New York.
SELECT public.jobs_enqueue_daily('f13.test_daily', '05:00', 5, '2026-10-05 00:30:00+00');
SELECT t.expect('2.1 at a 05:00 start, Tokyo (09:30) is due, Cairo (03:30) is not yet',
  t.runs('f13.test_daily', 'f1300000-0000-0000-0000-0000000000a1') = 1
  AND t.runs('f13.test_daily', 'f1300000-0000-0000-0000-0000000000c1') = 0);
SELECT t.expect('2.2 New York (20:30 the day before) is due for its own 4 October',
  t.business_date('f13.test_daily', 'f1300000-0000-0000-0000-0000000000b1') = '2026-10-04');

SELECT public.jobs_enqueue_daily('f13.test_daily', '05:00', 5, '2026-10-05 02:30:00+00');
SELECT t.expect('2.3 two hours later Cairo (05:30) is due for 5 October; Tokyo isn''t queued twice',
  t.runs('f13.test_daily', 'f1300000-0000-0000-0000-0000000000c1') = 1
  AND t.business_date('f13.test_daily', 'f1300000-0000-0000-0000-0000000000c1') = '2026-10-05'
  AND t.runs('f13.test_daily', 'f1300000-0000-0000-0000-0000000000a1') = 1);
SELECT t.expect('2.4 the run carries its business date and a per-shop, per-day key',
  (SELECT payload = '{"businessDate": "2026-10-05"}'::jsonb
          AND dedupe_key = 'f1300000-0000-0000-0000-0000000000a1/2026-10-05' AND max_attempts = 5
     FROM public.jobs WHERE job_type = 'f13.test_daily' AND organization_id = 'f1300000-0000-0000-0000-0000000000a1'));

UPDATE public.jobs SET status = 'succeeded', finished_at = now() WHERE job_type = 'f13.test_daily';
-- 03:00 UTC: still 5 October in Cairo and Tokyo, and 4 October (23:00) in New York.
SELECT t.expect('2.5 after today''s runs finished, ticking again the same local day queues nothing',
  public.jobs_enqueue_daily('f13.test_daily', '05:00', 5, '2026-10-05 03:00:00+00') = 0);
UPDATE public.jobs SET status = 'dead', finished_at = now() WHERE job_type = 'f13.test_daily';
SELECT t.expect('2.6 a dead run isn''t retried by the daily tick either (the failed list keeps it)',
  public.jobs_enqueue_daily('f13.test_daily', '05:00', 5, '2026-10-05 03:30:00+00') = 0);

SELECT public.jobs_enqueue_daily('f13.test_daily', '05:00', 5, '2026-10-06 03:00:00+00');
SELECT t.expect('2.7 the next local day queues the next run (Cairo now has 5 and 6 October)',
  t.business_date('f13.test_daily', 'f1300000-0000-0000-0000-0000000000c1') = '2026-10-05,2026-10-06');
SELECT t.expect('2.8 suspended shops and shops with an unknown time zone are skipped; others still run',
  t.runs('f13.test_daily', 'f1300000-0000-0000-0000-0000000000d1') = 0
  AND t.runs('f13.test_daily', 'f1300000-0000-0000-0000-0000000000e1') = 0
  AND t.runs('f13.test_daily', 'f1300000-0000-0000-0000-0000000000b1') = 2);
SELECT t.expect('2.9 every seeded active shop got its run too (one per local day)',
  NOT EXISTS (SELECT 1 FROM public.organizations o
               WHERE o.status = 'active' AND o.timezone IN (SELECT name FROM pg_timezone_names)
                 AND (SELECT count(*) FROM public.jobs j WHERE j.job_type = 'f13.test_daily'
                       AND j.organization_id = o.id) NOT BETWEEN 1 AND 2));
SELECT t.expect_error('2.10 a bad job type is refused',
  $$SELECT public.jobs_enqueue_daily('Bad Type!', '01:00')$$, 'VALIDATION_FAILED');

-- ---------------------------------------------------------------- 3. access
SELECT t.expect('3.1 app users and anon can''t call any job function; the service role can',
  (SELECT bool_and(NOT has_function_privilege('authenticated', f, 'EXECUTE')
               AND NOT has_function_privilege('anon', f, 'EXECUTE')
               AND has_function_privilege('service_role', f, 'EXECUTE'))
     FROM unnest(ARRAY['public.jobs_enqueue_daily(text,time,integer,timestamptz)', 'public.jobs_claim(text,text[],integer)',
                       'public.jobs_succeed(uuid,text)', 'public.jobs_fail(uuid,text,text,interval)',
                       'public.jobs_ledger_mismatches(uuid)']) f));
SELECT t.expect('3.2 app users can''t read the jobs table or the support view',
  NOT has_table_privilege('authenticated', 'public.jobs', 'SELECT')
  AND NOT has_table_privilege('authenticated', 'app.v_job_runs', 'SELECT')
  AND NOT has_table_privilege('anon', 'app.v_job_runs', 'SELECT')
  AND has_table_privilege('service_role', 'app.v_job_runs', 'SELECT'));
SELECT t.expect_error('3.3 the reconciliation wrapper needs a shop',
  $$SELECT * FROM public.jobs_ledger_mismatches(NULL)$$, 'VALIDATION_FAILED');
SELECT t.expect('3.4 a shop with no stock or cash reconciles (no rows)',
  NOT EXISTS (SELECT 1 FROM public.jobs_ledger_mismatches('f1300000-0000-0000-0000-0000000000c1')));

-- ---------------------------------------------------------------- result
SELECT name, ok, detail FROM t.results WHERE NOT ok;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
