-- =============================================================================
-- R02 · Customer account (EC-64, D74)
--
-- One page shows everything about a customer's money: purchases, returns, installment contracts
-- and their schedules, payments, overdue amounts, the open balance, documents and guarantors, and
-- a statement for a date range. Read only: no table, column, enum, view or permission changes;
-- every number is computed here once (from the baseline views where one exists) and the API and
-- the page only show it.
--
-- Numbered after S09's reserved 20261016100000 (D39). Nothing creates contracts, schedule lines,
-- collections or fees yet (N02-N05), so on real data the contract parts are empty until then.
--
-- Rules (D74):
--   1. Reads use the R01 read guard (any customer read key + the customers module); an expired
--      shop can read.
--   2. Contract total = the current (not superseded) schedule lines' amounts + what was paid on
--      superseded lines, so the formula below stays true after a reschedule (N05). For a contract
--      never rescheduled it equals total_payable.
--   3. Open balance (the slice's "Done when"), over the customer's active and rescheduled
--      contracts: contract totals - payments (effective allocations on their schedule lines) -
--      returns (sales_returns with refund_method contract_adjustment on their sales). Late fees
--      are kept apart: fees_due, and total_due = open balance + fees_due.
--   4. Statement: balance > 0 = the customer owes the shop. Debits: every sale (a void is a
--      return row), a contract's total above its financed amount when it has a sale (the
--      markup, plus what a reschedule added; a contract without a sale, M02: its whole
--      contract total), a payment out (refund), a late fee, the reversal of a payment in.
--      Credits: a payment in, a return / void / exchange, a fee waiver, the reversal of a payment
--      out. Store-credit payments (in or out) are not rows: the credit was counted when it was
--      given (by the return or the overpayment). Without dates the closing balance equals
--      total_due - store credit.
-- =============================================================================

-- 1. Helpers (schema app, no grants) ---------------------------------------------------------------

-- Rule 2. A contract without schedule lines (never the case once N02 writes them in the same
-- transaction) counts its total payable.
CREATE FUNCTION app.customer_contract_total(p_org uuid, p_contract_id uuid)
RETURNS numeric LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT CASE WHEN count(ls.schedule_line_id) = 0 THEN max(c.total_payable)
                ELSE COALESCE(sum(ls.amount) FILTER (WHERE NOT ls.superseded), 0)
                     + COALESCE(sum(ls.paid) FILTER (WHERE ls.superseded), 0) END::numeric(18,2)
    FROM public.contracts c
    LEFT JOIN public.v_schedule_line_status ls ON ls.contract_id = c.id AND ls.organization_id = c.organization_id
    WHERE c.organization_id = p_org AND c.id = p_contract_id
$$;

-- Rule 3: {contract_totals, payments, returns, open_balance, fees_due, total_due}, money as text.
-- TODO(S05/N05): a contract_adjustment return must also write the new schedule version, so that
-- the open balance and v_contract_balances.remaining keep agreeing.
CREATE FUNCTION app.customer_open_balance(p_org uuid, p_customer_id uuid)
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

    SELECT COALESCE(sum(r.total), 0) INTO v_returns
    FROM public.sales_returns r
    JOIN public.contracts c ON c.sale_id = r.sale_id AND c.organization_id = r.organization_id
    WHERE r.organization_id = p_org AND c.customer_id = p_customer_id
      AND c.status IN ('active', 'rescheduled') AND r.refund_method = 'contract_adjustment';

    SELECT COALESCE(sum(cb.fees_due), 0) INTO v_fees
    FROM public.v_contract_balances cb
    WHERE cb.organization_id = p_org AND cb.customer_id = p_customer_id AND cb.status IN ('active', 'rescheduled');

    RETURN jsonb_build_object(
        'contract_totals', v_totals::numeric(18,2)::text,
        'payments', v_paid::numeric(18,2)::text,
        'returns', v_returns::numeric(18,2)::text,
        'open_balance', (v_totals - v_paid - v_returns)::numeric(18,2)::text,
        'fees_due', v_fees::numeric(18,2)::text,
        'total_due', (v_totals - v_paid - v_returns + v_fees)::numeric(18,2)::text);
END;
$$;

