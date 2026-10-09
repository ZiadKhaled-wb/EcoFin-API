-- =============================================================================
-- U06 · Purchase approval by amount (EC-58, D55)
--
-- Above the shop's purchase approval threshold (org_settings.purchase_approval_threshold, P03;
-- NULL = no approval step), only the OWNER approves or rejects a purchase invoice. A non-owner's
-- approve of a draft whose total (VAT included, after U02's recompute) is STRICTLY greater than
-- the threshold sends it to the owner instead of posting: the invoice becomes pending_approval,
-- one approvals row (kind purchase_invoice, status pending) is written and audited as
-- purchase_invoice.approval_requested. The owner approves a pending invoice with a note (posted
-- exactly as U02 does) or rejects it with a reason; the approval row records the decision.
-- A pending invoice stays pending if the threshold changes later. No new permission key.
-- Numbered after the newest migration on main (D39). No table or column changes.
-- =============================================================================

-- 1. One pending approval per invoice ---------------------------------------------------------------

CREATE UNIQUE INDEX approvals_one_pending_purchase_key ON public.approvals (organization_id, entity_id)
    WHERE kind = 'purchase_invoice' AND status = 'pending';

-- 2. JSON ------------------------------------------------------------------------------------------

-- An approval in the contract's PurchaseApproval shape; the threshold is the one at request time.
CREATE FUNCTION app.purchase_approval_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', a.id, 'status', a.status, 'amount', a.amount::text,
        'threshold', a.payload ->> 'threshold',
        'requested_by_name', re.full_name, 'requested_at', a.created_at,
        'decided_by_name', de.full_name, 'decided_at', a.decided_at, 'note', a.decision_note)
    FROM public.approvals a
    LEFT JOIN public.employees re ON re.id = a.requested_by AND re.organization_id = a.organization_id
    LEFT JOIN public.employees de ON de.id = a.decided_by AND de.organization_id = a.organization_id
    WHERE a.organization_id = p_org AND a.id = p_id
$$;

-- U02's invoice JSON plus the latest approval (same signature).
CREATE OR REPLACE FUNCTION app.purchase_invoice_json(p_org uuid, p_id uuid, p_with_lines boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', i.id, 'number', i.number, 'supplier_id', i.supplier_id, 'supplier_name', s.name,
        'branch_id', i.branch_id, 'supplier_invoice_no', i.supplier_invoice_no,
        'invoice_date', i.invoice_date, 'status', i.status,
        'subtotal', i.subtotal::text, 'tax_total', i.tax_total::text, 'total', i.total::text,
        'outstanding', CASE WHEN i.status = 'approved' THEN COALESCE((
            SELECT b.outstanding FROM public.v_purchase_invoice_balances b
            WHERE b.organization_id = p_org AND b.purchase_invoice_id = i.id), i.total)::numeric(18,2)::text END,
        'approved_by_name', ae.full_name, 'approved_at', i.approved_at,
        'rejected_reason', i.rejected_reason,
        'created_by_name', ce.full_name, 'created_at', i.created_at, 'updated_at', i.updated_at,
        -- U06: the invoice's latest approval (pending, approved, rejected), or null.
        'approval', (SELECT app.purchase_approval_json(p_org, a.id) FROM public.approvals a
                     WHERE a.organization_id = p_org AND a.kind = 'purchase_invoice' AND a.entity_id = i.id
                     ORDER BY a.created_at DESC, a.id DESC LIMIT 1))
        || CASE WHEN p_with_lines THEN jsonb_build_object('lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', l.id, 'product_id', l.product_id, 'name_ar', p.name_ar, 'name_en', p.name_en,
                'sku', p.sku, 'is_serialized', p.is_serialized, 'quantity', l.quantity,
                'unit_cost', l.unit_cost::text, 'tax_class_id', l.tax_class_id, 'tax_rate', tc.rate::text,
                'tax_amount', l.tax_amount::text,
                'net', (l.quantity * l.unit_cost)::numeric(18,2)::text,
                'line_total', l.line_total::text, 'serials', to_jsonb(l.serials),
                'unit_ids', COALESCE((SELECT jsonb_agg(u.id ORDER BY u.serial) FROM public.units u
                                      WHERE u.organization_id = p_org AND u.purchase_invoice_line_id = l.id),
                                     '[]'::jsonb))
                ORDER BY p.name_ar, l.product_id)
            FROM public.purchase_invoice_lines l
            JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
            JOIN public.tax_classes tc ON tc.id = l.tax_class_id AND tc.organization_id = l.organization_id
            WHERE l.organization_id = p_org AND l.invoice_id = i.id), '[]'::jsonb))
           ELSE jsonb_build_object('lines_count', (
            SELECT count(*) FROM public.purchase_invoice_lines l
            WHERE l.organization_id = p_org AND l.invoice_id = i.id)) END
    FROM public.purchase_invoices i
    JOIN public.suppliers s ON s.id = i.supplier_id AND s.organization_id = i.organization_id
    LEFT JOIN public.employees ce ON ce.id = i.created_by AND ce.organization_id = i.organization_id
    LEFT JOIN public.employees ae ON ae.id = i.approved_by AND ae.organization_id = i.organization_id
    WHERE i.organization_id = p_org AND i.id = p_id
