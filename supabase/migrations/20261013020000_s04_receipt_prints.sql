-- S04 (D68): a printed sale receipt is logged. The audit log is the print log: the first print of a
-- sale is the original, every later one a copy. No table and no column (a sale never changes).
CREATE FUNCTION public.record_sale_receipt_print(p_sale_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE o uuid:=app.current_org_id(); s public.sales; n integer;
BEGIN
    IF NOT (app.has_permission('sale.create') OR app.has_permission('report.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: sale.create or report.view' USING ERRCODE='42501';
    END IF;
    -- A write: an expired (read-only) shop is refused here; the client then prints a copy.
    IF app.has_permission('sale.create') THEN PERFORM app.require_permission('sale.create');
    ELSE PERFORM app.require_permission('report.view'); END IF;
    -- The sale's row lock gives two tills printing the same sale two different numbers.
    SELECT * INTO s FROM public.sales WHERE id=p_sale_id AND organization_id=o FOR UPDATE;
    IF NOT FOUND OR NOT app.has_branch_access(s.branch_id) THEN
        RAISE EXCEPTION 'SALE_NOT_FOUND' USING ERRCODE='P0001'; END IF;
    SELECT count(*)+1 INTO n FROM public.audit_log a
        WHERE a.organization_id=o AND a.entity_type='sale' AND a.entity_id=s.id AND a.action='sale.receipt_printed';
    PERFORM app.write_audit('sale.receipt_printed','sale',s.id,
        p_after=>jsonb_build_object('number',s.number,'print_no',n,'copy',n>1),p_branch_id=>s.branch_id);
    RETURN jsonb_build_object('print_no',n,'copy',n>1);
END $$;
REVOKE ALL ON FUNCTION public.record_sale_receipt_print(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.record_sale_receipt_print(uuid) TO authenticated;

-- S07's details also answer how many times the receipt was printed (0: the next print is the original).
CREATE OR REPLACE FUNCTION public.get_sale_details(p_sale_id uuid) RETURNS jsonb
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
    RETURN app.sale_json(o,s.id)||jsonb_build_object('receipt_prints',(SELECT count(*) FROM public.audit_log a WHERE a.organization_id=o AND a.entity_type='sale' AND a.entity_id=s.id AND a.action='sale.receipt_printed'),'status',v_status,'voidable',v_block IS NULL,
        'void_block_reason',v_block,'returns',v_returns,
        'branch',(SELECT jsonb_build_object('id',b.id,'name',b.name) FROM public.branches b WHERE b.id=s.branch_id AND b.organization_id=o),
        'cashier',(SELECT jsonb_build_object('id',e.id,'name',e.full_name) FROM public.employees e WHERE e.id=s.created_by AND e.organization_id=o),
        'customer',(SELECT jsonb_build_object('id',c.id,'name',c.full_name) FROM public.customers c WHERE c.id=s.customer_id AND c.organization_id=o));
END $$;