-- Overdue numbers and the aging buckets of the customer's open contracts. next_due_date = the
-- earliest unpaid current line (it may be in the past); next_due_amount = what is left on the
-- lines due that day.
CREATE FUNCTION app.customer_overdue_json(p_org uuid, p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_r record; v_next numeric; v_aging jsonb;
BEGIN
    SELECT COALESCE(sum(cb.overdue_amount), 0) AS overdue_amount,
           COALESCE(sum(cb.overdue_lines), 0)::integer AS overdue_lines,
           max(cb.max_days_late)::integer AS max_days_late,
           min(cb.next_due_date) AS next_due_date
    INTO v_r
    FROM public.v_contract_balances cb
    WHERE cb.organization_id = p_org AND cb.customer_id = p_customer_id AND cb.status IN ('active', 'rescheduled');

    IF v_r.next_due_date IS NOT NULL THEN
        SELECT sum(ls.remaining) INTO v_next
        FROM public.v_schedule_line_status ls
        JOIN public.contracts c ON c.id = ls.contract_id AND c.organization_id = ls.organization_id
        WHERE ls.organization_id = p_org AND c.customer_id = p_customer_id
          AND c.status IN ('active', 'rescheduled') AND NOT ls.superseded
          AND ls.due_date = v_r.next_due_date AND ls.status IN ('overdue', 'partly_paid', 'due', 'upcoming');
    END IF;

    SELECT jsonb_build_object(
        'not_yet_due', COALESCE(sum(a.not_yet_due), 0)::numeric(18,2)::text,
        'late_1_30', COALESCE(sum(a.late_1_30), 0)::numeric(18,2)::text,
        'late_31_60', COALESCE(sum(a.late_31_60), 0)::numeric(18,2)::text,
        'late_61_90', COALESCE(sum(a.late_61_90), 0)::numeric(18,2)::text,
        'late_90_plus', COALESCE(sum(a.late_90_plus), 0)::numeric(18,2)::text)
    INTO v_aging
    FROM public.v_receivables_aging a
    WHERE a.organization_id = p_org AND a.customer_id = p_customer_id;

    RETURN jsonb_build_object(
        'overdue_amount', v_r.overdue_amount::numeric(18,2)::text,
        'overdue_lines', v_r.overdue_lines,
        'max_days_late', v_r.max_days_late,
        'next_due_date', v_r.next_due_date,
        'next_due_amount', v_next::numeric(18,2)::text,
        'aging', v_aging);
END;
$$;

-- One contract of the customer, with its balances (the contract's CustomerContractSummary).
CREATE FUNCTION app.customer_contract_json(p_org uuid, p_contract_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', c.id, 'number', c.number, 'status', c.status,
        'branch', jsonb_build_object('id', b.id, 'name', b.name),
        'sale_id', c.sale_id, 'sale_number', s.number, 'issued_at', c.created_at,
        'is_migrated', c.is_migrated,
        'cash_price', c.cash_price::text, 'down_payment', c.down_payment::text,
        'financed_amount', c.financed_amount::text, 'markup_amount', c.markup_amount::text,
        'total_payable', c.total_payable::text,
        'contract_total', app.customer_contract_total(p_org, c.id)::text,
        'paid', cb.paid::text, 'remaining', cb.remaining::text, 'fees_due', cb.fees_due::text,
        'overdue_amount', cb.overdue_amount::text, 'overdue_lines', cb.overdue_lines,
        'max_days_late', cb.max_days_late, 'next_due_date', cb.next_due_date,
        'installments_count', c.installments_count, 'frequency', c.frequency,
        'first_due_date', c.first_due_date)
    FROM public.contracts c
    JOIN public.branches b ON b.id = c.branch_id AND b.organization_id = c.organization_id
    JOIN public.v_contract_balances cb ON cb.contract_id = c.id AND cb.organization_id = c.organization_id
    LEFT JOIN public.sales s ON s.id = c.sale_id AND s.organization_id = c.organization_id
    WHERE c.organization_id = p_org AND c.id = p_contract_id
$$;

-- One payment with what it paid (document numbers; a schedule line is "<contract> #<seq>").
CREATE FUNCTION app.customer_payment_json(p_org uuid, p_payment_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', p.id, 'number', p.number, 'direction', p.direction, 'method', p.method,
        'amount', p.amount::text, 'reference', p.reference, 'received_at', p.paid_at,
        'business_date', p.business_date,
        'branch', jsonb_build_object('id', b.id, 'name', b.name),
        'allocated_to', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'kind', CASE WHEN a.sale_id IS NOT NULL THEN 'sale'
                             WHEN a.schedule_line_id IS NOT NULL THEN 'schedule_line'
                             WHEN a.charge_id IS NOT NULL THEN 'charge'
                             WHEN a.order_id IS NOT NULL THEN 'order'
                             ELSE 'return' END,
                'document_number', COALESCE(s.number, CASE WHEN sl.id IS NOT NULL THEN c.number || ' #' || sl.seq END,
                                            c.number, so.number, r.number),
                'amount', a.amount::text) ORDER BY a.created_at, a.id)
            FROM public.payment_allocations a
            LEFT JOIN public.sales s ON s.id = a.sale_id AND s.organization_id = a.organization_id
            LEFT JOIN public.schedule_lines sl ON sl.id = a.schedule_line_id AND sl.organization_id = a.organization_id
            LEFT JOIN public.contracts c ON c.id = a.contract_id AND c.organization_id = a.organization_id
            LEFT JOIN public.sales_orders so ON so.id = a.order_id AND so.organization_id = a.organization_id
            LEFT JOIN public.sales_returns r ON r.id = a.return_id AND r.organization_id = a.organization_id
            WHERE a.organization_id = p_org AND a.payment_id = p.id), '[]'::jsonb))
    FROM public.payments p
    JOIN public.branches b ON b.id = p.branch_id AND b.organization_id = p.organization_id
    WHERE p.organization_id = p_org AND p.id = p_payment_id
