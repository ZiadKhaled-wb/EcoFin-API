-- =============================================================================
-- S05 returns and exchanges (EC-72, D88; spec docs/tasks/S05.md)
--
-- A customer brings goods back against the original sale. One document per return, one transaction:
-- the sales_returns row (RT number), its lines, the stock coming back, the money going back, the
-- contract change of an installment sale, the ETA return receipt and the audit row, or nothing.
--
-- Rules:
--   1. In the caller's open shift (its device), the sale's own branch only (RETURN_OTHER_BRANCH).
--      refund.create + the pos module; a contract sale also the installments module.
--   2. Per sale line: returnable = sold - every earlier return. A serialized line comes back with
--      its own unit (RETURN_UNIT_MISMATCH). Over-return: RETURN_QTY_EXCEEDED.
--   3. Period: sale date + return_policy_days. Later: the OWNER only (warning audit), or an open
--      warranty claim on the returned unit (S12; the claim closes).
--   4. Amounts from the stored sale line, cumulative so the last unit takes the rest:
--      refund = round(line_total * (prev + q) / Q) - round(line_total * prev / Q); the same for tax
--      (and, for the ETA, the discount). The client confirms the total (expected_total, PRICE_CHANGED).
--   5. Stock back once: sale_return_in at the line's cost, sellable or damaged. A damaged unit ends
--      'returned' (not sellable), which app.apply_stock_movement now says.
--   6. Money on a cash sale: the sale's own methods up to what each paid less what earlier returns
--      gave back by it (REFUND_EXCEEDS_PAID), or store credit for any part (a customer is needed).
--      Cash leaves the caller's drawer; a bank transfer leaves a bank the sale was paid into.
--   7. Installment sale (ISLAMIC_FINANCE_RULES 1, 5, 9): credit = the returned goods' cash price +
--      their share of the profit (cumulative: round(M * (prior + t) / T) - round(M * prior / T)).
--      It lowers what is still owed first: a new schedule version over the same remaining
--      installments and dates, each smaller (one contract_changes row 'return_adjustment', checked
--      by app.schedule_lines_sum_check). Nothing left: the lines are superseded, status 'returned'
--      when every unit came back, 'completed' otherwise; the overpaid part goes back by refund lines.
--   8. Exchange = this return + a new sale (app.post_sale_core) in the same transaction. The credit
--      pays the new sale first through the drawer (one 'sale' and one 'refund' movement for the
--      credit used, net 0); the difference is paid by the new sale's payment lines or given back by
--      refund lines. Not for contract sales (EXCHANGE_NOT_FOR_CONTRACT).
--   9. ETA: a b2c_return fiscal row on the return's POS when the sale has a fiscal row; it is built
--      once the sale's receipt has its UUID (eta_load_pending_for_device skips it until then).
--      A sale receipt older than 540 days: RETURN_ETA_WINDOW_PASSED.
--  10. R02 (D74 TODO(S05/N05)): the open balance no longer subtracts contract_adjustment returns (the
--      new version carries them); the statement shows the return's whole credit and the contract
--      row adds the return reductions back, so history does not move.
--
-- Numbers: contracts 0.58.0, 6 routes (293). No new table, column, enum value or permission key.
-- =============================================================================

-- 1. A damaged unit coming back is 'returned', not 'in_stock' -------------------------------------------

CREATE OR REPLACE FUNCTION app.apply_stock_movement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    INSERT INTO public.stock_levels (organization_id, product_id, branch_id, stock_state)
    VALUES (NEW.organization_id, NEW.product_id, NEW.branch_id, NEW.stock_state)
    ON CONFLICT (organization_id, product_id, branch_id, stock_state) DO NOTHING;

    UPDATE public.stock_levels sl
       SET on_hand = sl.on_hand + NEW.quantity, updated_at = now()
     WHERE sl.organization_id = NEW.organization_id AND sl.product_id = NEW.product_id
       AND sl.branch_id = NEW.branch_id AND sl.stock_state = NEW.stock_state
       AND sl.on_hand + NEW.quantity >= sl.reserved;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUT_OF_STOCK: product % at branch % (% stock; reserved stock counts as taken)',
            NEW.product_id, NEW.branch_id, NEW.stock_state USING ERRCODE = '23514';
    END IF;

    IF NEW.unit_id IS NOT NULL THEN
        UPDATE public.units u
           SET branch_id = NEW.branch_id,
               status = CASE
                   -- S05: a damaged return is kept apart and is not sellable.
                   WHEN NEW.quantity > 0 AND NEW.stock_state = 'damaged' THEN 'returned'
                   WHEN NEW.quantity > 0 THEN 'in_stock'
                   WHEN NEW.type IN ('sale_out', 'delivery_out') THEN 'sold'
                   WHEN NEW.type = 'transfer_out' THEN 'in_transit'
                   WHEN NEW.type = 'purchase_return_out' THEN 'returned'
                   WHEN NEW.type = 'claim_out' THEN 'in_repair'
                   ELSE 'written_off'
               END::public.unit_status,
               updated_at = now()
         WHERE u.id = NEW.unit_id;
    END IF;
    RETURN NULL;
END;
$$;

-- 2. Helpers (schema app, no grants) ------------------------------------------------------------------

