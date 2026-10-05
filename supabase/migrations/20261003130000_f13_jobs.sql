-- F13 background jobs (D34). The queue is in the baseline: public.jobs + app.claim_jobs()
-- (FOR UPDATE SKIP LOCKED, stale 'running' jobs retried, out of attempts -> 'dead').
-- This adds what the API's job worker calls through PostgREST, as the service role only:
--   jobs_enqueue_daily  queue today's run of a daily job for every shop whose local time is past
--                       the job's start time; at most once per shop per day, even with many workers
--   jobs_claim          take due jobs of the types this worker handles (app.claim_jobs rules)
--   jobs_succeed        mark a claimed job done
--   jobs_fail           retry later, or 'dead' (the failed list) when out of attempts
--   jobs_ledger_mismatches  F10's reconciliation for the nightly 'ledger.reconcile' job
-- plus app.v_job_runs, a read-only view of runs and failures for support (no app access).

-- Looking a daily run up by type and key, in any status (the baseline's unique dedupe index only
-- covers queued/running jobs).
CREATE INDEX jobs_type_dedupe_lookup_idx ON public.jobs (job_type, dedupe_key) WHERE dedupe_key IS NOT NULL;

CREATE FUNCTION public.jobs_enqueue_daily(
    p_job_type     text,
    p_local_time   time,
    p_max_attempts integer DEFAULT 5,
    p_now          timestamptz DEFAULT now()          -- tests pass a fixed time
)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_count integer;
BEGIN
    IF p_job_type IS NULL OR p_job_type !~ '^[a-z][a-z0-9_.]{2,63}$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: job type must be lower-case letters, digits, dots or underscores'
            USING ERRCODE = 'P0001';
    END IF;
    IF p_local_time IS NULL OR p_max_attempts IS NULL OR p_max_attempts < 1 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: local time and max attempts are required' USING ERRCODE = 'P0001';
    END IF;

    -- Every worker ticks every minute: one at a time per job type, so the "not queued yet today"
    -- check below can't race. A run that already exists in ANY status (even succeeded or dead)
    -- counts, so a daily job runs once per shop per local day.
    PERFORM pg_advisory_xact_lock(hashtextextended('jobs.daily/' || p_job_type, 0));

    -- Shops with an unknown time zone are skipped (MATERIALIZED: filtered before any conversion,
    -- so one bad zone can't break the tick for every shop).
    WITH shops AS MATERIALIZED (
        SELECT o.id, o.timezone
        FROM public.organizations o
        WHERE o.status = 'active'
          AND o.timezone IN (SELECT name FROM pg_catalog.pg_timezone_names)
    ), local_now AS MATERIALIZED (
        SELECT s.id, p_now AT TIME ZONE s.timezone AS local_ts FROM shops s
    ), due AS (
        SELECT l.id, l.local_ts::date AS local_date FROM local_now l WHERE l.local_ts::time >= p_local_time
    )
    INSERT INTO public.jobs (organization_id, job_type, payload, dedupe_key, max_attempts)
    SELECT d.id, p_job_type, jsonb_build_object('businessDate', d.local_date),
           d.id::text || '/' || d.local_date::text, p_max_attempts
    FROM due d
    WHERE NOT EXISTS (
        SELECT 1 FROM public.jobs j
        WHERE j.job_type = p_job_type AND j.dedupe_key = d.id::text || '/' || d.local_date::text);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

-- Same rules as app.claim_jobs (SKIP LOCKED; a job stuck in 'running' for 15 minutes is taken
-- over; out of attempts -> 'dead'), limited to the job types this worker has handlers for, so a
-- server that doesn't know a type (an older version during a deploy) never takes it.
CREATE FUNCTION public.jobs_claim(p_worker text, p_types text[], p_limit integer DEFAULT 10)
RETURNS SETOF public.jobs LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_stale constant interval := interval '15 minutes';
BEGIN
    IF p_worker IS NULL OR length(p_worker) NOT BETWEEN 1 AND 200 OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100
       OR p_types IS NULL OR cardinality(p_types) = 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: worker id, job types and a limit of 1 to 100 are required'
            USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.jobs
       SET status = 'dead', finished_at = now(),
           last_error = COALESCE(last_error, 'max attempts reached')
     WHERE job_type = ANY (p_types)
       AND status IN ('queued', 'running', 'failed') AND attempts >= max_attempts
       AND (status <> 'running' OR locked_at < now() - v_stale);

    RETURN QUERY
    UPDATE public.jobs j
       SET status = 'running', locked_at = now(), locked_by = p_worker, attempts = j.attempts + 1
     WHERE j.id IN (SELECT id FROM public.jobs
                    WHERE job_type = ANY (p_types) AND attempts < max_attempts AND run_at <= now()
                      AND (status IN ('queued', 'failed')
                           OR (status = 'running' AND locked_at < now() - v_stale))
                    ORDER BY run_at
                    LIMIT p_limit
                    FOR UPDATE SKIP LOCKED)
    RETURNING j.*;
END;
$$;

-- Only the worker that holds the job can finish it: a worker that lost the job (it was claimed
-- again after 15 minutes) gets false and changes nothing.
CREATE FUNCTION public.jobs_succeed(p_job_id uuid, p_worker text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    UPDATE public.jobs
       SET status = 'succeeded', finished_at = now()
     WHERE id = p_job_id AND status = 'running' AND locked_by = p_worker;
    RETURN FOUND;
END;
$$;

-- A failed attempt: 'failed' and due again after p_retry_in, or 'dead' when this was the last
-- attempt. Returns the new status, or NULL when this worker no longer holds the job.
CREATE FUNCTION public.jobs_fail(p_job_id uuid, p_worker text, p_error text, p_retry_in interval)
RETURNS public.job_status LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_status public.job_status;
BEGIN
    UPDATE public.jobs j
       SET status      = CASE WHEN j.attempts >= j.max_attempts THEN 'dead' ELSE 'failed' END::public.job_status,
           run_at      = CASE WHEN j.attempts >= j.max_attempts THEN j.run_at
                              ELSE now() + GREATEST(COALESCE(p_retry_in, interval '0'), interval '0') END,
           finished_at = CASE WHEN j.attempts >= j.max_attempts THEN now() END,
           last_error  = left(COALESCE(NULLIF(p_error, ''), 'unknown error'), 2000)
     WHERE j.id = p_job_id AND j.status = 'running' AND j.locked_by = p_worker
    RETURNING j.status INTO v_status;
    RETURN v_status;
END;
$$;

-- F10 reconciliation for one shop, for the nightly 'ledger.reconcile' job (D33: internal only).
CREATE FUNCTION public.jobs_ledger_mismatches(p_organization_id uuid)
RETURNS TABLE (ledger text, organization_id uuid, subject_id uuid, branch_id uuid, detail text,
               cached numeric, from_ledger numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF p_organization_id IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a shop is required' USING ERRCODE = 'P0001';
    END IF;
    RETURN QUERY SELECT * FROM app.ledger_mismatches(p_organization_id);
END;
$$;

-- Runs and failures for support (the failed list is status = 'dead'). Not exposed to the app.
CREATE VIEW app.v_job_runs AS
SELECT j.id, j.job_type, j.organization_id, o.tenant_slug, j.status, j.attempts, j.max_attempts,
       j.run_at, j.locked_by, j.locked_at, j.finished_at, j.last_error, j.payload, j.created_at
FROM public.jobs j
LEFT JOIN public.organizations o ON o.id = j.organization_id;

REVOKE ALL ON app.v_job_runs FROM PUBLIC, anon, authenticated;
GRANT SELECT ON app.v_job_runs TO service_role;

REVOKE ALL ON FUNCTION public.jobs_enqueue_daily(text, time, integer, timestamptz),
                       public.jobs_claim(text, text[], integer),
                       public.jobs_succeed(uuid, text),
                       public.jobs_fail(uuid, text, text, interval),
                       public.jobs_ledger_mismatches(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.jobs_enqueue_daily(text, time, integer, timestamptz),
                          public.jobs_claim(text, text[], integer),
                          public.jobs_succeed(uuid, text),
                          public.jobs_fail(uuid, text, text, interval),
                          public.jobs_ledger_mismatches(uuid)
    TO service_role;