$$;

-- 3. Posting (U02's loop, shared by a direct approval and the owner's approval) ---------------------

-- Posts every line in product_id order: moving-average cost on the net unit cost (all branches,
-- half-up to 4 places; no stock -> the unit cost), then the stock (units for serialized lines),
-- and marks the invoice approved. Returns the costs before and after, for the audit.
CREATE FUNCTION app.post_purchase_invoice(p_org uuid, p_emp uuid, p_invoice public.purchase_invoices)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r record; v_old_qty bigint; v_old_avg numeric(18,4); v_new_avg numeric(18,4); v_costs jsonb := '[]';
BEGIN
    FOR r IN SELECT * FROM public.purchase_invoice_lines x
             WHERE x.organization_id = p_org AND x.invoice_id = p_invoice.id ORDER BY x.product_id LOOP
        SELECT p.avg_cost INTO v_old_avg FROM public.products p
        WHERE p.id = r.product_id AND p.organization_id = p_org FOR UPDATE;
        SELECT COALESCE(sum(sl.on_hand), 0) INTO v_old_qty FROM public.stock_levels sl
        WHERE sl.organization_id = p_org AND sl.product_id = r.product_id;
        v_new_avg := CASE WHEN v_old_qty <= 0 THEN r.unit_cost
                          ELSE round((v_old_qty * v_old_avg + r.quantity * r.unit_cost) / (v_old_qty + r.quantity), 4) END;
        UPDATE public.products p SET avg_cost = v_new_avg, updated_by = p_emp WHERE p.id = r.product_id;
        v_costs := v_costs || jsonb_build_object('product_id', r.product_id, 'before', v_old_avg::text,
                                                 'after', v_new_avg::text);

        IF r.serials IS NOT NULL THEN
            PERFORM app.create_units(p_org, p_emp, r.product_id, p_invoice.branch_id, r.serials, r.unit_cost,
                                     'purchase_in', 'purchase_invoice', p_invoice.id, r.id);
        ELSE
            INSERT INTO public.stock_movements (organization_id, product_id, branch_id, quantity, type, stock_state,
                                                unit_cost, source_type, source_id, source_line_id, created_by)
            VALUES (p_org, r.product_id, p_invoice.branch_id, r.quantity, 'purchase_in', 'sellable', r.unit_cost,
                    'purchase_invoice', p_invoice.id, r.id, p_emp);
        END IF;
    END LOOP;

    UPDATE public.purchase_invoices i
       SET status = 'approved', approved_by = p_emp, approved_at = now(), updated_by = p_emp
     WHERE i.id = p_invoice.id;
    RETURN v_costs;
END;
$$;

-- 4. Drafts only (a pending invoice waits for the owner) ---------------------------------------------