-- Who may read a return: whoever reads its sale (S01/S07), or refund.create in the sale's branch.
CREATE FUNCTION app.can_read_return(p_branch_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT app.has_branch_access(p_branch_id)
       AND (app.has_permission('sale.create') OR app.has_permission('report.view')
            OR app.has_permission('cash.view') OR app.has_permission('refund.create'))
$$;

-- Read guard shared by the read functions: one of the keys, and an expired shop still reads (P05).
CREATE FUNCTION app.return_read_guard()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_key text;
BEGIN
    SELECT k INTO v_key FROM unnest(ARRAY['refund.create', 'sale.create', 'report.view', 'cash.view']) k
    WHERE app.has_permission(k) LIMIT 1;
    IF v_key IS NULL THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: refund.create, sale.create, report.view or cash.view'
            USING ERRCODE = '42501';
    END IF;
    BEGIN
        PERFORM app.require_permission(v_key);
    EXCEPTION WHEN insufficient_privilege THEN
        IF SQLERRM <> 'SUBSCRIPTION_EXPIRED' THEN RAISE; END IF;
    END;
END;
$$;

-- What the sale was paid with, less what earlier returns gave back by each method (rule 6). The
-- drawer pair of an exchange (keys system:exchange:...) is not money leaving the shop: left out.
CREATE FUNCTION app.sale_refundable(p_org uuid, p_sale_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    WITH paid AS (
        SELECT p.method, sum(a.amount) AS amount
        FROM public.payment_allocations a
        JOIN public.payments p ON p.id = a.payment_id AND p.organization_id = a.organization_id
        WHERE a.organization_id = p_org AND a.sale_id = p_sale_id AND p.direction = 'in'
          AND p.idempotency_key NOT LIKE 'system:exchange:%'
        GROUP BY p.method
    ), back AS (
        SELECT p.method, sum(a.amount) AS amount
        FROM public.sales_returns r
        JOIN public.payment_allocations a ON a.organization_id = r.organization_id AND a.return_id = r.id
        JOIN public.payments p ON p.id = a.payment_id AND p.organization_id = a.organization_id
        WHERE r.organization_id = p_org AND r.sale_id = p_sale_id AND p.direction = 'out'
          AND p.idempotency_key NOT LIKE 'system:exchange:%'
        GROUP BY p.method
    )
    SELECT jsonb_build_object(
        'cash', GREATEST(COALESCE((SELECT amount FROM paid WHERE method = 'cash'), 0)
                       - COALESCE((SELECT amount FROM back WHERE method = 'cash'), 0), 0)::numeric(18,2)::text,
        'bank_transfer', GREATEST(COALESCE((SELECT amount FROM paid WHERE method = 'bank_transfer'), 0)
                       - COALESCE((SELECT amount FROM back WHERE method = 'bank_transfer'), 0), 0)::numeric(18,2)::text,
        'store_credit', GREATEST(COALESCE((SELECT amount FROM paid WHERE method = 'store_credit'), 0)
                       - COALESCE((SELECT amount FROM back WHERE method = 'store_credit'), 0), 0)::numeric(18,2)::text)
$$;

-- The returned goods' share of a contract's profit for a return of p_total on top of p_prior
-- (rule 7). Cumulative, so every return of the whole sale adds up to the profit exactly.
CREATE FUNCTION app.return_profit_share(p_markup numeric, p_sale_total numeric, p_prior numeric, p_total numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT (round(p_markup * (p_prior + p_total) / p_sale_total, 2) - round(p_markup * p_prior / p_sale_total, 2))::numeric(18,2)
$$;

-- The profit share of a stored return (its sale's earlier returns counted first).
CREATE FUNCTION app.stored_return_profit_share(p_org uuid, p_return_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(app.return_profit_share(c.markup_amount, s.total,
               COALESCE((SELECT sum(x.total) FROM public.sales_returns x
                         WHERE x.organization_id = r.organization_id AND x.sale_id = r.sale_id
                           AND (x.created_at, x.id) < (r.created_at, r.id)), 0),
               r.total), 0)
    FROM public.sales_returns r
    JOIN public.sales s ON s.id = r.sale_id AND s.organization_id = r.organization_id
    LEFT JOIN public.contracts c ON c.sale_id = s.id AND c.organization_id = s.organization_id
    WHERE r.organization_id = p_org AND r.id = p_return_id AND c.id IS NOT NULL
$$;

-- What the returns took off a contract (R02's statement): per return change, what was left on the
-- old version minus what the new version carries (0 when nothing is left).
CREATE FUNCTION app.contract_return_reduction(p_org uuid, p_contract_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(sum(
               (SELECT COALESCE(sum(ls.amount - ls.paid), 0) FROM public.v_schedule_line_status ls
                WHERE ls.organization_id = x.organization_id AND ls.contract_id = x.contract_id
                  AND ls.version = x.old_version) - x.amount), 0)::numeric(18,2)
    FROM public.contract_changes x
    WHERE x.organization_id = p_org AND x.contract_id = p_contract_id AND x.kind = 'return_adjustment'
$$;

-- The contract side of a return (rule 7): the credit, what it takes off, the new lines, what is
-- overpaid. p_all_back: after this return every unit of the sale has come back.
CREATE FUNCTION app.return_contract_plan(p_org uuid, c public.contracts, s public.sales, p_total numeric,
                                         p_all_back boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_prior numeric; v_share numeric; v_credit numeric; v_left record; v_remaining numeric;
    v_new numeric; v_new_profit numeric; v_new_principal numeric; v_dates date[]; v_n integer;
    v_step numeric; v_lines jsonb; v_status public.contract_status;
BEGIN
    SELECT COALESCE(sum(r.total), 0) INTO v_prior FROM public.sales_returns r
    WHERE r.organization_id = p_org AND r.sale_id = s.id;
    v_share := app.return_profit_share(c.markup_amount, s.total, v_prior, p_total);
    v_credit := p_total + v_share;
    SELECT * INTO v_left FROM app.contract_left(p_org, c.id);
    v_remaining := CASE WHEN c.status IN ('active', 'rescheduled')
                        THEN v_left.principal_left + v_left.profit_left ELSE 0 END;
    v_new := GREATEST(v_remaining - v_credit, 0);
    v_new_profit := LEAST(GREATEST(CASE WHEN c.status IN ('active', 'rescheduled') THEN v_left.profit_left ELSE 0 END
                                   - v_share, 0), v_new);
    v_new_principal := v_new - v_new_profit;

    IF v_new > 0 THEN
        SELECT array_agg(ls.due_date ORDER BY ls.seq) INTO v_dates
        FROM public.v_schedule_line_status ls
        WHERE ls.organization_id = p_org AND ls.contract_id = c.id AND ls.version = c.current_version
          AND NOT ls.superseded AND ls.remaining > 0;
        SELECT p.rounding_step INTO v_step FROM public.installment_policies p
        WHERE p.id = c.policy_id AND p.organization_id = p_org;
        v_n := COALESCE(array_length(v_dates, 1), 1);
        -- The same installments, each smaller; when rounding leaves the last one empty, fewer.
        LOOP
            v_lines := app.schedule_split(v_new_principal, v_new_profit, v_n, c.frequency,
                                          app.org_today(p_org), COALESCE(v_step, 0.01));
            EXIT WHEN v_lines IS NOT NULL OR v_n = 1;
            v_n := v_n - 1;
        END LOOP;
        IF v_lines IS NULL THEN
            v_lines := app.schedule_split(v_new_principal, v_new_profit, 1, c.frequency, app.org_today(p_org), 0.01);
        END IF;
        SELECT jsonb_agg(x || jsonb_build_object('due_date',
                   COALESCE(v_dates[(x ->> 'seq')::integer], (x ->> 'due_date')::date)::text) ORDER BY (x ->> 'seq')::integer)
        INTO v_lines FROM jsonb_array_elements(v_lines) x;
        v_status := c.status;
    ELSE
        v_lines := '[]'::jsonb;
        v_status := CASE WHEN p_all_back THEN 'returned' ELSE 'completed' END;
    END IF;

    RETURN jsonb_build_object(
        'contract_id', c.id, 'number', c.number, 'status_before', c.status, 'status_after', v_status,
        'version_before', c.current_version,
        'remaining_before', v_remaining::numeric(18,2)::text,
        'profit_share', v_share::numeric(18,2)::text,
        'credit', v_credit::numeric(18,2)::text,
        'applied', (v_remaining - v_new)::numeric(18,2)::text,
        'remaining_after', v_new::numeric(18,2)::text,
        'principal_after', v_new_principal::numeric(18,2)::text,
        'profit_after', v_new_profit::numeric(18,2)::text,
        'overpaid', (v_credit - (v_remaining - v_new))::numeric(18,2)::text,
        'installments_left', jsonb_array_length(v_lines),
        'installment_amount', v_lines -> 0 ->> 'amount',
        'lines', v_lines);
END;
$$;

-- The refund lines, checked (rule 6; a contract sale: any method for the overpaid part).
-- [{method, amount, cash_account_id?, reference?}] -> the same list, normalised.
CREATE FUNCTION app.return_refund_lines(p_org uuid, s public.sales, p_shift public.shifts, p_refunds jsonb,
                                        p_due numeric, p_contract boolean, p_check_sum boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    e jsonb; v_out jsonb := '[]'; v_method text; v_amount numeric; v_account uuid; v_ref text;
    v_sum numeric := 0; v_avail jsonb; v_acc public.cash_accounts; v_by jsonb := '{}';
BEGIN
    IF p_refunds IS NULL OR p_refunds = 'null'::jsonb THEN
        p_refunds := '[]'::jsonb;
    END IF;
    IF jsonb_typeof(p_refunds) <> 'array' OR jsonb_array_length(p_refunds) > 5 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: refunds' USING ERRCODE = 'P0001';
    END IF;
    v_avail := app.sale_refundable(p_org, s.id);
    FOR e IN SELECT * FROM jsonb_array_elements(p_refunds) LOOP
        IF jsonb_typeof(e) <> 'object'
           OR EXISTS (SELECT 1 FROM jsonb_object_keys(e) k WHERE k NOT IN ('method', 'amount', 'cash_account_id', 'reference'))
           OR e ->> 'method' NOT IN ('cash', 'bank_transfer', 'store_credit')
           OR jsonb_typeof(e -> 'amount') IS DISTINCT FROM 'string'
           OR (e ->> 'amount') !~ '^\d{1,16}(\.\d{1,2})?$' OR (e ->> 'amount')::numeric <= 0 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: refunds' USING ERRCODE = 'P0001';
        END IF;
        v_method := e ->> 'method';
        v_amount := (e ->> 'amount')::numeric;
        v_account := NULL;
        v_ref := NULL;
        IF v_method = 'bank_transfer' THEN
            v_ref := btrim(e ->> 'reference');
            IF v_ref IS NULL OR length(v_ref) NOT BETWEEN 1 AND 100 OR e ->> 'cash_account_id' IS NULL
               OR (e ->> 'cash_account_id') !~ '^[0-9a-fA-F-]{36}$' THEN
                RAISE EXCEPTION 'VALIDATION_FAILED: a bank refund needs its bank and a reference' USING ERRCODE = 'P0001';
            END IF;
            v_account := (e ->> 'cash_account_id')::uuid;
            SELECT * INTO v_acc FROM public.cash_accounts a WHERE a.id = v_account AND a.organization_id = p_org;
            IF NOT FOUND OR v_acc.kind <> 'bank'
               OR (v_acc.branch_id IS NOT NULL AND v_acc.branch_id <> s.branch_id)
               OR (NOT p_contract AND NOT EXISTS (
                       SELECT 1 FROM public.payment_allocations a
                       JOIN public.payments p ON p.id = a.payment_id AND p.organization_id = a.organization_id
                       WHERE a.organization_id = p_org AND a.sale_id = s.id AND p.direction = 'in'
                         AND p.cash_account_id = v_account)) THEN
                RAISE EXCEPTION 'VAULT_INVALID: refund bank' USING ERRCODE = 'P0001';
            END IF;
            IF NOT v_acc.is_active OR v_acc.archived_at IS NOT NULL THEN
                RAISE EXCEPTION 'CASH_ACCOUNT_INACTIVE' USING ERRCODE = 'P0001';
            END IF;
        ELSIF e ? 'cash_account_id' OR e ? 'reference' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: refunds' USING ERRCODE = 'P0001';
        ELSIF v_method = 'cash' THEN
            v_account := p_shift.drawer_account_id;
        ELSIF s.customer_id IS NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: store credit needs the sale''s customer' USING ERRCODE = 'P0001';
        END IF;
        IF v_method <> 'bank_transfer' AND (v_by ? v_method) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: one refund line per method (banks excepted)' USING ERRCODE = 'P0001';
        END IF;
        v_by := v_by || jsonb_build_object(v_method, COALESCE((v_by ->> v_method)::numeric, 0) + v_amount);
        v_sum := v_sum + v_amount;
        v_out := v_out || jsonb_build_object('method', v_method, 'amount', v_amount::numeric(18,2)::text,
                                             'cash_account_id', v_account, 'reference', v_ref);
    END LOOP;
    -- Rule 6: the sale's own methods up to what each paid; store credit for any part.
    IF NOT p_contract THEN
        SELECT m INTO v_method FROM unnest(ARRAY['cash', 'bank_transfer']) m
        WHERE COALESCE((v_by ->> m)::numeric, 0) > (v_avail ->> m)::numeric LIMIT 1;
        IF v_method IS NOT NULL THEN
            RAISE EXCEPTION 'REFUND_EXCEEDS_PAID: % refunds more than the sale took', v_method USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('method', v_method, 'available', v_avail ->> v_method)::text;
        END IF;
    END IF;
    IF p_check_sum AND v_sum <> p_due THEN
        RAISE EXCEPTION 'PAYMENT_TOTAL_MISMATCH: the refunds add up to %, the return gives back %', v_sum, p_due
            USING ERRCODE = 'P0001',
                  DETAIL = jsonb_build_object('total', p_due::numeric(18,2)::text, 'paid', v_sum::numeric(18,2)::text)::text;
    END IF;
    RETURN v_out;
END;
$$;

-- The whole return worked out (rules 1-8), for the quote (p_write false) and the post (p_write
-- true, after the caller locked the rows). Raises the business errors; writes nothing.
CREATE FUNCTION app.return_compute(p_org uuid, p_shift public.shifts, p_body jsonb, p_write boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    s public.sales; c public.contracts; sl public.sale_lines; e jsonb; v_kind text; v_reason text;
    v_today date := app.org_today(p_org); v_days integer; v_deadline date; v_override boolean := false;
    v_claim public.warranty_claims; v_claim_id uuid; v_lines jsonb := '[]'; v_seen uuid[] := '{}';
    v_qty integer; v_prev_qty integer; v_prev_amount numeric; v_prev_tax numeric; v_amount numeric; v_tax numeric;
    v_condition text; v_unit uuid; v_total numeric := 0; v_tax_total numeric := 0; v_expected numeric;
    v_contract jsonb; v_all_back boolean; v_due numeric; v_refunds jsonb; v_new jsonb; v_cart jsonb;
    v_new_total numeric; v_credit_used numeric := 0; v_pay_due numeric; v_eta_issued timestamptz;
BEGIN
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_body) k
                  WHERE k NOT IN ('sale_id', 'kind', 'lines', 'refunds', 'reason', 'expected_total',
                                  'warranty_claim_id', 'new_sale'))
       OR (p_body ->> 'sale_id') !~ '^[0-9a-fA-F-]{36}$'
       OR COALESCE(p_body ->> 'kind', 'return') NOT IN ('return', 'exchange')
       OR jsonb_typeof(p_body -> 'lines') IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_body -> 'lines') NOT BETWEEN 1 AND 200 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    v_kind := COALESCE(p_body ->> 'kind', 'return');
    IF (v_kind = 'exchange') <> (jsonb_typeof(p_body -> 'new_sale') = 'object') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: new_sale is for an exchange' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO s FROM public.sales x WHERE x.id = (p_body ->> 'sale_id')::uuid AND x.organization_id = p_org;
    IF NOT FOUND OR NOT app.has_branch_access(s.branch_id) THEN
        RAISE EXCEPTION 'SALE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF s.branch_id <> p_shift.branch_id THEN
        RAISE EXCEPTION 'RETURN_OTHER_BRANCH: the sale belongs to another branch' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('branch_id', s.branch_id)::text;
    END IF;
    IF EXISTS (SELECT 1 FROM public.sales_returns r WHERE r.organization_id = p_org AND r.sale_id = s.id AND r.kind = 'void') THEN
        RAISE EXCEPTION 'ALREADY_VOIDED' USING ERRCODE = 'P0001';
    END IF;

    v_reason := NULLIF(btrim(p_body ->> 'reason'), '');
    IF p_write AND (v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 200) THEN
        RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO c FROM public.contracts k WHERE k.organization_id = p_org AND k.sale_id = s.id;
    IF FOUND THEN
        IF v_kind = 'exchange' THEN
            RAISE EXCEPTION 'EXCHANGE_NOT_FOR_CONTRACT: return it, then sell again' USING ERRCODE = 'P0001';
        END IF;
        IF NOT app.org_has_module(p_org, 'installments') THEN
            RAISE EXCEPTION 'MODULE_NOT_IN_PLAN: installments' USING ERRCODE = 'P0001';
        END IF;
        IF c.status NOT IN ('active', 'rescheduled', 'completed') THEN
            RAISE EXCEPTION 'CONTRACT_NOT_OPEN: %', c.number USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('contract_id', c.id, 'status', c.status)::text;
        END IF;
    END IF;

    -- A warranty claim (S12) on a returned unit lifts the period.
    IF p_body ? 'warranty_claim_id' AND p_body -> 'warranty_claim_id' <> 'null'::jsonb THEN
        IF (p_body ->> 'warranty_claim_id') !~ '^[0-9a-fA-F-]{36}$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: warranty_claim_id' USING ERRCODE = 'P0001';
        END IF;
        v_claim_id := (p_body ->> 'warranty_claim_id')::uuid;
        SELECT * INTO v_claim FROM public.warranty_claims w WHERE w.id = v_claim_id AND w.organization_id = p_org;
        IF NOT FOUND OR v_claim.status NOT IN ('open', 'in_repair', 'repaired')
           OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_body -> 'lines') l
                          WHERE l ->> 'sale_line_id' = v_claim.sale_line_id::text) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: the claim is not open on a returned line' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    SELECT st.return_policy_days INTO v_days FROM public.org_settings st WHERE st.organization_id = p_org;
    v_deadline := s.business_date + COALESCE(v_days, 14);
    IF v_today > v_deadline AND v_claim_id IS NULL THEN
        IF app.current_role() IS DISTINCT FROM 'OWNER' THEN
            RAISE EXCEPTION 'RETURN_PERIOD_EXPIRED: the period ended on %', v_deadline USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('deadline', v_deadline::text)::text;
        END IF;
        v_override := true;
    END IF;

    -- The lines (rules 2 and 4).
    FOR e IN SELECT * FROM jsonb_array_elements(p_body -> 'lines') LOOP
        IF jsonb_typeof(e) <> 'object'
           OR EXISTS (SELECT 1 FROM jsonb_object_keys(e) k WHERE k NOT IN ('sale_line_id', 'unit_id', 'quantity', 'condition'))
           OR (e ->> 'sale_line_id') !~ '^[0-9a-fA-F-]{36}$'
           OR jsonb_typeof(e -> 'quantity') IS DISTINCT FROM 'number' OR (e ->> 'quantity') !~ '^\d{1,6}$'
           OR (e ->> 'quantity')::integer < 1
           OR COALESCE(e ->> 'condition', 'resellable') NOT IN ('resellable', 'damaged')
           OR (e ? 'unit_id' AND e -> 'unit_id' <> 'null'::jsonb AND (e ->> 'unit_id') !~ '^[0-9a-fA-F-]{36}$') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
        END IF;
        SELECT * INTO sl FROM public.sale_lines x
        WHERE x.id = (e ->> 'sale_line_id')::uuid AND x.organization_id = p_org AND x.sale_id = s.id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: the line is not on this sale' USING ERRCODE = 'P0001';
        END IF;
        IF sl.id = ANY (v_seen) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: a line appears twice' USING ERRCODE = 'P0001';
        END IF;
        v_seen := v_seen || sl.id;
        v_qty := (e ->> 'quantity')::integer;
        v_unit := NULLIF(e ->> 'unit_id', '')::uuid;
        IF sl.unit_id IS NOT NULL AND (v_unit IS NULL OR v_unit <> sl.unit_id) THEN
            RAISE EXCEPTION 'RETURN_UNIT_MISMATCH: this unit was not sold on the line' USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('sale_line_id', sl.id)::text;
        END IF;
        IF sl.unit_id IS NULL AND v_unit IS NOT NULL THEN
            RAISE EXCEPTION 'RETURN_UNIT_MISMATCH: the line has no unit' USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('sale_line_id', sl.id)::text;
        END IF;
        SELECT COALESCE(sum(rl.quantity), 0)::integer, COALESCE(sum(rl.refund_amount), 0), COALESCE(sum(rl.tax_amount), 0)
        INTO v_prev_qty, v_prev_amount, v_prev_tax
        FROM public.sales_return_lines rl WHERE rl.organization_id = p_org AND rl.sale_line_id = sl.id;
        IF v_qty > sl.quantity - v_prev_qty THEN
            RAISE EXCEPTION 'RETURN_QTY_EXCEEDED: % can take % more', sl.id, sl.quantity - v_prev_qty
                USING ERRCODE = 'P0001',
                      DETAIL = jsonb_build_object('sale_line_id', sl.id, 'returnable', sl.quantity - v_prev_qty)::text;
        END IF;
        v_amount := round(sl.line_total * (v_prev_qty + v_qty) / sl.quantity, 2) - v_prev_amount;
        v_tax := round(sl.tax_amount * (v_prev_qty + v_qty) / sl.quantity, 2) - v_prev_tax;
        v_condition := COALESCE(e ->> 'condition', 'resellable');
        v_total := v_total + v_amount;
        v_tax_total := v_tax_total + v_tax;
        v_lines := v_lines || jsonb_build_object(
            'sale_line_id', sl.id, 'line_no', sl.line_no, 'product_id', sl.product_id, 'unit_id', sl.unit_id,
            'quantity', v_qty, 'condition', v_condition,
            'refund_amount', v_amount::numeric(18,2)::text, 'tax_amount', v_tax::numeric(18,2)::text,
            'unit_cost', sl.unit_cost::text,
            'name_ar', (SELECT p.name_ar FROM public.products p WHERE p.id = sl.product_id),
            'name_en', (SELECT p.name_en FROM public.products p WHERE p.id = sl.product_id),
            'sku', (SELECT p.sku FROM public.products p WHERE p.id = sl.product_id),
            'serial', (SELECT u.serial FROM public.units u WHERE u.id = sl.unit_id));
    END LOOP;
    IF v_total <= 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a return must give something back' USING ERRCODE = 'P0001';
    END IF;

    IF p_write OR (p_body ? 'expected_total' AND p_body -> 'expected_total' <> 'null'::jsonb) THEN
        IF jsonb_typeof(p_body -> 'expected_total') IS DISTINCT FROM 'string'
           OR (p_body ->> 'expected_total') !~ '^\d{1,16}(\.\d{1,2})?$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: expected_total' USING ERRCODE = 'P0001';
        END IF;
        v_expected := (p_body ->> 'expected_total')::numeric;
        IF p_write AND v_expected <> v_total THEN
            RAISE EXCEPTION 'PRICE_CHANGED: expected %, the return is %', v_expected, v_total USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('expected_total', v_expected::numeric(18,2)::text,
                                            'total', v_total::numeric(18,2)::text)::text;
        END IF;
    END IF;

    -- Rule 9: the ETA takes a return up to 540 days after the sale receipt.
    SELECT s.issued_at INTO v_eta_issued FROM public.fiscal_submissions f
    WHERE f.organization_id = p_org AND f.sale_id = s.id AND f.status <> 'cancelled';
    IF v_eta_issued IS NOT NULL AND now() > v_eta_issued + interval '540 days' THEN
        RAISE EXCEPTION 'RETURN_ETA_WINDOW_PASSED: the sale receipt is older than 540 days' USING ERRCODE = 'P0001';
    END IF;

    -- What goes back, and how.
    IF c.id IS NOT NULL THEN
        SELECT bool_and(x.quantity = COALESCE(x.back, 0) + COALESCE(x.now, 0)) INTO v_all_back
        FROM (SELECT l.quantity,
                     (SELECT sum(rl.quantity) FROM public.sales_return_lines rl
                      WHERE rl.organization_id = p_org AND rl.sale_line_id = l.id) AS back,
                     (SELECT sum((n ->> 'quantity')::integer) FROM jsonb_array_elements(v_lines) n
                      WHERE (n ->> 'sale_line_id')::uuid = l.id) AS now
              FROM public.sale_lines l WHERE l.organization_id = p_org AND l.sale_id = s.id) x;
        v_contract := app.return_contract_plan(p_org, c, s, v_total, COALESCE(v_all_back, false));
        v_due := (v_contract ->> 'overpaid')::numeric;
    ELSE
        v_due := v_total;
    END IF;

    IF v_kind = 'exchange' THEN
        v_new := p_body -> 'new_sale';
        IF EXISTS (SELECT 1 FROM jsonb_object_keys(v_new) k
                   WHERE k NOT IN ('lines', 'expected_total', 'payments', 'sale_discount', 'discount_reason',
                                   'discount_approval_id')) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: new_sale' USING ERRCODE = 'P0001';
        END IF;
        IF NOT app.has_permission('sale.create') THEN
            RAISE EXCEPTION 'PERMISSION_DENIED: sale.create' USING ERRCODE = '42501';
        END IF;
        PERFORM app.sale_lines_input(v_new -> 'lines');
        v_cart := app.sale_cart(p_org, p_shift.branch_id, v_new -> 'lines', app.has_permission('price.override'),
                                NULLIF(v_new -> 'sale_discount', 'null'::jsonb));
        v_new_total := (v_cart ->> 'total')::numeric;
        v_credit_used := LEAST(v_total, v_new_total);
        v_due := v_total - v_credit_used;
        v_pay_due := v_new_total - v_credit_used;
    END IF;

    v_refunds := app.return_refund_lines(p_org, s, p_shift,
                                         CASE WHEN p_body ? 'refunds' THEN p_body -> 'refunds' END,
                                         v_due, c.id IS NOT NULL, p_write);

    RETURN jsonb_build_object(
        'sale_id', s.id, 'sale_number', s.number, 'branch_id', s.branch_id, 'customer_id', s.customer_id,
        'kind', v_kind, 'reason', v_reason,
        'lines', v_lines,
        'subtotal', (v_total - v_tax_total)::numeric(18,2)::text,
        'tax_total', v_tax_total::numeric(18,2)::text,
        'total', v_total::numeric(18,2)::text,
        'deadline', v_deadline::text, 'period_override', v_override, 'warranty_claim_id', v_claim_id,
        'contract', v_contract,
        'refund_due', v_due::numeric(18,2)::text,
        'refunds', v_refunds,
        'refundable', CASE WHEN c.id IS NULL THEN app.sale_refundable(p_org, s.id) END,
        'exchange', CASE WHEN v_kind = 'exchange' THEN jsonb_build_object(
            'new_total', v_new_total::numeric(18,2)::text, 'credit_used', v_credit_used::numeric(18,2)::text,
            'to_pay', v_pay_due::numeric(18,2)::text,
            'quote', (v_cart - 'discount') - 'prices_include_vat') END);
END;
$$;

-- A return as the API shows it.
CREATE FUNCTION app.return_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', r.id, 'number', r.number, 'kind', r.kind, 'refund_method', r.refund_method,
        'sale', jsonb_build_object('id', s.id, 'number', s.number, 'business_date', s.business_date,
                                   'total', s.total::text),
        'branch', jsonb_build_object('id', b.id, 'name', b.name),
        'customer', CASE WHEN cu.id IS NOT NULL THEN jsonb_build_object('id', cu.id, 'name', cu.full_name) END,
        'shift_id', r.shift_id,
        'subtotal', r.subtotal::text, 'tax_total', r.tax_total::text, 'total', r.total::text,
        'reason', r.reason, 'business_date', r.business_date, 'created_at', r.created_at,
        'created_by', jsonb_build_object('id', e.id, 'name', e.full_name),
        'lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', rl.id, 'sale_line_id', rl.sale_line_id, 'line_no', l.line_no, 'product_id', l.product_id,
                'sku', p.sku, 'name_ar', p.name_ar, 'name_en', p.name_en,
                'unit_id', rl.unit_id, 'serial', u.serial, 'quantity', rl.quantity, 'condition', rl.condition,
                'refund_amount', rl.refund_amount::text, 'tax_amount', rl.tax_amount::text,
                'tax_rate', l.tax_rate::numeric(5,2)::text) ORDER BY l.line_no, rl.id)
            FROM public.sales_return_lines rl
            JOIN public.sale_lines l ON l.id = rl.sale_line_id AND l.organization_id = rl.organization_id
            JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
            LEFT JOIN public.units u ON u.id = rl.unit_id AND u.organization_id = rl.organization_id
            WHERE rl.organization_id = r.organization_id AND rl.return_id = r.id), '[]'::jsonb),
        'refunds', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', p.id, 'number', p.number, 'method', p.method, 'amount', a.amount::text,
                'cash_account_id', p.cash_account_id, 'cash_account_name', ca.name, 'reference', p.reference,
                'exchange', p.idempotency_key LIKE 'system:exchange:%') ORDER BY p.number)
            FROM public.payment_allocations a
            JOIN public.payments p ON p.id = a.payment_id AND p.organization_id = a.organization_id
            LEFT JOIN public.cash_accounts ca ON ca.id = p.cash_account_id AND ca.organization_id = p.organization_id
            WHERE a.organization_id = r.organization_id AND a.return_id = r.id AND p.direction = 'out'), '[]'::jsonb),
        'contract_change', (
            SELECT jsonb_build_object('id', x.id, 'contract_id', x.contract_id, 'contract_number', c.number,
                'old_version', x.old_version, 'new_version', x.new_version,
                'remaining_after', x.amount::text, 'status_after', c.status,
                'credit', (r.total + app.stored_return_profit_share(r.organization_id, r.id))::numeric(18,2)::text,
                'profit_share', app.stored_return_profit_share(r.organization_id, r.id)::numeric(18,2)::text)
            FROM public.contract_changes x
            JOIN public.contracts c ON c.id = x.contract_id AND c.organization_id = x.organization_id
            WHERE x.organization_id = r.organization_id AND x.sales_return_id = r.id),
        'exchange_sale', CASE WHEN r.exchange_sale_id IS NOT NULL THEN (
            SELECT jsonb_build_object('id', n.id, 'number', n.number, 'total', n.total::text)
            FROM public.sales n WHERE n.id = r.exchange_sale_id AND n.organization_id = r.organization_id) END,
        'fiscal', (
            SELECT jsonb_build_object('status', f.status, 'eta_uuid', f.eta_uuid, 'qr_payload', f.qr_payload,
                                      'last_error', f.last_error)
            FROM public.fiscal_submissions f WHERE f.organization_id = r.organization_id AND f.return_id = r.id),
        'receipt_prints', (SELECT count(*) FROM public.audit_log al
                           WHERE al.organization_id = r.organization_id AND al.entity_type = 'sales_return'
                             AND al.entity_id = r.id AND al.action = 'sales_return.receipt_printed'))
    FROM public.sales_returns r
    JOIN public.sales s ON s.id = r.sale_id AND s.organization_id = r.organization_id
    JOIN public.branches b ON b.id = r.branch_id AND b.organization_id = r.organization_id
    LEFT JOIN public.customers cu ON cu.id = s.customer_id AND cu.organization_id = s.organization_id
    LEFT JOIN public.employees e ON e.id = r.created_by AND e.organization_id = r.organization_id
    WHERE r.organization_id = p_org AND r.id = p_id
