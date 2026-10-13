-- S07: branch-scoped history and an immutable, full reversal of a same-day sale.
CREATE INDEX IF NOT EXISTS sales_org_business_date_idx
    ON public.sales (organization_id, business_date DESC);

CREATE FUNCTION public.search_sales(
    p_query text DEFAULT NULL, p_branch_id uuid DEFAULT NULL,
    p_customer_id uuid DEFAULT NULL, p_cashier_id uuid DEFAULT NULL,
    p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_status text DEFAULT NULL,
    p_limit integer DEFAULT 20, p_offset integer DEFAULT 0)
RETURNS TABLE (id uuid, number text, issued_at timestamptz, business_date date,
    branch jsonb, cashier jsonb, customer jsonb, total text, status text,
    items_count bigint, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE o uuid := app.current_org_id();
BEGIN
    IF NOT (app.has_permission('sale.create') OR app.has_permission('report.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: sale.create or report.view' USING ERRCODE='42501';
    END IF;
    BEGIN
        IF app.has_permission('sale.create') THEN PERFORM app.require_permission('sale.create');
        ELSE PERFORM app.require_permission('report.view'); END IF;
    EXCEPTION WHEN insufficient_privilege THEN
        -- P05 permits reads after expiry. The key was verified above; writes never use this exception.
        IF SQLERRM <> 'SUBSCRIPTION_EXPIRED' THEN RAISE; END IF;
    END;
    IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR p_offset IS NULL OR p_offset < 0
       OR p_from > p_to OR (p_status IS NOT NULL AND p_status NOT IN ('completed','voided','returned','partially_returned')) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001';
    END IF;
    RETURN QUERY
    WITH rows AS (
        SELECT s.id, s.number, s.issued_at, s.business_date,
            jsonb_build_object('id',b.id,'name',b.name) AS branch,
            jsonb_build_object('id',e.id,'name',e.full_name) AS cashier,
            CASE WHEN c.id IS NULL THEN NULL ELSE jsonb_build_object('id',c.id,'name',c.full_name) END AS customer,
            s.total::text AS total,
            CASE WHEN EXISTS(SELECT 1 FROM public.sales_returns r WHERE r.sale_id=s.id AND r.kind='void') THEN 'voided'
                WHEN EXISTS(SELECT 1 FROM public.sales_returns r WHERE r.sale_id=s.id) AND COALESCE((SELECT sum(r.total) FROM public.sales_returns r WHERE r.sale_id=s.id),0)>=s.total THEN 'returned'
                WHEN EXISTS(SELECT 1 FROM public.sales_returns r WHERE r.sale_id=s.id) THEN 'partially_returned'
                ELSE 'completed' END AS status,
            (SELECT sum(l.quantity) FROM public.sale_lines l WHERE l.sale_id=s.id) AS items_count
        FROM public.sales s
        JOIN public.branches b ON b.id=s.branch_id AND b.organization_id=o
        LEFT JOIN public.employees e ON e.id=s.created_by AND e.organization_id=o
        LEFT JOIN public.customers c ON c.id=s.customer_id AND c.organization_id=o
        WHERE s.organization_id=o AND app.has_branch_access(s.branch_id)
            AND (p_branch_id IS NULL OR s.branch_id=p_branch_id)
            AND (p_customer_id IS NULL OR s.customer_id=p_customer_id)
            AND (p_cashier_id IS NULL OR s.created_by=p_cashier_id)
            AND (p_from IS NULL OR s.business_date>=p_from)
            AND (p_to IS NULL OR s.business_date<=p_to)
            AND (NULLIF(btrim(p_query),'') IS NULL OR starts_with(lower(s.number),lower(btrim(p_query)))
                OR EXISTS(SELECT 1 FROM public.sale_lines l JOIN public.units u ON u.id=l.unit_id AND u.organization_id=o
                    WHERE l.sale_id=s.id AND u.serial=btrim(p_query))
                OR EXISTS(SELECT 1 FROM unnest(c.phones) ph WHERE app.normalize_customer_phone(ph)=app.normalize_customer_phone(p_query)))
    )
    SELECT r.id,r.number,r.issued_at,r.business_date,r.branch,r.cashier,r.customer,r.total,r.status,
        r.items_count,count(*) OVER()
    FROM rows r WHERE p_status IS NULL OR r.status=p_status
    ORDER BY r.issued_at DESC,r.id DESC LIMIT p_limit OFFSET p_offset;
END $$;
REVOKE ALL ON FUNCTION public.search_sales(text,uuid,uuid,uuid,date,date,text,integer,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.search_sales(text,uuid,uuid,uuid,date,date,text,integer,integer) TO authenticated;

CREATE FUNCTION public.get_sale_details(p_sale_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE o uuid:=app.current_org_id(); s public.sales; v_status text; v_block text; v_returns jsonb;
BEGIN
    IF NOT (app.has_permission('sale.create') OR app.has_permission('report.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: sale.create or report.view' USING ERRCODE='42501';
    END IF;
    BEGIN
        IF app.has_permission('sale.create') THEN PERFORM app.require_permission('sale.create');
        ELSE PERFORM app.require_permission('report.view'); END IF;
    EXCEPTION WHEN insufficient_privilege THEN
        -- P05 permits reads after expiry. The key was verified above; writes never use this exception.
        IF SQLERRM <> 'SUBSCRIPTION_EXPIRED' THEN RAISE; END IF;
    END;
    SELECT * INTO s FROM public.sales WHERE id=p_sale_id AND organization_id=o;
    IF NOT FOUND OR NOT app.has_branch_access(s.branch_id) THEN
        RAISE EXCEPTION 'SALE_NOT_FOUND' USING ERRCODE='P0001'; END IF;
    SELECT CASE WHEN bool_or(r.kind='void') THEN 'voided'
        WHEN sum(r.total)>=s.total THEN 'returned'
        WHEN count(*)>0 THEN 'partially_returned' ELSE 'completed' END,
        COALESCE(jsonb_agg(jsonb_build_object('id',r.id,'number',r.number,'kind',r.kind,'total',r.total::text,
            'reason',r.reason,'by',e.full_name,'at',r.created_at) ORDER BY r.created_at,r.id),'[]')
    INTO v_status,v_returns FROM public.sales_returns r
    LEFT JOIN public.employees e ON e.id=r.created_by AND e.organization_id=o WHERE r.sale_id=s.id;
    v_block:=CASE
        WHEN NOT app.has_permission('sale.void') THEN 'PERMISSION_DENIED'
        WHEN app.org_is_expired(o) THEN 'SUBSCRIPTION_EXPIRED'
        WHEN v_status='voided' THEN 'ALREADY_VOIDED'
        WHEN s.business_date<>app.org_today(o) THEN 'VOID_NOT_SAME_DAY'
        WHEN NOT EXISTS(SELECT 1 FROM public.shifts sh WHERE sh.id=s.shift_id AND sh.status='open') THEN 'VOID_SHIFT_CLOSED'
        WHEN jsonb_array_length(v_returns)>0 THEN 'VOID_HAS_RETURNS'
        WHEN EXISTS(SELECT 1 FROM public.warranty_claims w JOIN public.sale_lines l ON l.id=w.sale_line_id WHERE l.sale_id=s.id) THEN 'VOID_HAS_CLAIMS'
        WHEN EXISTS(SELECT 1 FROM public.contracts c WHERE c.sale_id=s.id) THEN 'VOID_HAS_CONTRACT'
        WHEN EXISTS(SELECT 1 FROM public.fiscal_submissions f WHERE f.sale_id=s.id AND f.eta_uuid IS NOT NULL) THEN 'VOID_FISCALIZED'
        ELSE NULL END;
    RETURN app.sale_json(o,s.id)||jsonb_build_object('status',v_status,'voidable',v_block IS NULL,
        'void_block_reason',v_block,'returns',v_returns,
        'branch',(SELECT jsonb_build_object('id',b.id,'name',b.name) FROM public.branches b WHERE b.id=s.branch_id AND b.organization_id=o),
        'cashier',(SELECT jsonb_build_object('id',e.id,'name',e.full_name) FROM public.employees e WHERE e.id=s.created_by AND e.organization_id=o),
        'customer',(SELECT jsonb_build_object('id',c.id,'name',c.full_name) FROM public.customers c WHERE c.id=s.customer_id AND c.organization_id=o));
END $$;
REVOKE ALL ON FUNCTION public.get_sale_details(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_sale_details(uuid) TO authenticated;

CREATE FUNCTION public.void_sale(p_sale_id uuid,p_reason text,p_idempotency_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE emp uuid:=app.require_permission('sale.void'); o uuid:=app.current_org_id();
    s public.sales; sh public.shifts; v_return public.sales_returns; l public.sale_lines;
    m public.stock_movements; cm public.cash_movements; pay public.payments;
    v_line uuid; v_payment uuid; v_method public.refund_method;
BEGIN
    PERFORM app.lock_idempotency_key(o,p_idempotency_key);
    IF p_idempotency_key LIKE 'system:%' THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
    SELECT * INTO s FROM public.sales WHERE id=p_sale_id AND organization_id=o FOR UPDATE;
    IF NOT FOUND OR NOT app.has_branch_access(s.branch_id) THEN RAISE EXCEPTION 'SALE_NOT_FOUND' USING ERRCODE='P0001'; END IF;
    PERFORM app.require_branch_access(s.branch_id);
    SELECT * INTO v_return FROM public.sales_returns WHERE organization_id=o AND idempotency_key=p_idempotency_key;
    IF FOUND THEN
        IF v_return.sale_id<>s.id OR v_return.kind<>'void' THEN RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='P0001'; END IF;
        RETURN jsonb_build_object('return_id',v_return.id,'number',v_return.number);
    END IF;
    SELECT * INTO sh FROM public.shifts WHERE id=s.shift_id AND organization_id=o FOR UPDATE;
    PERFORM 1 FROM public.sale_lines sl WHERE sl.sale_id=s.id ORDER BY sl.product_id,sl.id FOR UPDATE;
    PERFORM 1 FROM public.stock_movements sm WHERE sm.organization_id=o AND sm.source_type='sale' AND sm.source_id=s.id
        ORDER BY sm.product_id,sm.id FOR UPDATE;
    PERFORM 1 FROM public.stock_levels sl WHERE sl.organization_id=o AND sl.branch_id=s.branch_id
        AND sl.product_id IN(SELECT x.product_id FROM public.sale_lines x WHERE x.sale_id=s.id)
        ORDER BY sl.product_id,sl.stock_state FOR UPDATE;
    PERFORM 1 FROM public.fiscal_submissions f WHERE f.sale_id=s.id AND f.organization_id=o FOR UPDATE;
    IF EXISTS(SELECT 1 FROM public.sales_returns r WHERE r.sale_id=s.id AND r.kind='void') THEN RAISE EXCEPTION 'ALREADY_VOIDED' USING ERRCODE='P0001'; END IF;
    IF s.business_date<>app.org_today(o) THEN RAISE EXCEPTION 'VOID_NOT_SAME_DAY' USING ERRCODE='P0001'; END IF;
    IF sh.id IS NULL OR sh.status<>'open' THEN RAISE EXCEPTION 'VOID_SHIFT_CLOSED' USING ERRCODE='P0001'; END IF;
    IF EXISTS(SELECT 1 FROM public.sales_returns r WHERE r.sale_id=s.id) THEN RAISE EXCEPTION 'VOID_HAS_RETURNS' USING ERRCODE='P0001'; END IF;
    IF EXISTS(SELECT 1 FROM public.warranty_claims w JOIN public.sale_lines sl ON sl.id=w.sale_line_id WHERE sl.sale_id=s.id) THEN RAISE EXCEPTION 'VOID_HAS_CLAIMS' USING ERRCODE='P0001'; END IF;
    IF EXISTS(SELECT 1 FROM public.contracts c WHERE c.sale_id=s.id) THEN RAISE EXCEPTION 'VOID_HAS_CONTRACT' USING ERRCODE='P0001'; END IF;
    IF EXISTS(SELECT 1 FROM public.fiscal_submissions f WHERE f.sale_id=s.id AND f.eta_uuid IS NOT NULL) THEN RAISE EXCEPTION 'VOID_FISCALIZED' USING ERRCODE='P0001'; END IF;
    IF p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 200 THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE='P0001'; END IF;
    SELECT p.method::text::public.refund_method INTO v_method FROM public.payments p
        JOIN public.payment_allocations a ON a.payment_id=p.id WHERE a.sale_id=s.id AND p.direction='in'
        ORDER BY p.amount DESC,p.id LIMIT 1;
    INSERT INTO public.sales_returns(organization_id,number,sale_id,branch_id,shift_id,kind,refund_method,
        subtotal,tax_total,total,reason,business_date,idempotency_key,created_by)
    VALUES(o,app.next_document_number(o,s.branch_id,'sales_return'),s.id,s.branch_id,s.shift_id,'void',v_method,
        s.subtotal,s.tax_total,s.total,btrim(p_reason),app.org_today(o),p_idempotency_key,emp) RETURNING * INTO v_return;
    FOR l IN SELECT * FROM public.sale_lines WHERE sale_id=s.id ORDER BY product_id,id LOOP
        INSERT INTO public.sales_return_lines(organization_id,return_id,sale_line_id,unit_id,quantity,condition,refund_amount,tax_amount,unit_cost,created_by)
        VALUES(o,v_return.id,l.id,l.unit_id,l.quantity,'resellable',l.line_total,l.tax_amount,l.unit_cost,emp) RETURNING id INTO v_line;
        FOR m IN SELECT * FROM public.stock_movements WHERE organization_id=o AND source_type='sale' AND source_id=s.id AND source_line_id=l.id AND type='sale_out' ORDER BY id LOOP
            INSERT INTO public.stock_movements(organization_id,product_id,branch_id,unit_id,quantity,type,stock_state,unit_cost,source_type,source_id,source_line_id,reverses_movement_id,business_date,created_by)
            VALUES(o,m.product_id,m.branch_id,m.unit_id,-m.quantity,'sale_return_in',m.stock_state,m.unit_cost,'sales_return',v_return.id,v_line,m.id,app.org_today(o),emp);
        END LOOP;
    END LOOP;
    FOR pay IN SELECT p.* FROM public.payments p JOIN public.payment_allocations a ON a.payment_id=p.id
        WHERE a.sale_id=s.id AND p.organization_id=o AND p.direction='in' ORDER BY p.cash_account_id NULLS LAST,p.id LOOP
        INSERT INTO public.payments(organization_id,number,branch_id,direction,method,amount,customer_id,cash_account_id,shift_id,reference,received_by,business_date,reverses_payment_id,reason,idempotency_key,created_by)
        VALUES(o,app.next_document_number(o,s.branch_id,'payment'),s.branch_id,'out',pay.method,pay.amount,pay.customer_id,pay.cash_account_id,pay.shift_id,pay.reference,emp,app.org_today(o),pay.id,btrim(p_reason),'system:void:'||v_return.id||':'||pay.id,emp)
        RETURNING id INTO v_payment;
        INSERT INTO public.payment_allocations(organization_id,payment_id,amount,return_id,created_by) VALUES(o,v_payment,pay.amount,v_return.id,emp);
        IF pay.method='store_credit' THEN
            INSERT INTO public.store_credit_movements(organization_id,customer_id,amount,source_type,source_id,branch_id,business_date,created_by)
            VALUES(o,pay.customer_id,pay.amount,'sales_return',v_return.id,s.branch_id,app.org_today(o),emp);
        END IF;
    END LOOP;
    FOR cm IN SELECT * FROM public.cash_movements WHERE organization_id=o AND source_type='sale' AND source_id=s.id AND type='sale' ORDER BY cash_account_id,id LOOP
        INSERT INTO public.cash_movements(organization_id,cash_account_id,branch_id,shift_id,amount,type,source_type,source_id,reverses_movement_id,note,business_date,created_by)
        VALUES(o,cm.cash_account_id,cm.branch_id,cm.shift_id,-cm.amount,'refund','sales_return',v_return.id,cm.id,btrim(p_reason),app.org_today(o),emp);
    END LOOP;
    UPDATE public.fiscal_submissions SET status='cancelled',updated_at=now() WHERE organization_id=o AND sale_id=s.id AND eta_uuid IS NULL;
    PERFORM app.write_audit('sale.voided','sale',s.id,p_after=>jsonb_build_object('return_id',v_return.id,'number',v_return.number,'total',s.total::text),p_reason=>btrim(p_reason),p_severity=>'warning');
    RETURN jsonb_build_object('return_id',v_return.id,'number',v_return.number);
END $$;
REVOKE ALL ON FUNCTION public.void_sale(uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.void_sale(uuid,text,text) TO authenticated;