$$;

-- Rule 4: every statement row of the customer, unsorted. ord breaks ties inside one day and one
-- transaction (a sale before its payments, a contract after its sale, a fee before its waiver).
CREATE FUNCTION app.customer_statement_rows(p_org uuid, p_customer_id uuid)
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
    -- TODO(N05): write-offs and early-settlement discounts (contract_changes) become credit rows.
    SELECT COALESCE(s.business_date, (c.created_at AT TIME ZONE (SELECT o.timezone FROM o))::date),
           c.created_at, 2, 'contract', c.id, c.number, s.number, NULL,
           app.customer_contract_total(p_org, c.id) - CASE WHEN c.sale_id IS NULL THEN 0 ELSE c.financed_amount END, 0
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
    -- returns, voids and exchanges of the customer's sales
    SELECT r.business_date, r.created_at, 4, 'return', r.id, r.number, r.kind::text, NULL, 0, r.total
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
$$;

-- {id, full_name, status, phones} of a customer of the shop; NULL when there is none.
CREATE FUNCTION app.customer_account_head(p_org uuid, p_customer_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object('id', c.id, 'full_name', c.full_name, 'status', c.status,
                              'phones', to_jsonb(COALESCE(c.phones, ARRAY[]::text[])))
    FROM public.customers c WHERE c.organization_id = p_org AND c.id = p_customer_id
$$;

-- 2. Reads (rule 1) --------------------------------------------------------------------------------

CREATE FUNCTION public.get_customer_account(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_head jsonb; v_balance jsonb; v_x record;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    v_head := app.customer_account_head(v_org, p_customer_id);
    IF v_head IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;

    SELECT x.credit_limit, x.available_credit, x.store_credit INTO v_x
    FROM public.v_customer_exposure x WHERE x.organization_id = v_org AND x.customer_id = p_customer_id;
    v_balance := app.customer_open_balance(v_org, p_customer_id) || jsonb_build_object(
        'store_credit', COALESCE(v_x.store_credit, 0)::numeric(18,2)::text,
        'credit_limit', COALESCE(v_x.credit_limit, 0)::numeric(18,2)::text,
        'available', GREATEST(COALESCE(v_x.available_credit, 0), 0)::numeric(18,2)::text);

    RETURN jsonb_build_object(
        'customer', v_head,
        'balance', v_balance,
        'overdue', app.customer_overdue_json(v_org, p_customer_id),
        'totals', (
            SELECT jsonb_build_object(
                'purchases_count', (SELECT count(*) FROM public.sales s
                                    WHERE s.organization_id = v_org AND s.customer_id = p_customer_id
                                      AND NOT EXISTS (SELECT 1 FROM public.sales_returns r
                                                      WHERE r.sale_id = s.id AND r.kind = 'void')),
                'purchases_total', (SELECT COALESCE(sum(s.total), 0)::numeric(18,2)::text FROM public.sales s
                                    WHERE s.organization_id = v_org AND s.customer_id = p_customer_id
                                      AND NOT EXISTS (SELECT 1 FROM public.sales_returns r
                                                      WHERE r.sale_id = s.id AND r.kind = 'void')),
                'returns_count', (SELECT count(*) FROM public.sales_returns r
                                  JOIN public.sales s ON s.id = r.sale_id AND s.organization_id = r.organization_id
                                  WHERE r.organization_id = v_org AND s.customer_id = p_customer_id),
                'returns_total', (SELECT COALESCE(sum(r.total), 0)::numeric(18,2)::text FROM public.sales_returns r
                                  JOIN public.sales s ON s.id = r.sale_id AND s.organization_id = r.organization_id
                                  WHERE r.organization_id = v_org AND s.customer_id = p_customer_id),
                'payments_in', COALESCE(sum(p.amount) FILTER (WHERE p.direction = 'in'), 0)::numeric(18,2)::text,
                'payments_out', COALESCE(sum(p.amount) FILTER (WHERE p.direction = 'out'), 0)::numeric(18,2)::text,
                'last_purchase_at', (SELECT max(s.issued_at) FROM public.sales s
                                     WHERE s.organization_id = v_org AND s.customer_id = p_customer_id),
                'last_payment_at', max(p.paid_at) FILTER (WHERE p.direction = 'in'))
            FROM public.payments p
            WHERE p.organization_id = v_org AND p.customer_id = p_customer_id AND p.method <> 'store_credit'
              AND p.reverses_payment_id IS NULL
              AND NOT EXISTS (SELECT 1 FROM public.payments rv WHERE rv.reverses_payment_id = p.id)),
        'contracts', COALESCE((
            SELECT jsonb_agg(app.customer_contract_json(v_org, c.id) ORDER BY c.created_at DESC, c.number DESC)
            FROM public.contracts c WHERE c.organization_id = v_org AND c.customer_id = p_customer_id), '[]'::jsonb),
        'recent_payments', COALESCE((
            SELECT jsonb_agg(app.customer_payment_json(v_org, x.id) ORDER BY x.business_date DESC, x.paid_at DESC, x.number DESC)
            FROM (SELECT p.id, p.business_date, p.paid_at, p.number FROM public.payments p
                  WHERE p.organization_id = v_org AND p.customer_id = p_customer_id AND p.reverses_payment_id IS NULL
                    AND NOT EXISTS (SELECT 1 FROM public.payments rv WHERE rv.reverses_payment_id = p.id)
                  ORDER BY p.business_date DESC, p.paid_at DESC, p.number DESC LIMIT 10) x), '[]'::jsonb),
        'recent_returns', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', x.id, 'number', x.number, 'kind', x.kind,
                                                'refund_method', x.refund_method, 'total', x.total::text,
                                                'sale_id', x.sale_id, 'sale_number', x.sale_number,
                                                'business_date', x.business_date, 'created_at', x.created_at)
                             ORDER BY x.business_date DESC, x.created_at DESC, x.number DESC)
            FROM (SELECT r.*, s.number AS sale_number FROM public.sales_returns r
                  JOIN public.sales s ON s.id = r.sale_id AND s.organization_id = r.organization_id
                  WHERE r.organization_id = v_org AND s.customer_id = p_customer_id
                  ORDER BY r.business_date DESC, r.created_at DESC, r.number DESC LIMIT 10) x), '[]'::jsonb),
        'documents_count', (
            SELECT count(*) FROM public.files f
            WHERE f.organization_id = v_org
              AND ((f.entity_type = 'customer' AND f.entity_id = p_customer_id)
                   OR (f.entity_type = 'contract' AND f.entity_id IN (
                        SELECT c.id FROM public.contracts c
                        WHERE c.organization_id = v_org AND c.customer_id = p_customer_id)))));