$$;

-- 3. Reads ----------------------------------------------------------------------------------------------

-- What can still come back from a sale (the return screen's start).
CREATE FUNCTION public.get_sale_returnable(p_sale_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE o uuid := app.current_org_id(); s public.sales; c public.contracts; v_days integer; v_remaining numeric;
        v_voided boolean; v_lines jsonb;
BEGIN
    IF NOT app.has_permission('refund.create') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: refund.create' USING ERRCODE = '42501';
    END IF;
    BEGIN
        PERFORM app.require_permission('refund.create');
    EXCEPTION WHEN insufficient_privilege THEN
        IF SQLERRM <> 'SUBSCRIPTION_EXPIRED' THEN RAISE; END IF;
    END;
    SELECT * INTO s FROM public.sales x WHERE x.id = p_sale_id AND x.organization_id = o;
    IF NOT FOUND OR NOT app.has_branch_access(s.branch_id) THEN
        RAISE EXCEPTION 'SALE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO c FROM public.contracts k WHERE k.organization_id = o AND k.sale_id = s.id;
    SELECT st.return_policy_days INTO v_days FROM public.org_settings st WHERE st.organization_id = o;
    v_voided := EXISTS (SELECT 1 FROM public.sales_returns r WHERE r.organization_id = o AND r.sale_id = s.id AND r.kind = 'void');
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'sale_line_id', l.id, 'line_no', l.line_no, 'product_id', l.product_id, 'sku', p.sku,
               'name_ar', p.name_ar, 'name_en', p.name_en, 'is_serialized', p.is_serialized,
               'unit_id', l.unit_id, 'serial', u.serial,
               'sold', l.quantity, 'returned', COALESCE(b.qty, 0),
               'returnable', CASE WHEN v_voided THEN 0 ELSE l.quantity - COALESCE(b.qty, 0) END,
               'unit_price', l.unit_price::text, 'line_total', l.line_total::text, 'tax_amount', l.tax_amount::text,
               'refunded', COALESCE(b.amount, 0)::numeric(18,2)::text,
               'warranty_claim_id', (SELECT w.id FROM public.warranty_claims w
                                     WHERE w.organization_id = o AND w.sale_line_id = l.id
                                       AND w.status IN ('open', 'in_repair', 'repaired') LIMIT 1))
               ORDER BY l.line_no), '[]'::jsonb)
    INTO v_lines
    FROM public.sale_lines l
    JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
    LEFT JOIN public.units u ON u.id = l.unit_id AND u.organization_id = l.organization_id
    LEFT JOIN LATERAL (SELECT sum(rl.quantity)::integer AS qty, sum(rl.refund_amount) AS amount
                       FROM public.sales_return_lines rl
                       WHERE rl.organization_id = o AND rl.sale_line_id = l.id) b ON true
    WHERE l.organization_id = o AND l.sale_id = s.id;
    IF c.id IS NOT NULL THEN
        SELECT x.principal_left + x.profit_left INTO v_remaining FROM app.contract_left(o, c.id) x;
    END IF;
    RETURN jsonb_build_object(
        'sale', jsonb_build_object('id', s.id, 'number', s.number, 'business_date', s.business_date,
                                   'branch_id', s.branch_id, 'total', s.total::text, 'customer_id', s.customer_id,
                                   'customer_name', (SELECT cu.full_name FROM public.customers cu
                                                     WHERE cu.id = s.customer_id AND cu.organization_id = o)),
        'lines', v_lines,
        'paid_by_method', app.sale_refundable(o, s.id),
        'deadline', (s.business_date + COALESCE(v_days, 14))::text,
        'period_passed', app.org_today(o) > s.business_date + COALESCE(v_days, 14),
        'can_pass_period', app.current_role() IS NOT DISTINCT FROM 'OWNER',
        'contract', CASE WHEN c.id IS NOT NULL THEN jsonb_build_object(
            'id', c.id, 'number', c.number, 'status', c.status,
            'remaining', v_remaining::numeric(18,2)::text,
            'installments_left', (SELECT count(*) FROM public.v_schedule_line_status ls
                                  WHERE ls.organization_id = o AND ls.contract_id = c.id
                                    AND ls.version = c.current_version AND NOT ls.superseded AND ls.remaining > 0)) END,
        'blocked', CASE
            WHEN v_voided THEN 'voided'
            WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_lines) x WHERE (x ->> 'returnable')::integer > 0)
                THEN 'fully_returned'
            WHEN c.id IS NOT NULL AND c.status NOT IN ('active', 'rescheduled', 'completed') THEN 'contract_closed' END);
