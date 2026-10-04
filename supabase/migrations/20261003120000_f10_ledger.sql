-- F10 ledger core: the reconciliation check (D33).
-- The ledgers themselves are in the baseline (section 17): append-only stock_movements,
-- cash_movements and store_credit_movements; stock_levels, cash_balances and
-- store_credit_balances are caches that only the AFTER INSERT triggers change, under a row lock.
-- This adds the check that every cache still equals the sum of its ledger.

-- One row per mismatch; no rows = every cache matches its ledger. A cache row that's missing
-- while the ledger has a non-zero sum (or the other way round) is a mismatch too.
--   stock_on_hand  stock_levels.on_hand   = SUM(stock_movements.quantity)   per product, branch, state
--   stock_reserved stock_levels.reserved  = SUM(active reservations)        per product, branch (sellable)
--   cash           cash_balances.balance  = SUM(cash_movements.amount)      per cash account
--   store_credit   store_credit_balances  = SUM(store_credit_movements)     per customer
-- Internal (D33): CI runs it after the full test suite; the nightly job (F13) and monitoring
-- (Q02) will run it too. Not granted to app users. p_organization_id NULL = every shop.
CREATE FUNCTION app.ledger_mismatches(p_organization_id uuid DEFAULT NULL)
RETURNS TABLE (
    ledger          text,
    organization_id uuid,
    subject_id      uuid,      -- product, cash account or customer
    branch_id       uuid,      -- NULL for cash accounts and customers
    detail          text,      -- stock state for stock rows
    cached          numeric,
    from_ledger     numeric
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    WITH levels AS (
        SELECT l.organization_id, l.product_id, l.branch_id, l.stock_state, l.on_hand, l.reserved
        FROM public.stock_levels l
        WHERE p_organization_id IS NULL OR l.organization_id = p_organization_id
    ), moved AS (
        SELECT m.organization_id, m.product_id, m.branch_id, m.stock_state, SUM(m.quantity) AS quantity
        FROM public.stock_movements m
        WHERE p_organization_id IS NULL OR m.organization_id = p_organization_id
        GROUP BY m.organization_id, m.product_id, m.branch_id, m.stock_state
    ), reserved AS (
        SELECT r.organization_id, r.product_id, r.branch_id, SUM(r.quantity) AS quantity
        FROM public.stock_reservations r
        WHERE r.status = 'active' AND (p_organization_id IS NULL OR r.organization_id = p_organization_id)
        GROUP BY r.organization_id, r.product_id, r.branch_id
    ), balances AS (
        SELECT b.organization_id, b.cash_account_id, b.balance
        FROM public.cash_balances b
        WHERE p_organization_id IS NULL OR b.organization_id = p_organization_id
    ), cash AS (
        SELECT c.organization_id, c.cash_account_id, SUM(c.amount) AS amount
        FROM public.cash_movements c
        WHERE p_organization_id IS NULL OR c.organization_id = p_organization_id
        GROUP BY c.organization_id, c.cash_account_id
    ), credit_balances AS (
        SELECT s.organization_id, s.customer_id, s.balance
        FROM public.store_credit_balances s
        WHERE p_organization_id IS NULL OR s.organization_id = p_organization_id
    ), credit AS (
        SELECT s.organization_id, s.customer_id, SUM(s.amount) AS amount
        FROM public.store_credit_movements s
        WHERE p_organization_id IS NULL OR s.organization_id = p_organization_id
        GROUP BY s.organization_id, s.customer_id
    )
    SELECT 'stock_on_hand', COALESCE(l.organization_id, m.organization_id), COALESCE(l.product_id, m.product_id),
           COALESCE(l.branch_id, m.branch_id), COALESCE(l.stock_state, m.stock_state)::text,
           COALESCE(l.on_hand, 0)::numeric, COALESCE(m.quantity, 0)::numeric
    FROM levels l
    FULL JOIN moved m ON m.organization_id = l.organization_id AND m.product_id = l.product_id
                     AND m.branch_id = l.branch_id AND m.stock_state = l.stock_state
    WHERE COALESCE(l.on_hand, 0) <> COALESCE(m.quantity, 0)

    UNION ALL
    SELECT 'stock_reserved', COALESCE(l.organization_id, r.organization_id), COALESCE(l.product_id, r.product_id),
           COALESCE(l.branch_id, r.branch_id), 'sellable',
           COALESCE(l.reserved, 0)::numeric, COALESCE(r.quantity, 0)::numeric
    FROM (SELECT * FROM levels WHERE stock_state = 'sellable') l
    FULL JOIN reserved r ON r.organization_id = l.organization_id AND r.product_id = l.product_id
                        AND r.branch_id = l.branch_id
    WHERE COALESCE(l.reserved, 0) <> COALESCE(r.quantity, 0)

    UNION ALL
    SELECT 'cash', COALESCE(b.organization_id, c.organization_id), COALESCE(b.cash_account_id, c.cash_account_id),
           NULL::uuid, NULL::text, COALESCE(b.balance, 0), COALESCE(c.amount, 0)
    FROM balances b
    FULL JOIN cash c ON c.cash_account_id = b.cash_account_id
    WHERE COALESCE(b.balance, 0) <> COALESCE(c.amount, 0)

    UNION ALL
    SELECT 'store_credit', COALESCE(s.organization_id, c.organization_id), COALESCE(s.customer_id, c.customer_id),
           NULL::uuid, NULL::text, COALESCE(s.balance, 0), COALESCE(c.amount, 0)
    FROM credit_balances s
    FULL JOIN credit c ON c.customer_id = s.customer_id
    WHERE COALESCE(s.balance, 0) <> COALESCE(c.amount, 0)
$$;

REVOKE ALL ON FUNCTION app.ledger_mismatches(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.ledger_mismatches(uuid) TO service_role;

-- F10. Idempotency for write functions (D33). Every money or stock write function calls this
-- FIRST, before it looks for an existing document or takes a document number:
--     PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
--     SELECT id INTO v_id FROM public.<documents> WHERE organization_id = v_org AND idempotency_key = p_idempotency_key;
--     IF FOUND THEN RETURN v_id; END IF;   -- a repeat changes nothing
--     ... app.next_document_number(...), insert the document, post the ledger rows ...
-- Concurrent requests with the same key queue on this lock until the first one commits, so the
-- second finds that document and returns it: nothing is posted twice and no number is taken
-- for nothing. The table's UNIQUE (organization_id, idempotency_key) stays as the last line of defence.
CREATE FUNCTION app.lock_idempotency_key(p_organization_id uuid, p_key text)
RETURNS void LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    IF p_key IS NULL OR length(p_key) NOT BETWEEN 8 AND 128 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: the idempotency key must be 8 to 128 characters' USING ERRCODE = 'P0001';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('idempotency/' || p_organization_id::text || '/' || p_key, 0));
END;
$$;

REVOKE ALL ON FUNCTION app.lock_idempotency_key(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.lock_idempotency_key(uuid, text) TO service_role;