END;
$$;

CREATE FUNCTION public.get_customer_contract_schedule(p_customer_id uuid, p_contract_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    IF app.customer_account_head(v_org, p_customer_id) IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.contracts c
                   WHERE c.organization_id = v_org AND c.id = p_contract_id AND c.customer_id = p_customer_id) THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN jsonb_build_object(
        'contract', app.customer_contract_json(v_org, p_contract_id),
        'lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', ls.schedule_line_id, 'version', ls.version, 'seq', ls.seq, 'due_date', ls.due_date,
                'principal', ls.principal::text, 'profit', ls.profit::text, 'amount', ls.amount::text,
                'paid', ls.paid::text, 'remaining', GREATEST(ls.remaining, 0)::numeric(18,2)::text,
                'fees_due', ls.fees_due::text,
                'days_late', CASE WHEN ls.status = 'overdue' THEN ls.days_late ELSE 0 END,
                'status', ls.status, 'superseded', ls.superseded)
                ORDER BY ls.superseded, ls.version DESC, ls.seq)
            FROM public.v_schedule_line_status ls
            WHERE ls.organization_id = v_org AND ls.contract_id = p_contract_id), '[]'::jsonb),
        'charges', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', ch.id, 'schedule_line_id', ch.schedule_line_id, 'seq', sl.seq, 'kind', ch.kind,
                'assessed_on', ch.assessed_on, 'amount', ch.amount::text,
                'waived', COALESCE(w.waived, 0)::numeric(18,2)::text,
                'paid', COALESCE(pd.paid, 0)::numeric(18,2)::text,
                'due', (ch.amount - COALESCE(w.waived, 0) - COALESCE(pd.paid, 0))::numeric(18,2)::text)
                ORDER BY ch.assessed_on, sl.seq, ch.id)
            FROM public.charges ch
            JOIN public.schedule_lines sl ON sl.id = ch.schedule_line_id AND sl.organization_id = ch.organization_id
            LEFT JOIN (SELECT cw.charge_id, sum(cw.amount) AS waived FROM public.charge_waivers cw
                       WHERE cw.organization_id = v_org GROUP BY cw.charge_id) w ON w.charge_id = ch.id
            LEFT JOIN (SELECT ea.charge_id, sum(ea.amount) AS paid FROM public.v_effective_allocations ea
                       WHERE ea.organization_id = v_org AND ea.charge_id IS NOT NULL GROUP BY ea.charge_id) pd
                   ON pd.charge_id = ch.id
            WHERE ch.organization_id = v_org AND ch.contract_id = p_contract_id), '[]'::jsonb));