END;
$$;

-- The quote: everything checked and computed, nothing locked or written (rules 1-8).
CREATE FUNCTION public.quote_sales_return(p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid := app.current_employee_id(); o uuid := app.current_org_id(); v_shift public.shifts;
BEGIN
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('refund.create') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: refund.create' USING ERRCODE = '42501';
    END IF;
    PERFORM app.require_module('pos');
    v_shift := app.require_open_shift(o, v_emp);
    RETURN app.return_compute(o, v_shift, p_body, false);
END;
$$;

-- 4. The write -----------------------------------------------------------------------------------------

CREATE FUNCTION public.post_sales_return(p_body jsonb, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; o uuid; v_shift public.shifts; s public.sales; c public.contracts; v_plan jsonb;
    v_return public.sales_returns; v_line jsonb; v_line_id uuid; v_state public.stock_state;
    v_refund jsonb; v_payment uuid; v_n integer := 0; v_method public.refund_method; v_today date;
    v_contract jsonb; v_version integer; v_new_sale uuid; v_used numeric; v_new jsonb; v_drawer_in uuid;
    v_env public.eta_environment; v_sale_fiscal public.fiscal_submissions; v_existing public.sales_returns;
BEGIN
    v_emp := app.require_permission('refund.create');
    o := app.current_org_id();
    PERFORM app.require_module('pos');
    PERFORM app.lock_idempotency_key(o, p_idempotency_key);
    IF p_idempotency_key LIKE 'system:%' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: idempotency key' USING ERRCODE = 'P0001';
    END IF;
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' OR (p_body ->> 'sale_id') !~ '^[0-9a-fA-F-]{36}$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_existing FROM public.sales_returns r WHERE r.organization_id = o AND r.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        IF v_existing.sale_id <> (p_body ->> 'sale_id')::uuid OR v_existing.kind = 'void' THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = 'P0001';
        END IF;
        RETURN app.return_json(o, v_existing.id) || jsonb_build_object('replayed', true);
    END IF;
    IF EXISTS (SELECT 1 FROM public.sales x WHERE x.organization_id = o AND x.idempotency_key = p_idempotency_key)
       OR EXISTS (SELECT 1 FROM public.payments x WHERE x.organization_id = o AND x.idempotency_key = p_idempotency_key)
       OR EXISTS (SELECT 1 FROM public.contract_changes x WHERE x.organization_id = o AND x.idempotency_key = p_idempotency_key) THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = 'P0001';
    END IF;

    -- The caller's open shift, locked, on its own POS.
    v_shift := app.require_open_shift(o, v_emp);
    SELECT * INTO v_shift FROM public.shifts x WHERE x.id = v_shift.id FOR UPDATE;
    IF v_shift.status <> 'open' THEN
        RAISE EXCEPTION 'SHIFT_CLOSED: the shift is closed' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_shift.branch_id);
    PERFORM app.require_shift_device(v_shift.id);

    -- Locks in one order: the sale, its lines, its stock rows and levels, units, contract, fiscal row.
    SELECT * INTO s FROM public.sales x WHERE x.id = (p_body ->> 'sale_id')::uuid AND x.organization_id = o FOR UPDATE;
    IF NOT FOUND OR NOT app.has_branch_access(s.branch_id) THEN
        RAISE EXCEPTION 'SALE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM 1 FROM public.sale_lines l WHERE l.organization_id = o AND l.sale_id = s.id ORDER BY l.product_id, l.id FOR UPDATE;
    PERFORM 1 FROM public.stock_levels sl WHERE sl.organization_id = o AND sl.branch_id = s.branch_id
        AND sl.product_id IN (SELECT l.product_id FROM public.sale_lines l WHERE l.organization_id = o AND l.sale_id = s.id)
        ORDER BY sl.product_id, sl.stock_state FOR UPDATE;
    PERFORM 1 FROM public.units u WHERE u.organization_id = o
        AND u.id IN (SELECT l.unit_id FROM public.sale_lines l WHERE l.organization_id = o AND l.sale_id = s.id AND l.unit_id IS NOT NULL)
        ORDER BY u.id FOR UPDATE;
    SELECT * INTO c FROM public.contracts k WHERE k.organization_id = o AND k.sale_id = s.id FOR UPDATE;
    IF FOUND THEN
        PERFORM app.require_module('installments');
    END IF;
    SELECT * INTO v_sale_fiscal FROM public.fiscal_submissions f WHERE f.organization_id = o AND f.sale_id = s.id FOR UPDATE;

    -- A new statement after the locks: everything checked on what is committed now.
    v_plan := app.return_compute(o, v_shift, p_body, true);
    v_today := app.org_today(o);
    v_contract := NULLIF(v_plan -> 'contract', 'null'::jsonb);

    -- Exchange: the new sale first (its own checks, number and ledgers), paid for the difference.
    IF v_plan ->> 'kind' = 'exchange' THEN
        v_new := p_body -> 'new_sale';
        IF jsonb_typeof(v_new -> 'expected_total') IS DISTINCT FROM 'string'
           OR (v_new ->> 'expected_total') !~ '^\d{1,16}(\.\d{1,2})?$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: new_sale.expected_total' USING ERRCODE = 'P0001';
        END IF;
        PERFORM app.require_permission('sale.create');
        v_used := (v_plan -> 'exchange' ->> 'credit_used')::numeric;
        v_new_sale := app.post_sale_core(o, v_emp, v_shift, v_new -> 'lines', s.customer_id,
                          (v_new ->> 'expected_total')::numeric, 'system:exchange:' || md5(o::text || p_idempotency_key),
                          NULLIF(NULLIF(v_new -> 'payments', 'null'::jsonb), '[]'::jsonb),
                          NULLIF(v_new -> 'sale_discount', 'null'::jsonb), v_new ->> 'discount_reason',
                          NULLIF(v_new ->> 'discount_approval_id', '')::uuid,
                          (v_plan -> 'exchange' ->> 'to_pay')::numeric);
    END IF;

    v_method := CASE
        WHEN jsonb_array_length(v_plan -> 'refunds') = 0 AND v_contract IS NOT NULL THEN 'contract_adjustment'
        WHEN jsonb_array_length(v_plan -> 'refunds') = 0 THEN 'cash'
        ELSE (SELECT (r ->> 'method')::public.refund_method FROM jsonb_array_elements(v_plan -> 'refunds') r
              ORDER BY (r ->> 'amount')::numeric DESC LIMIT 1) END;

    INSERT INTO public.sales_returns (organization_id, number, sale_id, branch_id, shift_id, kind, refund_method,
                                      subtotal, tax_total, total, reason, exchange_sale_id, business_date,
                                      idempotency_key, created_by)
    VALUES (o, app.next_document_number(o, s.branch_id, 'sales_return'), s.id, s.branch_id, v_shift.id,
            (v_plan ->> 'kind')::public.return_kind, v_method, (v_plan ->> 'subtotal')::numeric,
            (v_plan ->> 'tax_total')::numeric, (v_plan ->> 'total')::numeric, v_plan ->> 'reason', v_new_sale,
            v_today, p_idempotency_key, v_emp)
    RETURNING * INTO v_return;

    -- Lines and stock (rules 4 and 5), in product order.
    FOR v_line IN SELECT x FROM jsonb_array_elements(v_plan -> 'lines') x
                  ORDER BY x ->> 'product_id', x ->> 'sale_line_id' LOOP
        INSERT INTO public.sales_return_lines (organization_id, return_id, sale_line_id, unit_id, quantity, condition,
                                               refund_amount, tax_amount, unit_cost, created_by)
        VALUES (o, v_return.id, (v_line ->> 'sale_line_id')::uuid, (v_line ->> 'unit_id')::uuid,
                (v_line ->> 'quantity')::integer, (v_line ->> 'condition')::public.return_condition,
                (v_line ->> 'refund_amount')::numeric, (v_line ->> 'tax_amount')::numeric,
                (v_line ->> 'unit_cost')::numeric, v_emp)
        RETURNING id INTO v_line_id;
        v_state := CASE WHEN v_line ->> 'condition' = 'damaged' THEN 'damaged' ELSE 'sellable' END;
        -- No reverses_movement_id: a sale_out is reversed once (a void); a line can come back in pieces.
        INSERT INTO public.stock_movements (organization_id, product_id, branch_id, unit_id, quantity, type, stock_state,
                                            unit_cost, source_type, source_id, source_line_id, business_date, created_by)
        VALUES (o, (v_line ->> 'product_id')::uuid, s.branch_id, (v_line ->> 'unit_id')::uuid,
                (v_line ->> 'quantity')::integer, 'sale_return_in', v_state, (v_line ->> 'unit_cost')::numeric,
                'sales_return', v_return.id, v_line_id, v_today, v_emp);
    END LOOP;

    -- Exchange: the credit pays the new sale through the drawer (rule 8), money in before money out.
    IF v_new_sale IS NOT NULL AND v_used > 0 THEN
        INSERT INTO public.payments (organization_id, number, branch_id, direction, method, amount, customer_id,
                                     cash_account_id, shift_id, received_by, business_date, reason, idempotency_key, created_by)
        VALUES (o, app.next_document_number(o, s.branch_id, 'payment'), s.branch_id, 'in', 'cash', v_used,
                s.customer_id, v_shift.drawer_account_id, v_shift.id, v_emp, v_today, 'exchange ' || v_return.number,
                'system:exchange:' || v_return.id || ':in', v_emp)
        RETURNING id INTO v_drawer_in;
        INSERT INTO public.payment_allocations (organization_id, payment_id, amount, sale_id, created_by)
        VALUES (o, v_drawer_in, v_used, v_new_sale, v_emp);
        INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, shift_id, amount, type,
                                           source_type, source_id, note, business_date, created_by)
        VALUES (o, v_shift.drawer_account_id, s.branch_id, v_shift.id, v_used, 'sale', 'sale', v_new_sale,
                'exchange ' || v_return.number, v_today, v_emp);
        INSERT INTO public.payments (organization_id, number, branch_id, direction, method, amount, customer_id,
                                     cash_account_id, shift_id, received_by, business_date, reason, idempotency_key, created_by)
        VALUES (o, app.next_document_number(o, s.branch_id, 'payment'), s.branch_id, 'out', 'cash', v_used,
                s.customer_id, v_shift.drawer_account_id, v_shift.id, v_emp, v_today, v_return.reason,
                'system:exchange:' || v_return.id || ':out', v_emp)
        RETURNING id INTO v_payment;
        INSERT INTO public.payment_allocations (organization_id, payment_id, amount, return_id, created_by)
        VALUES (o, v_payment, v_used, v_return.id, v_emp);
        INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, shift_id, amount, type,
                                           source_type, source_id, note, business_date, created_by)
        VALUES (o, v_shift.drawer_account_id, s.branch_id, v_shift.id, -v_used, 'refund', 'sales_return', v_return.id,
                'exchange ' || v_return.number, v_today, v_emp);
    END IF;

    -- The money going back (rule 6 / the overpaid part of rule 7).
    FOR v_refund IN SELECT * FROM jsonb_array_elements(v_plan -> 'refunds') LOOP
        v_n := v_n + 1;
        INSERT INTO public.payments (organization_id, number, branch_id, direction, method, amount, customer_id,
                                     cash_account_id, shift_id, reference, received_by, business_date, reason,
                                     idempotency_key, created_by)
        VALUES (o, app.next_document_number(o, s.branch_id, 'payment'), s.branch_id, 'out',
                (v_refund ->> 'method')::public.payment_method, (v_refund ->> 'amount')::numeric, s.customer_id,
                CASE WHEN v_refund ->> 'method' = 'store_credit' THEN NULL ELSE (v_refund ->> 'cash_account_id')::uuid END,
                v_shift.id, v_refund ->> 'reference', v_emp, v_today, v_return.reason,
                'system:return:' || v_return.id || ':' || v_n, v_emp)
        RETURNING id INTO v_payment;
        INSERT INTO public.payment_allocations (organization_id, payment_id, amount, return_id, created_by)
        VALUES (o, v_payment, (v_refund ->> 'amount')::numeric, v_return.id, v_emp);
        IF v_refund ->> 'method' = 'store_credit' THEN
            INSERT INTO public.store_credit_movements (organization_id, customer_id, amount, source_type, source_id,
                                                       branch_id, business_date, created_by)
            VALUES (o, s.customer_id, (v_refund ->> 'amount')::numeric, 'sales_return', v_return.id, s.branch_id,
                    v_today, v_emp);
        ELSE
            -- K02: only drawer rows carry the shift.
            INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, shift_id, amount, type,
                                               source_type, source_id, note, business_date, created_by)
            VALUES (o, (v_refund ->> 'cash_account_id')::uuid, s.branch_id,
                    CASE WHEN v_refund ->> 'method' = 'cash' THEN v_shift.id END,
                    -(v_refund ->> 'amount')::numeric, 'refund', 'sales_return', v_return.id,
                    v_return.number || COALESCE(' ' || (v_refund ->> 'reference'), ''), v_today, v_emp);
        END IF;
    END LOOP;

    -- The contract (rule 7): the change row first (the deferred version check reads it), then the lines.
    IF v_contract IS NOT NULL THEN
        IF (v_contract ->> 'remaining_after')::numeric > 0 THEN
            INSERT INTO public.contract_changes (organization_id, contract_id, kind, old_version, new_version, amount,
                                                 principal_amount, profit_amount, reason, sales_return_id,
                                                 idempotency_key, branch_id, business_date, created_by)
            VALUES (o, c.id, 'return_adjustment', c.current_version, c.current_version + 1,
                    (v_contract ->> 'remaining_after')::numeric, (v_contract ->> 'principal_after')::numeric,
                    (v_contract ->> 'profit_after')::numeric, v_return.reason, v_return.id,
                    'system:return:' || v_return.id, s.branch_id, v_today, v_emp);
            v_version := app.write_schedule_version(o, c.id, v_contract -> 'lines', v_emp,
                                                    (v_contract ->> 'status_after')::public.contract_status);
        ELSIF (v_contract ->> 'status_before') <> 'completed' OR (v_contract ->> 'status_after') = 'returned' THEN
            INSERT INTO public.contract_changes (organization_id, contract_id, kind, old_version, new_version, amount,
                                                 principal_amount, profit_amount, reason, sales_return_id,
                                                 idempotency_key, branch_id, business_date, created_by)
            VALUES (o, c.id, 'return_adjustment', c.current_version, NULL, 0, 0, 0, v_return.reason, v_return.id,
                    'system:return:' || v_return.id, s.branch_id, v_today, v_emp);
            UPDATE public.schedule_lines l SET superseded = true
            WHERE l.organization_id = o AND l.contract_id = c.id AND l.version = c.current_version AND NOT l.superseded;
            UPDATE public.contracts k
               SET status = (v_contract ->> 'status_after')::public.contract_status,
                   closed_at = COALESCE(k.closed_at, now()), updated_at = now(), updated_by = v_emp
             WHERE k.id = c.id;
        ELSE
            -- A completed contract: nothing is owed; the return is only a refund. Record it all the same.
            INSERT INTO public.contract_changes (organization_id, contract_id, kind, old_version, new_version, amount,
                                                 principal_amount, profit_amount, reason, sales_return_id,
                                                 idempotency_key, branch_id, business_date, created_by)
            VALUES (o, c.id, 'return_adjustment', c.current_version, NULL, 0, 0, 0, v_return.reason, v_return.id,
                    'system:return:' || v_return.id, s.branch_id, v_today, v_emp);
        END IF;
        PERFORM app.write_audit('contract.return_adjusted', 'contract', c.id,
            jsonb_build_object('status', c.status, 'version', c.current_version,
                               'remaining', v_contract ->> 'remaining_before'),
            jsonb_build_object('status', v_contract ->> 'status_after', 'version', COALESCE(v_version, c.current_version),
                               'remaining', v_contract ->> 'remaining_after', 'credit', v_contract ->> 'credit',
                               'overpaid', v_contract ->> 'overpaid', 'return_id', v_return.id,
                               'return_number', v_return.number),
            v_return.reason, s.branch_id, 'warning');
    END IF;

    -- S12: the claim this refund answers closes.
    IF v_plan ->> 'warranty_claim_id' IS NOT NULL THEN
        UPDATE public.warranty_claims w
           SET status = 'closed', closed_at = clock_timestamp(),
               resolution = COALESCE(w.resolution || E'\n', '') || 'refunded by ' || v_return.number,
               updated_at = clock_timestamp(), updated_by = v_emp
         WHERE w.id = (v_plan ->> 'warranty_claim_id')::uuid AND w.organization_id = o;
        PERFORM app.write_audit('warranty_claim.moved', 'warranty_claim', (v_plan ->> 'warranty_claim_id')::uuid,
            NULL, jsonb_build_object('status', 'closed', 'return_id', v_return.id, 'return_number', v_return.number),
            NULL, s.branch_id);
    END IF;

    -- Rule 9: the ETA return receipt, on this shift's POS, when the sale has a fiscal record.
    IF v_sale_fiscal.id IS NOT NULL AND v_sale_fiscal.status <> 'cancelled' THEN
        SELECT st.environment INTO v_env FROM public.eta_settings st WHERE st.organization_id = o AND st.is_enabled;
        IF FOUND AND app.org_has_module(o, 'eta') THEN
            INSERT INTO public.fiscal_submissions (organization_id, branch_id, device_id, doc_type, return_id, environment,
                                                   internal_id, status, created_by)
            VALUES (o, s.branch_id, v_shift.device_id, 'b2c_return', v_return.id, v_env, v_return.number, 'pending', v_emp);
            IF v_sale_fiscal.eta_uuid IS NOT NULL THEN
                PERFORM app.eta_enqueue(o, 'eta.prepare', 'eta.prepare:' || COALESCE(v_shift.device_id, s.branch_id)::text,
                    jsonb_build_object('device_id', v_shift.device_id, 'branch_id', s.branch_id));
            END IF;
        END IF;
    END IF;

    PERFORM app.write_audit('sales_return.created', 'sales_return', v_return.id, NULL,
        jsonb_build_object('number', v_return.number, 'kind', v_return.kind, 'sale_id', s.id, 'sale_number', s.number,
                           'total', v_return.total::text, 'refund_method', v_return.refund_method,
                           'refunds', v_plan -> 'refunds', 'exchange_sale_id', v_new_sale,
                           'period_override', (v_plan ->> 'period_override')::boolean,
                           'lines', (SELECT jsonb_agg(jsonb_build_object('sale_line_id', x ->> 'sale_line_id',
                                         'unit_id', x ->> 'unit_id', 'quantity', (x ->> 'quantity')::integer,
                                         'condition', x ->> 'condition', 'refund_amount', x ->> 'refund_amount'))
                                     FROM jsonb_array_elements(v_plan -> 'lines') x)),
        v_return.reason, s.branch_id,
        CASE WHEN (v_plan ->> 'period_override')::boolean THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN app.return_json(o, v_return.id);
END;
$$;

-- 5. Lists, details, print ------------------------------------------------------------------------------

CREATE FUNCTION public.list_sales_returns(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE o uuid := app.current_org_id(); f jsonb := COALESCE(p_filters, '{}'::jsonb); v_from date; v_to date;
        v_branch uuid; v_sale uuid; v_customer uuid; v_kind public.return_kind; v_page integer; v_size integer;
        v_rows jsonb; v_count bigint;
BEGIN
    PERFORM app.return_read_guard();
    BEGIN
        v_from := NULLIF(f ->> 'from', '')::date;
        v_to := NULLIF(f ->> 'to', '')::date;
        v_branch := NULLIF(f ->> 'branch_id', '')::uuid;
        v_sale := NULLIF(f ->> 'sale_id', '')::uuid;
        v_customer := NULLIF(f ->> 'customer_id', '')::uuid;
        v_kind := NULLIF(f ->> 'kind', '')::public.return_kind;
        v_page := COALESCE(NULLIF(f ->> 'page', '')::integer, 1);
        v_size := COALESCE(NULLIF(f ->> 'page_size', '')::integer, 20);
    EXCEPTION WHEN data_exception OR invalid_text_representation THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END;
    IF v_page < 1 OR v_size NOT BETWEEN 1 AND 100 OR v_from > v_to THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;
    WITH rows AS (
        SELECT r.id, r.created_at
        FROM public.sales_returns r
        JOIN public.sales s ON s.id = r.sale_id AND s.organization_id = r.organization_id
        WHERE r.organization_id = o AND app.can_read_return(r.branch_id)
          AND (v_from IS NULL OR r.business_date >= v_from) AND (v_to IS NULL OR r.business_date <= v_to)
          AND (v_branch IS NULL OR r.branch_id = v_branch) AND (v_sale IS NULL OR r.sale_id = v_sale)
          AND (v_customer IS NULL OR s.customer_id = v_customer) AND (v_kind IS NULL OR r.kind = v_kind)
    )
    SELECT (SELECT count(*) FROM rows),
           COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'id', r.id, 'number', r.number, 'kind', r.kind, 'refund_method', r.refund_method,
                'sale_id', r.sale_id, 'sale_number', s.number, 'branch', jsonb_build_object('id', b.id, 'name', b.name),
                'customer', CASE WHEN cu.id IS NOT NULL THEN jsonb_build_object('id', cu.id, 'name', cu.full_name) END,
                'total', r.total::text, 'reason', r.reason, 'business_date', r.business_date, 'created_at', r.created_at,
                'created_by', jsonb_build_object('id', e.id, 'name', e.full_name)) ORDER BY r.created_at DESC, r.id DESC)
            FROM (SELECT x.id FROM rows x ORDER BY x.created_at DESC, x.id DESC
                  LIMIT v_size OFFSET (v_page - 1) * v_size) p
            JOIN public.sales_returns r ON r.id = p.id
            JOIN public.sales s ON s.id = r.sale_id AND s.organization_id = r.organization_id
            JOIN public.branches b ON b.id = r.branch_id AND b.organization_id = r.organization_id
            LEFT JOIN public.customers cu ON cu.id = s.customer_id AND cu.organization_id = s.organization_id
            LEFT JOIN public.employees e ON e.id = r.created_by AND e.organization_id = r.organization_id), '[]'::jsonb)
    INTO v_count, v_rows;
    RETURN jsonb_build_object('items', v_rows, 'total_count', v_count, 'page', v_page, 'page_size', v_size);