-- U02's update, now for drafts only.
CREATE OR REPLACE FUNCTION public.update_purchase_invoice(p_id uuid, p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_i public.purchase_invoices; v_key text; v_no text; v_date date;
    v_before jsonb := '{}'; v_after jsonb := '{}'; v_old_lines jsonb; v_new_lines jsonb; v_total text;
BEGIN
    v_emp := app.require_permission('purchase.invoice_create');
    v_org := app.current_org_id();
    v_i := app.purchase_invoice_for_write(v_org, p_id);
    PERFORM app.require_branch_access(v_i.branch_id);
    IF v_i.status <> 'draft' THEN                            -- U06: a pending invoice waits for the owner
        RAISE EXCEPTION 'PURCHASE_INVOICE_NOT_EDITABLE: the invoice is %', v_i.status USING ERRCODE = 'P0001';
    END IF;
    IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT k INTO v_key FROM jsonb_object_keys(p_changes) k
    WHERE k <> ALL (ARRAY['supplier_invoice_no', 'invoice_date', 'lines']) LIMIT 1;
    IF v_key IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
    END IF;

    IF p_changes ? 'supplier_invoice_no' THEN
        v_no := app.supplier_invoice_no(p_changes ->> 'supplier_invoice_no');
        IF v_no IS DISTINCT FROM v_i.supplier_invoice_no THEN
            BEGIN
                UPDATE public.purchase_invoices i SET supplier_invoice_no = v_no, updated_by = v_emp WHERE i.id = p_id;
            EXCEPTION WHEN unique_violation THEN
                RAISE EXCEPTION 'SUPPLIER_INVOICE_NO_TAKEN' USING ERRCODE = 'P0001';
            END;
            v_before := v_before || jsonb_build_object('supplier_invoice_no', v_i.supplier_invoice_no);
            v_after := v_after || jsonb_build_object('supplier_invoice_no', v_no);
        END IF;
    END IF;
    IF p_changes ? 'invoice_date' THEN
        v_date := (p_changes ->> 'invoice_date')::date;
        IF v_date IS NULL OR v_date > app.org_today(v_org) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: date' USING ERRCODE = 'P0001';
        END IF;
        IF v_date <> v_i.invoice_date THEN
            UPDATE public.purchase_invoices i SET invoice_date = v_date, updated_by = v_emp WHERE i.id = p_id;
            v_before := v_before || jsonb_build_object('invoice_date', v_i.invoice_date);
            v_after := v_after || jsonb_build_object('invoice_date', v_date);
        END IF;
    END IF;
    IF p_changes ? 'lines' THEN
        v_old_lines := app.purchase_invoice_lines_json(v_org, p_id);
        PERFORM app.set_purchase_invoice_lines(v_org, v_emp, v_i, p_changes -> 'lines');
        v_new_lines := app.purchase_invoice_lines_json(v_org, p_id);
        IF v_new_lines <> v_old_lines THEN
            SELECT i.total::text INTO v_total FROM public.purchase_invoices i WHERE i.id = p_id;
            UPDATE public.purchase_invoices i SET updated_by = v_emp WHERE i.id = p_id;
            v_before := v_before || jsonb_build_object('lines', v_old_lines, 'total', v_i.total::text);
            v_after := v_after || jsonb_build_object('lines', v_new_lines, 'total', v_total);
        END IF;
    END IF;

    IF v_after <> '{}'::jsonb THEN                          -- no change: no audit row
        PERFORM app.write_audit('purchase_invoice.updated', 'purchase_invoice', p_id, v_before,
            v_after || jsonb_build_object('number', v_i.number), NULL, v_i.branch_id);
    END IF;
    RETURN app.purchase_invoice_json(v_org, p_id, true);
EXCEPTION
    WHEN invalid_text_representation OR datetime_field_overflow OR invalid_datetime_format THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
END;
$$;

-- 5. Approve -------------------------------------------------------------------------------------

DROP FUNCTION public.approve_purchase_invoice(uuid);

-- Draft: posts as U02 does, unless a non-owner approves a total above the threshold, which sends
-- it to the owner (pending_approval). Pending: only the owner, with a note (3-500). Approved:
-- answered unchanged (U02). Rejected: PURCHASE_INVOICE_NOT_EDITABLE.
CREATE FUNCTION public.approve_purchase_invoice(p_id uuid, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_i public.purchase_invoices; v_missing jsonb; v_owner boolean; v_note text;
    v_threshold numeric(18,2); v_total numeric(18,2); v_above boolean; v_costs jsonb; v_approval uuid;
BEGIN
    v_emp := app.require_permission('purchase.invoice_approve');
    v_org := app.current_org_id();
    v_i := app.purchase_invoice_for_write(v_org, p_id);
    PERFORM app.require_branch_access(v_i.branch_id);
    IF v_i.status = 'approved' THEN
        RETURN app.purchase_invoice_json(v_org, p_id, true);     -- a repeat posts nothing again
    ELSIF v_i.status = 'rejected' THEN
        RAISE EXCEPTION 'PURCHASE_INVOICE_NOT_EDITABLE: the invoice is rejected' USING ERRCODE = 'P0001';
    END IF;
    v_owner := app.current_role() = 'OWNER';
    IF v_i.status = 'pending_approval' THEN
        -- Only the owner decides, whatever the threshold is now (it may have changed since).
        IF NOT v_owner THEN
            RAISE EXCEPTION 'APPROVAL_OWNER_ONLY' USING ERRCODE = '42501';
        END IF;
        v_note := btrim(p_note);
        IF v_note IS NULL OR length(v_note) NOT BETWEEN 3 AND 500 THEN
            RAISE EXCEPTION 'APPROVAL_NOTE_REQUIRED' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    PERFORM app.require_active_supplier(v_org, v_i.supplier_id);

    SELECT jsonb_agg(l.id ORDER BY l.product_id) INTO v_missing
    FROM public.purchase_invoice_lines l
    JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
    WHERE l.organization_id = v_org AND l.invoice_id = p_id AND p.is_serialized AND l.serials IS NULL;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'SERIALS_REQUIRED: % line(s) need serials', jsonb_array_length(v_missing) USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('line_ids', v_missing)::text;
    END IF;
    IF EXISTS (SELECT 1 FROM public.purchase_invoice_lines l
               JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
               WHERE l.organization_id = v_org AND l.invoice_id = p_id AND p.is_serialized) THEN
        PERFORM app.require_module('serials');
    END IF;

    -- Current class rates (a rate changed since the draft applies).
    PERFORM app.purchase_invoice_compute(v_org, p_id);
    SELECT i.total INTO v_total FROM public.purchase_invoices i WHERE i.id = p_id;

    IF v_i.status = 'pending_approval' THEN
        -- The owner's decision on a waiting invoice: post, then close the approval in one statement.
        v_costs := app.post_purchase_invoice(v_org, v_emp, v_i);
        UPDATE public.approvals a
           SET status = 'approved', decided_by = v_emp, decided_at = now(), decision_note = v_note
         WHERE a.organization_id = v_org AND a.kind = 'purchase_invoice' AND a.entity_id = p_id
           AND a.status = 'pending'
        RETURNING a.id INTO v_approval;
        PERFORM app.write_audit('purchase_invoice.approved', 'purchase_invoice', p_id,
            jsonb_build_object('status', 'pending_approval'),
            jsonb_build_object('status', 'approved', 'number', v_i.number, 'total', v_total::text,
                               'lines', (SELECT count(*) FROM public.purchase_invoice_lines x
                                         WHERE x.organization_id = v_org AND x.invoice_id = p_id),
                               'avg_cost', v_costs, 'approval_id', v_approval),
            v_note, v_i.branch_id);
        RETURN app.purchase_invoice_json(v_org, p_id, true);
    END IF;

    -- U06: a draft above the threshold waits for the owner (strictly greater, VAT included).
    SELECT s.purchase_approval_threshold INTO v_threshold
    FROM public.org_settings s WHERE s.organization_id = v_org;
    v_above := v_threshold IS NOT NULL AND v_total > v_threshold;
    IF v_above AND NOT v_owner THEN
        UPDATE public.purchase_invoices i SET status = 'pending_approval', updated_by = v_emp WHERE i.id = p_id;
        INSERT INTO public.approvals (organization_id, branch_id, kind, entity_type, entity_id, amount, payload,
                                     status, requested_by, created_by)
        VALUES (v_org, v_i.branch_id, 'purchase_invoice', 'purchase_invoice', p_id, v_total,
                jsonb_build_object('threshold', v_threshold::text, 'number', v_i.number),
                'pending', v_emp, v_emp)
        RETURNING id INTO v_approval;
        PERFORM app.write_audit('purchase_invoice.approval_requested', 'purchase_invoice', p_id,
            jsonb_build_object('status', 'draft'),
            jsonb_build_object('status', 'pending_approval', 'number', v_i.number, 'total', v_total::text,
                               'threshold', v_threshold::text, 'approval_id', v_approval),
            NULL, v_i.branch_id);
        RETURN app.purchase_invoice_json(v_org, p_id, true);
    END IF;

    v_costs := app.post_purchase_invoice(v_org, v_emp, v_i);
    PERFORM app.write_audit('purchase_invoice.approved', 'purchase_invoice', p_id,
        jsonb_build_object('status', v_i.status),
        jsonb_build_object('status', 'approved', 'number', v_i.number, 'total', v_total::text,
                           'lines', (SELECT count(*) FROM public.purchase_invoice_lines x
                                     WHERE x.organization_id = v_org AND x.invoice_id = p_id),
                           'avg_cost', v_costs, 'threshold', v_threshold::text, 'above', v_above),
        NULL, v_i.branch_id);
    RETURN app.purchase_invoice_json(v_org, p_id, true);
END;
$$;

-- 6. Reject: a pending invoice is the owner's to reject; its approval closes with the reason ------

CREATE OR REPLACE FUNCTION public.reject_purchase_invoice(p_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_i public.purchase_invoices; v_reason text; v_approval uuid;
BEGIN
    v_emp := app.require_permission('purchase.invoice_approve');
    v_org := app.current_org_id();
    v_i := app.purchase_invoice_for_write(v_org, p_id);
    PERFORM app.require_branch_access(v_i.branch_id);
    IF v_i.status NOT IN ('draft', 'pending_approval') THEN
        RAISE EXCEPTION 'PURCHASE_INVOICE_NOT_EDITABLE: the invoice is %', v_i.status USING ERRCODE = 'P0001';
    END IF;
    IF v_i.status = 'pending_approval' AND app.current_role() IS DISTINCT FROM 'OWNER' THEN
        RAISE EXCEPTION 'APPROVAL_OWNER_ONLY' USING ERRCODE = '42501';
    END IF;
    v_reason := btrim(p_reason);
    IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    IF v_i.status = 'pending_approval' THEN
        UPDATE public.approvals a
           SET status = 'rejected', decided_by = v_emp, decided_at = now(), decision_note = v_reason
         WHERE a.organization_id = v_org AND a.kind = 'purchase_invoice' AND a.entity_id = p_id
           AND a.status = 'pending'
        RETURNING a.id INTO v_approval;
    END IF;
    UPDATE public.purchase_invoices i
       SET status = 'rejected', rejected_reason = v_reason, updated_by = v_emp
     WHERE i.id = p_id;
    PERFORM app.write_audit('purchase_invoice.rejected', 'purchase_invoice', p_id,
        jsonb_build_object('status', v_i.status),
        jsonb_build_object('status', 'rejected', 'number', v_i.number, 'total', v_i.total::text)
            || CASE WHEN v_approval IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('approval_id', v_approval) END,
        v_reason, v_i.branch_id, 'warning'::public.audit_severity);
    RETURN app.purchase_invoice_json(v_org, p_id, true);
END;
$$;

-- 7. The approval list ----------------------------------------------------------------------------

-- purchase.invoice_approve (a read: works in an expired shop); approvals of the caller's branches
-- (OWNER: all), newest first. p_status: pending (default), approved, rejected or cancelled.
CREATE FUNCTION public.list_purchase_approvals(p_status text DEFAULT 'pending', p_branch_id uuid DEFAULT NULL,
                                               p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branches uuid[]; v_result jsonb;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('purchase.invoice_approve') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: purchase.invoice_approve' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    IF p_status IS NULL OR p_status NOT IN ('pending', 'approved', 'rejected', 'cancelled')
       OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
            RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF NOT app.has_branch_access(p_branch_id) THEN
            RAISE EXCEPTION 'BRANCH_DENIED' USING ERRCODE = '42501';
        END IF;
        v_branches := ARRAY[p_branch_id];
    ELSE
        SELECT COALESCE(array_agg(b.id), ARRAY[]::uuid[]) INTO v_branches
        FROM public.branches b WHERE b.organization_id = v_org AND app.has_branch_access(b.id);
    END IF;

    WITH found AS (
        SELECT a.id, a.entity_id, a.created_at FROM public.approvals a
        WHERE a.organization_id = v_org AND a.kind = 'purchase_invoice' AND a.status::text = p_status
          AND a.branch_id = ANY(v_branches)
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('approval', app.purchase_approval_json(v_org, f.id),
                                                'invoice', app.purchase_invoice_json(v_org, f.entity_id, false))
                             ORDER BY f.created_at DESC, f.id DESC)
            FROM (SELECT * FROM found ORDER BY created_at DESC, id DESC LIMIT p_limit OFFSET p_offset) f),
            '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- 8. Grants ----------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.purchase_approval_json(uuid, uuid),
    app.post_purchase_invoice(uuid, uuid, public.purchase_invoices)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.approve_purchase_invoice(uuid, text), public.reject_purchase_invoice(uuid, text),
    public.list_purchase_approvals(text, uuid, integer, integer)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.approve_purchase_invoice(uuid, text), public.reject_purchase_invoice(uuid, text),
    public.list_purchase_approvals(text, uuid, integer, integer)
    TO authenticated;