END;
$$;

-- Rule 4. Shop-wide (every branch), dates in the shop's timezone; at most three years at a time.
CREATE FUNCTION public.customer_statement(p_customer_id uuid, p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_head jsonb; v_opening numeric(18,2); v_result jsonb;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    v_head := app.customer_account_head(v_org, p_customer_id);
    IF v_head IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF p_from > p_to THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: from' USING ERRCODE = 'P0001';
    END IF;
    IF p_to > (p_from + interval '3 years')::date THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: to' USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(sum(s.debit - s.credit), 0) INTO v_opening
    FROM app.customer_statement_rows(v_org, p_customer_id) s WHERE p_from IS NOT NULL AND s.d < p_from;

    WITH shown AS (
        SELECT s.*, v_opening + sum(s.debit - s.credit)
                   OVER (ORDER BY s.d, s.created_at, s.ord, s.number, s.id ROWS UNBOUNDED PRECEDING) AS balance
        FROM app.customer_statement_rows(v_org, p_customer_id) s
        WHERE (p_from IS NULL OR s.d >= p_from) AND (p_to IS NULL OR s.d <= p_to)
    )
    SELECT jsonb_build_object(
        'customer', v_head,
        'from', p_from,
        'to', p_to,
        'opening_balance', v_opening::text,
        'closing_balance', (v_opening + COALESCE((SELECT sum(x.debit - x.credit) FROM shown x), 0))::numeric(18,2)::text,
        'totals', jsonb_build_object(
            'debit', COALESCE((SELECT sum(x.debit) FROM shown x), 0)::numeric(18,2)::text,
            'credit', COALESCE((SELECT sum(x.credit) FROM shown x), 0)::numeric(18,2)::text),
        'rows', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'date', x.d, 'kind', x.kind, 'document_id', x.id, 'number', x.number,
                'detail', x.detail, 'reference', x.reference,
                'debit', x.debit::numeric(18,2)::text, 'credit', x.credit::numeric(18,2)::text,
                'balance', x.balance::numeric(18,2)::text)
                ORDER BY x.d, x.created_at, x.ord, x.number, x.id)
            FROM shown x), '[]'::jsonb))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- 3. Grants ----------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.customer_contract_total(uuid, uuid), app.customer_open_balance(uuid, uuid),
    app.customer_overdue_json(uuid, uuid), app.customer_contract_json(uuid, uuid),
    app.customer_payment_json(uuid, uuid), app.customer_statement_rows(uuid, uuid),
    app.customer_account_head(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_customer_account(uuid), public.get_customer_contract_schedule(uuid, uuid),
    public.customer_statement(uuid, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_customer_account(uuid), public.get_customer_contract_schedule(uuid, uuid),
    public.customer_statement(uuid, date, date) TO authenticated;