END;
$$;

CREATE FUNCTION public.get_sales_return(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE o uuid := app.current_org_id(); v_branch uuid;
BEGIN
    PERFORM app.return_read_guard();
    SELECT r.branch_id INTO v_branch FROM public.sales_returns r WHERE r.id = p_id AND r.organization_id = o;
    IF NOT FOUND OR NOT app.can_read_return(v_branch) THEN
        RAISE EXCEPTION 'RETURN_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.return_json(o, p_id);
END;
$$;

-- S04's print log for a return: the first print is the original, every later one a copy.
CREATE FUNCTION public.record_return_receipt_print(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE o uuid := app.current_org_id(); r public.sales_returns; n integer; v_key text;
BEGIN
    SELECT k INTO v_key FROM unnest(ARRAY['refund.create', 'sale.create', 'report.view']) k
    WHERE app.has_permission(k) LIMIT 1;
    IF v_key IS NULL THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: refund.create, sale.create or report.view' USING ERRCODE = '42501';
    END IF;
    PERFORM app.require_permission(v_key);       -- a write: an expired shop is refused
    SELECT * INTO r FROM public.sales_returns x WHERE x.id = p_id AND x.organization_id = o FOR UPDATE;
    IF NOT FOUND OR NOT app.can_read_return(r.branch_id) THEN
        RAISE EXCEPTION 'RETURN_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    SELECT count(*) + 1 INTO n FROM public.audit_log a
    WHERE a.organization_id = o AND a.entity_type = 'sales_return' AND a.entity_id = r.id
      AND a.action = 'sales_return.receipt_printed';
    PERFORM app.write_audit('sales_return.receipt_printed', 'sales_return', r.id,
        p_after => jsonb_build_object('number', r.number, 'print_no', n, 'copy', n > 1), p_branch_id => r.branch_id);
    RETURN jsonb_build_object('print_no', n, 'copy', n > 1);
END;
$$;

-- 6. S12: the claim's refund opens the return form ---------------------------------------------------------

DROP FUNCTION public.request_claim_refund(uuid);
CREATE FUNCTION public.request_claim_refund(p_claim_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE e uuid := app.require_permission('warranty.manage'); o uuid := app.current_org_id(); w public.warranty_claims;
        v_sale uuid;
BEGIN
    SELECT * INTO w FROM public.warranty_claims x WHERE x.id = p_claim_id AND x.organization_id = o;
    IF NOT FOUND OR NOT app.has_branch_access(w.branch_id) THEN
        RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;
    PERFORM app.require_branch_access(w.branch_id);
    IF w.status NOT IN ('open', 'in_repair', 'repaired') THEN
        RAISE EXCEPTION 'CLAIM_REFUND_NEEDS_RETURN: the claim is closed' USING ERRCODE = 'P0001';
    END IF;
    SELECT l.sale_id INTO v_sale FROM public.sale_lines l WHERE l.id = w.sale_line_id AND l.organization_id = o;
    RETURN jsonb_build_object('claim_id', w.id, 'sale_id', v_sale, 'sale_line_id', w.sale_line_id,
                              'unit_id', w.unit_id);
END;
$$;

-- 7. R02 (D74's TODO(S05/N05)): the new version carries the return --------------------------------------

CREATE OR REPLACE FUNCTION app.customer_open_balance(p_org uuid, p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_totals numeric; v_paid numeric; v_returns numeric; v_fees numeric;
BEGIN
    SELECT COALESCE(sum(app.customer_contract_total(p_org, c.id)), 0) INTO v_totals
    FROM public.contracts c
    WHERE c.organization_id = p_org AND c.customer_id = p_customer_id AND c.status IN ('active', 'rescheduled');

    SELECT COALESCE(sum(ea.amount), 0) INTO v_paid
    FROM public.v_effective_allocations ea
    JOIN public.contracts c ON c.id = ea.contract_id AND c.organization_id = ea.organization_id
    WHERE ea.organization_id = p_org AND c.customer_id = p_customer_id
      AND c.status IN ('active', 'rescheduled') AND ea.schedule_line_id IS NOT NULL;

    -- S05: what returns took off these contracts. Shown, not subtracted: the contract totals above
    -- already come from the new schedule versions.
    SELECT COALESCE(sum(app.contract_return_reduction(p_org, c.id)), 0) INTO v_returns
    FROM public.contracts c
    WHERE c.organization_id = p_org AND c.customer_id = p_customer_id AND c.status IN ('active', 'rescheduled');

    SELECT COALESCE(sum(cb.fees_due), 0) INTO v_fees
    FROM public.v_contract_balances cb
    WHERE cb.organization_id = p_org AND cb.customer_id = p_customer_id AND cb.status IN ('active', 'rescheduled');

    RETURN jsonb_build_object(
        'contract_totals', v_totals::numeric(18,2)::text,
        'payments', v_paid::numeric(18,2)::text,
        'returns', v_returns::numeric(18,2)::text,
        'open_balance', (v_totals - v_paid)::numeric(18,2)::text,
        'fees_due', v_fees::numeric(18,2)::text,
        'total_due', (v_totals - v_paid + v_fees)::numeric(18,2)::text);
END;
$$;

CREATE OR REPLACE FUNCTION app.customer_statement_rows(p_org uuid, p_customer_id uuid)
RETURNS TABLE (d date, created_at timestamptz, ord integer, kind text, id uuid, number text,
               detail text, reference text, debit numeric, credit numeric)
LANGUAGE sql STABLE SET search_path = ''
AS $$
    WITH o AS (SELECT og.timezone FROM public.organizations og WHERE og.id = p_org)
    -- every sale of the customer; a void is its own return row
    SELECT s.business_date, s.created_at, 1, 'sale', s.id, s.number, NULL::text, NULL::text, s.total, 0::numeric
    FROM public.sales s
    WHERE s.organization_id = p_org AND s.customer_id = p_customer_id
    UNION ALL
    -- a contract adds to its sale what it costs above the financed amount (the markup, plus what a
    -- reschedule added); one without a sale (M02) adds its whole contract total.
    -- TODO(S10): a contract from an order is issued with the delivery's sale; revisit with S10.
    -- N05: a waiver at early settlement is added back here and shown as its own credit row below.
    -- S05: so is what a return took off (the return row below carries the whole credit).
    SELECT COALESCE(s.business_date, (c.created_at AT TIME ZONE (SELECT o.timezone FROM o))::date),
           c.created_at, 2, 'contract', c.id, c.number, s.number, NULL,
           app.customer_contract_total(p_org, c.id)
               + COALESCE((SELECT sum(x.profit_waived) FROM public.contract_changes x
                           WHERE x.organization_id = c.organization_id AND x.contract_id = c.id), 0)
               + app.contract_return_reduction(p_org, c.id)
               - CASE WHEN c.sale_id IS NULL THEN 0 ELSE c.financed_amount END, 0
    FROM public.contracts c
    LEFT JOIN public.sales s ON s.id = c.sale_id AND s.organization_id = c.organization_id
    WHERE c.organization_id = p_org AND c.customer_id = p_customer_id
    UNION ALL
    -- payments and refunds in cash or by bank transfer; a reversal undoes its original
    -- TODO(S10): an order deposit is a payment in (a credit) until the delivery issues the sale.
    SELECT p.business_date, p.created_at, 3,
           CASE WHEN p.reverses_payment_id IS NOT NULL THEN 'payment_reversal'
                WHEN p.direction = 'in' THEN 'payment_in' ELSE 'payment_out' END,
           p.id, p.number, p.method::text, p.reference,
           CASE WHEN COALESCE(orig.direction, p.direction) = 'in' AND p.reverses_payment_id IS NULL THEN 0
                WHEN COALESCE(orig.direction, p.direction) = 'out' AND p.reverses_payment_id IS NOT NULL THEN 0
                ELSE p.amount END,
           CASE WHEN COALESCE(orig.direction, p.direction) = 'in' AND p.reverses_payment_id IS NULL THEN p.amount
                WHEN COALESCE(orig.direction, p.direction) = 'out' AND p.reverses_payment_id IS NOT NULL THEN p.amount
                ELSE 0 END
    FROM public.payments p
    LEFT JOIN public.payments orig ON orig.id = p.reverses_payment_id AND orig.organization_id = p.organization_id
    WHERE p.organization_id = p_org AND p.customer_id = p_customer_id AND p.method <> 'store_credit'
    UNION ALL
    -- returns, voids and exchanges of the customer's sales; an installment sale's return also
    -- gives back the returned goods' share of the profit (S05 rule 7)
    SELECT r.business_date, r.created_at, 4, 'return', r.id, r.number, r.kind::text, NULL, 0,
           r.total + COALESCE(app.stored_return_profit_share(p_org, r.id), 0)
    FROM public.sales_returns r
    JOIN public.sales s ON s.id = r.sale_id AND s.organization_id = r.organization_id
    WHERE r.organization_id = p_org AND s.customer_id = p_customer_id
    UNION ALL
    -- late fees (N04) and their waivers; the number is the contract's
    SELECT ch.assessed_on, ch.created_at, 5, 'fee', ch.id, c.number, ch.kind::text, NULL, ch.amount, 0
    FROM public.charges ch
    JOIN public.contracts c ON c.id = ch.contract_id AND c.organization_id = ch.organization_id
    WHERE ch.organization_id = p_org AND c.customer_id = p_customer_id
    UNION ALL
    SELECT (w.created_at AT TIME ZONE (SELECT o.timezone FROM o))::date, w.created_at, 6, 'fee_waiver', w.id,
           c.number, w.reason, NULL, 0, w.amount
    FROM public.charge_waivers w
    JOIN public.charges ch ON ch.id = w.charge_id AND ch.organization_id = w.organization_id
    JOIN public.contracts c ON c.id = ch.contract_id AND c.organization_id = ch.organization_id
    WHERE w.organization_id = p_org AND c.customer_id = p_customer_id
    UNION ALL
    -- N05: profit waived at an early settlement and a written-off balance (credits); the number is
    -- the contract's
    SELECT x.business_date, x.created_at, 7, CASE x.kind WHEN 'write_off' THEN 'write_off' ELSE 'profit_waiver' END,
           x.id, c.number, x.reason, NULL, 0,
           CASE x.kind WHEN 'write_off' THEN x.amount ELSE x.profit_waived END
    FROM public.contract_changes x
    JOIN public.contracts c ON c.id = x.contract_id AND c.organization_id = x.organization_id
    WHERE x.organization_id = p_org AND c.customer_id = p_customer_id
      AND ((x.kind = 'early_settlement' AND x.profit_waived > 0) OR x.kind = 'write_off')
$$;

-- 8. ETA (rule 9): return receipts join their POS's chain -------------------------------------------------

-- T02's loader, now with the returns whose sale receipt has its UUID. A row is a sale receipt
-- (kind 'receipt') or a return receipt (kind 'return': the return as the sale, its lines with what
-- comes back, the refunds as payments, and the original receipt's UUID and issue time).
CREATE OR REPLACE FUNCTION public.eta_load_pending_for_device(p_device_id uuid, p_branch_id uuid DEFAULT NULL,
                                                              p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    WITH docs AS (
        SELECT s.issued_at, s.number, jsonb_build_object(
            'kind', 'receipt',
            'fiscal_id', f.id, 'organization_id', f.organization_id, 'environment', f.environment,
            'sale', jsonb_build_object(
                'id', s.id, 'number', s.number,
                'issued_at', to_char(s.issued_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                'prices_include_vat', s.prices_include_vat, 'total', s.total::text),
            'lines', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'line_no', l.line_no, 'quantity', l.quantity, 'unit_price', l.unit_price::text,
                    'discount_amount', l.discount_amount::text,
                    'tax_rate', l.tax_rate::numeric(5,2)::text, 'tax_amount', l.tax_amount::text,
                    'line_total', l.line_total::text, 'sku', p.sku, 'name', p.name_ar,
                    'eta_item_code', p.eta_item_code, 'eta_item_type', p.eta_item_type,
                    'eta_tax_type', t.eta_tax_type, 'eta_subtype', t.eta_subtype) ORDER BY l.line_no)
                FROM public.sale_lines l
                JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
                JOIN public.tax_classes t ON t.id = l.tax_class_id AND t.organization_id = l.organization_id
                WHERE l.organization_id = f.organization_id AND l.sale_id = s.id), '[]'::jsonb),
            'payments', COALESCE((
                SELECT jsonb_agg(jsonb_build_object('method', pay.method, 'amount', a.amount::text)
                                 ORDER BY pay.number)
                FROM public.payment_allocations a
                JOIN public.payments pay ON pay.id = a.payment_id AND pay.organization_id = a.organization_id
                WHERE a.organization_id = f.organization_id AND a.sale_id = s.id), '[]'::jsonb),
            'customer', CASE WHEN c.id IS NOT NULL THEN jsonb_build_object(
                'name', c.full_name, 'national_id', c.national_id, 'is_business', c.is_business,
                'tax_registration_no', c.tax_registration_no) END,
            'seller', jsonb_build_object(
                'rin', o.tax_registration_no, 'name', COALESCE(NULLIF(btrim(o.legal_name), ''), o.name),
                'activity_code', es.activity_code, 'branch_code', b.eta_branch_code,
                'governorate', b.governorate, 'city', b.city, 'street', b.address,
                'building_number', b.building_number),
            'device', CASE WHEN d.id IS NOT NULL THEN jsonb_build_object(
                'id', d.id, 'serial', d.eta_serial, 'status', d.eta_status,
                'is_active', d.is_active AND d.archived_at IS NULL) END) AS doc
        FROM public.fiscal_submissions f
        JOIN public.sales s ON s.id = f.sale_id AND s.organization_id = f.organization_id
        JOIN public.organizations o ON o.id = f.organization_id
        JOIN public.branches b ON b.id = f.branch_id AND b.organization_id = f.organization_id
        LEFT JOIN public.eta_settings es ON es.organization_id = f.organization_id
        LEFT JOIN public.customers c ON c.id = s.customer_id AND c.organization_id = f.organization_id
        LEFT JOIN public.devices d ON d.id = f.device_id AND d.organization_id = f.organization_id
        WHERE f.status = 'pending' AND f.eta_uuid IS NULL AND f.doc_type = 'b2c_receipt'
          AND ((p_device_id IS NOT NULL AND f.device_id = p_device_id)
               OR (p_device_id IS NULL AND p_branch_id IS NOT NULL AND f.device_id IS NULL
                   AND f.branch_id = p_branch_id))
        UNION ALL
        SELECT r.created_at, r.number, jsonb_build_object(
            'kind', 'return',
            'fiscal_id', f.id, 'organization_id', f.organization_id, 'environment', f.environment,
            'sale', jsonb_build_object(
                'id', r.id, 'number', r.number,
                'issued_at', to_char(date_trunc('second', r.created_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                'prices_include_vat', s.prices_include_vat, 'total', r.total::text),
            'original', jsonb_build_object(
                'uuid', sf.eta_uuid,
                'issued_at', to_char(s.issued_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
            'lines', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'line_no', l.line_no, 'quantity', rl.quantity, 'unit_price', l.unit_price::text,
                    -- the line's discount, cumulative like the refund (S05 rule 4)
                    'discount_amount', (round(l.discount_amount * (rl.prev_qty + rl.quantity) / l.quantity, 2)
                                        - round(l.discount_amount * rl.prev_qty / l.quantity, 2))::numeric(18,2)::text,
                    'tax_rate', l.tax_rate::numeric(5,2)::text, 'tax_amount', rl.tax_amount::text,
                    'line_total', rl.refund_amount::text, 'sku', p.sku, 'name', p.name_ar,
                    'eta_item_code', p.eta_item_code, 'eta_item_type', p.eta_item_type,
                    'eta_tax_type', t.eta_tax_type, 'eta_subtype', t.eta_subtype) ORDER BY l.line_no, rl.id)
                FROM (SELECT x.*, COALESCE((SELECT sum(y.quantity) FROM public.sales_return_lines y
                                            JOIN public.sales_returns yr ON yr.id = y.return_id AND yr.organization_id = y.organization_id
                                            WHERE y.organization_id = x.organization_id AND y.sale_line_id = x.sale_line_id
                                              AND (yr.created_at, yr.id) < (r.created_at, r.id)), 0)::integer AS prev_qty
                      FROM public.sales_return_lines x
                      WHERE x.organization_id = f.organization_id AND x.return_id = r.id) rl
                JOIN public.sale_lines l ON l.id = rl.sale_line_id AND l.organization_id = rl.organization_id
                JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
                JOIN public.tax_classes t ON t.id = l.tax_class_id AND t.organization_id = l.organization_id), '[]'::jsonb),
            'payments', COALESCE((
                SELECT jsonb_agg(jsonb_build_object('method', pay.method, 'amount', a.amount::text)
                                 ORDER BY pay.number)
                FROM public.payment_allocations a
                JOIN public.payments pay ON pay.id = a.payment_id AND pay.organization_id = a.organization_id
                WHERE a.organization_id = f.organization_id AND a.return_id = r.id), '[]'::jsonb),
            'customer', CASE WHEN c.id IS NOT NULL THEN jsonb_build_object(
                'name', c.full_name, 'national_id', c.national_id, 'is_business', c.is_business,
                'tax_registration_no', c.tax_registration_no) END,
            'seller', jsonb_build_object(
                'rin', o.tax_registration_no, 'name', COALESCE(NULLIF(btrim(o.legal_name), ''), o.name),
                'activity_code', es.activity_code, 'branch_code', b.eta_branch_code,
                'governorate', b.governorate, 'city', b.city, 'street', b.address,
                'building_number', b.building_number),
            'device', CASE WHEN d.id IS NOT NULL THEN jsonb_build_object(
                'id', d.id, 'serial', d.eta_serial, 'status', d.eta_status,
                'is_active', d.is_active AND d.archived_at IS NULL) END)
        FROM public.fiscal_submissions f
        JOIN public.sales_returns r ON r.id = f.return_id AND r.organization_id = f.organization_id
        JOIN public.sales s ON s.id = r.sale_id AND s.organization_id = r.organization_id
        JOIN public.fiscal_submissions sf ON sf.sale_id = s.id AND sf.organization_id = s.organization_id
        JOIN public.organizations o ON o.id = f.organization_id
        JOIN public.branches b ON b.id = f.branch_id AND b.organization_id = f.organization_id
        LEFT JOIN public.eta_settings es ON es.organization_id = f.organization_id
        LEFT JOIN public.customers c ON c.id = s.customer_id AND c.organization_id = f.organization_id
        LEFT JOIN public.devices d ON d.id = f.device_id AND d.organization_id = f.organization_id
        WHERE f.status = 'pending' AND f.eta_uuid IS NULL AND f.doc_type = 'b2c_return'
          AND sf.eta_uuid IS NOT NULL                       -- waits for the sale receipt's UUID
          AND ((p_device_id IS NOT NULL AND f.device_id = p_device_id)
               OR (p_device_id IS NULL AND p_branch_id IS NOT NULL AND f.device_id IS NULL
                   AND f.branch_id = p_branch_id))
    )
    SELECT jsonb_build_object(
        'last_uuid', (SELECT d.eta_last_uuid FROM public.devices d WHERE d.id = p_device_id),
        'rows', COALESCE((
            SELECT jsonb_agg(k.doc ORDER BY k.issued_at, k.number)
            FROM (SELECT * FROM docs ORDER BY issued_at, number
                  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)) k), '[]'::jsonb))
$$;

-- A sale receipt that gets its UUID wakes the returns that waited for it (on their own POS).
CREATE OR REPLACE FUNCTION public.eta_store_prepared(p_fiscal_id uuid, p_uuid text, p_previous_uuid text, p_payload jsonb,
                                                     p_qr text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_f public.fiscal_submissions; v_prev text := COALESCE(p_previous_uuid, ''); v_w record;
BEGIN
    IF p_uuid IS NULL OR p_uuid !~ '^[0-9a-f]{64}$' OR v_prev !~ '^([0-9a-f]{64})?$' OR p_uuid = v_prev
       OR p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' OR NULLIF(p_qr, '') IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: prepared receipt' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_f FROM public.fiscal_submissions f WHERE f.id = p_fiscal_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FISCAL_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_f.status <> 'pending' OR v_f.eta_uuid IS NOT NULL THEN
        RAISE EXCEPTION 'ALREADY_PREPARED' USING ERRCODE = 'P0001';
    END IF;
    IF v_f.device_id IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a receipt needs a POS' USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.devices d SET eta_last_uuid = p_uuid
    WHERE d.id = v_f.device_id AND COALESCE(d.eta_last_uuid, '') = v_prev;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CHAIN_MOVED' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.fiscal_submissions f
       SET eta_uuid = p_uuid, previous_uuid = v_prev, qr_payload = p_qr,
           payload = COALESCE(f.payload, '{}'::jsonb) || p_payload,     -- keeps the deadline mark
           next_retry_at = NULL, last_error = NULL, updated_at = now()
     WHERE f.id = p_fiscal_id;
    PERFORM app.eta_enqueue(v_f.organization_id, 'eta.submit', 'eta.submit:' || v_f.device_id::text,
        jsonb_build_object('device_id', v_f.device_id));
    -- S05: returns of this sale that waited for its UUID.
    IF v_f.sale_id IS NOT NULL THEN
        FOR v_w IN SELECT DISTINCT rf.device_id, rf.branch_id FROM public.fiscal_submissions rf
                   JOIN public.sales_returns r ON r.id = rf.return_id AND r.organization_id = rf.organization_id
                   WHERE rf.organization_id = v_f.organization_id AND r.sale_id = v_f.sale_id
                     AND rf.status = 'pending' AND rf.eta_uuid IS NULL LOOP
            PERFORM app.eta_enqueue(v_f.organization_id, 'eta.prepare',
                'eta.prepare:' || COALESCE(v_w.device_id, v_w.branch_id)::text,
                jsonb_build_object('device_id', v_w.device_id, 'branch_id', v_w.branch_id));
        END LOOP;
    END IF;
END;
$$;

-- 9. Grants -----------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.can_read_return(uuid), app.return_read_guard(), app.sale_refundable(uuid, uuid),
    app.return_profit_share(numeric, numeric, numeric, numeric), app.stored_return_profit_share(uuid, uuid),
    app.contract_return_reduction(uuid, uuid),
    app.return_contract_plan(uuid, public.contracts, public.sales, numeric, boolean),
    app.return_refund_lines(uuid, public.sales, public.shifts, jsonb, numeric, boolean, boolean),
    app.return_compute(uuid, public.shifts, jsonb, boolean), app.return_json(uuid, uuid)
    FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.get_sale_returnable(uuid), public.quote_sales_return(jsonb),
    public.post_sales_return(jsonb, text), public.list_sales_returns(jsonb), public.get_sales_return(uuid),
    public.record_return_receipt_print(uuid), public.request_claim_refund(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_sale_returnable(uuid), public.quote_sales_return(jsonb),
    public.post_sales_return(jsonb, text), public.list_sales_returns(jsonb), public.get_sales_return(uuid),
    public.record_return_receipt_print(uuid), public.request_claim_refund(uuid)
    TO authenticated;
