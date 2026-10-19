-- Live review 19 Oct, bug 3: the shift detail's Document column was empty for sales, expenses and
-- collections because app.shift_json only resolved cash_transfer numbers, and a sale's number showed
-- under Note instead (S02 and K03 store the document number in cash_movements.note).
-- Same signature and body as 20261014210000_ec147_shift_device_check.sql; only the movements change:
-- source_number now also covers sale, expense, payment and supplier_payment (each scoped to p_org),
-- and a note that only repeats that number comes back NULL so the number is not shown twice.

CREATE OR REPLACE FUNCTION app.shift_json(p_org uuid, p_id uuid, p_with_movements boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', s.id, 'number', s.number, 'branch_id', s.branch_id, 'device_id', s.device_id,
        'device_name', d.name, 'device_revoked', (d.id IS NULL OR NOT d.is_active OR d.archived_at IS NOT NULL OR d.token_hash IS NULL), 'employee_id', s.employee_id, 'employee_name', e.full_name,
        'drawer_account_id', s.drawer_account_id, 'status', s.status,
        'opening_float', s.opening_float::text, 'opened_at', s.opened_at, 'closed_at', s.closed_at,
        'closed_by_name', ce.full_name,
        'expected_cash', CASE WHEN s.status = 'open' THEN app.shift_expected(p_org, s)
                              ELSE s.expected_cash END::numeric(18,2)::text,
        'counted_cash', s.counted_cash::text,
        'difference', (s.counted_cash - s.expected_cash)::numeric(18,2)::text,
        'count_breakdown', s.count_breakdown, 'difference_reason', s.difference_reason,
        'sales_total', COALESCE((SELECT sum(x.total) FROM public.sales x
                                 WHERE x.organization_id = p_org AND x.shift_id = s.id), 0)::numeric(18,2)::text,
        'payment_totals', (
            SELECT jsonb_build_object(
                'cash', COALESCE(sum(p.amount) FILTER (WHERE p.method = 'cash'), 0)::numeric(18,2)::text,
                'bank_transfer', COALESCE(sum(p.amount) FILTER (WHERE p.method = 'bank_transfer'), 0)::numeric(18,2)::text,
                'store_credit', COALESCE(sum(p.amount) FILTER (WHERE p.method = 'store_credit'), 0)::numeric(18,2)::text)
            FROM public.payments p
            WHERE p.organization_id = p_org AND p.shift_id = s.id AND p.direction = 'in'))
        || CASE WHEN p_with_movements THEN jsonb_build_object('movements', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', m.id, 'created_at', m.created_at, 'type', m.type, 'amount', m.amount::text,
                'source_type', m.source_type,
                'source_number', n.number,
                'note', CASE WHEN m.note = n.number THEN NULL ELSE m.note END)
                ORDER BY m.created_at, m.id)
            FROM public.cash_movements m
            CROSS JOIN LATERAL (SELECT CASE m.source_type
                WHEN 'cash_transfer' THEN (SELECT t.number FROM public.cash_transfers t
                                           WHERE t.id = m.source_id AND t.organization_id = p_org)
                WHEN 'sale' THEN (SELECT x.number FROM public.sales x
                                  WHERE x.id = m.source_id AND x.organization_id = p_org)
                WHEN 'expense' THEN (SELECT x.number FROM public.expenses x
                                     WHERE x.id = m.source_id AND x.organization_id = p_org)
                WHEN 'payment' THEN (SELECT x.number FROM public.payments x
                                     WHERE x.id = m.source_id AND x.organization_id = p_org)
                WHEN 'supplier_payment' THEN (SELECT x.number FROM public.supplier_payments x
                                              WHERE x.id = m.source_id AND x.organization_id = p_org)
                END AS number) n
            WHERE m.organization_id = p_org AND m.shift_id = s.id AND m.cash_account_id = s.drawer_account_id),
            '[]'::jsonb))
           ELSE '{}'::jsonb END
    FROM public.shifts s
    JOIN public.employees e ON e.id = s.employee_id AND e.organization_id = s.organization_id
    LEFT JOIN public.employees ce ON ce.id = s.closed_by AND ce.organization_id = s.organization_id
    LEFT JOIN public.devices d ON d.id = s.device_id AND d.organization_id = s.organization_id
    WHERE s.organization_id = p_org AND s.id = p_id
$$;
REVOKE ALL ON FUNCTION app.shift_json(uuid,uuid,boolean) FROM PUBLIC, anon, authenticated;
