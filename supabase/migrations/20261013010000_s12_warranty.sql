-- S12. New sales normalize the date supplied by S03; existing non-NULL dates stay intact.
ALTER TABLE public.warranty_claims ADD COLUMN out_of_warranty boolean NOT NULL DEFAULT false;
ALTER TABLE public.warranty_claims DROP CONSTRAINT warranty_claims_check;
ALTER TABLE public.warranty_claims ADD CONSTRAINT warranty_claims_replacement_status_check
    CHECK (replacement_unit_id IS NULL OR status IN ('replaced','closed'));
CREATE UNIQUE INDEX warranty_claims_active_unit_idx ON public.warranty_claims(organization_id,unit_id)
    WHERE unit_id IS NOT NULL AND status NOT IN ('closed','rejected');

CREATE FUNCTION app.set_sale_warranty() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE d date; m integer;
BEGIN
    SELECT s.business_date,p.warranty_months INTO d,m FROM public.sales s
    JOIN public.products p ON p.id=NEW.product_id AND p.organization_id=NEW.organization_id
    WHERE s.id=NEW.sale_id AND s.organization_id=NEW.organization_id;
    NEW.warranty_until:=CASE WHEN m>0 THEN (d+make_interval(months=>m)-interval '1 day')::date END;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION app.set_sale_warranty() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER trg_sale_lines_warranty BEFORE INSERT ON public.sale_lines
    FOR EACH ROW EXECUTE FUNCTION app.set_sale_warranty();

-- Migration-only helper; never callable by an employee. The append-only guard is restored
-- in the same transaction. Only missing dates are filled; issued financial values do not change.
CREATE FUNCTION app.backfill_sale_warranties() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    ALTER TABLE public.sale_lines DISABLE TRIGGER trg_sale_lines_append_only;
    UPDATE public.sale_lines l SET warranty_until=(s.business_date+make_interval(months=>p.warranty_months)-interval '1 day')::date
    FROM public.sales s,public.products p
    WHERE l.sale_id=s.id AND l.organization_id=s.organization_id AND l.product_id=p.id
      AND l.organization_id=p.organization_id AND l.warranty_until IS NULL AND p.warranty_months>0;
    ALTER TABLE public.sale_lines ENABLE TRIGGER trg_sale_lines_append_only;
END $$;
REVOKE ALL ON FUNCTION app.backfill_sale_warranties() FROM PUBLIC,anon,authenticated;
SELECT app.backfill_sale_warranties();

-- F10 remains the sole stock-level writer. This later AFTER trigger only supplies the
-- warranty-specific unit status after the normal ledger trigger has posted the movement.
CREATE FUNCTION app.apply_warranty_unit_movement() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF NEW.source_type='warranty_claim' AND NEW.unit_id IS NOT NULL AND NEW.type IN ('claim_in','claim_out') THEN
        UPDATE public.units SET status=CASE WHEN NEW.type='claim_in' THEN 'returned' ELSE 'sold' END::public.unit_status,
            updated_at=now() WHERE id=NEW.unit_id AND organization_id=NEW.organization_id;
    END IF;
    RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION app.apply_warranty_unit_movement() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER trg_stock_movements_warranty AFTER INSERT ON public.stock_movements
    FOR EACH ROW EXECUTE FUNCTION app.apply_warranty_unit_movement();

CREATE FUNCTION app.warranty_serial_chain(o uuid,i uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
WITH RECURSIVE chain AS (
 SELECT u.id,u.serial,s.issued_at AS at,l.warranty_until,0 depth,ARRAY[u.id] path
 FROM public.sale_lines l JOIN public.sales s ON s.id=l.sale_id AND s.organization_id=o
 JOIN public.units u ON u.id=l.unit_id AND u.organization_id=o WHERE l.id=i AND l.organization_id=o
 UNION ALL
 SELECT u.id,u.serial,COALESCE((SELECT (a.after->>'moved_at')::timestamptz FROM public.audit_log a WHERE a.organization_id=o AND a.entity_id=w.id AND a.action='warranty_claim.moved' AND a.after->>'status'='replaced' ORDER BY a.id LIMIT 1),w.created_at),c.warranty_until,c.depth+1,c.path||u.id
 FROM chain c JOIN public.warranty_claims w ON w.unit_id=c.id AND w.organization_id=o AND w.sale_line_id=i
 JOIN public.units u ON u.id=w.replacement_unit_id AND u.organization_id=o WHERE NOT u.id=ANY(c.path))
SELECT COALESCE(jsonb_agg(jsonb_build_object('unit_id',id,'serial',serial,'at',at,'warranty_until',warranty_until) ORDER BY depth),'[]') FROM chain;
$$;
REVOKE ALL ON FUNCTION app.warranty_serial_chain(uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION app.warranty_line_json(o uuid,i uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
SELECT jsonb_build_object('sale_line_id',l.id,'product',jsonb_build_object('id',p.id,'name',p.name_ar,'sku',p.sku,'serialized',p.is_serialized),
    'quantity',l.quantity,'branch',jsonb_build_object('id',b.id,'name',b.name),
    'customer',CASE WHEN c.id IS NULL THEN NULL ELSE jsonb_build_object('id',c.id,'name',c.full_name) END,
    'sale_id',s.id,'sale_number',s.number,'sale_date',s.business_date,'warranty_until',l.warranty_until,
    'in_warranty',COALESCE(l.warranty_until>=app.org_today(o),false),'unit_id',l.unit_id,'serial',u.serial,
    'chain',app.warranty_serial_chain(o,l.id),
    'claims',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',w.id,'number',w.number,'status',w.status,'unit_id',w.unit_id,
        'replacement_unit_id',w.replacement_unit_id,'out_of_warranty',w.out_of_warranty,'created_at',w.created_at) ORDER BY w.created_at,w.number)
        FROM public.warranty_claims w WHERE w.organization_id=o AND w.sale_line_id=l.id),'[]'::jsonb))
FROM public.sale_lines l JOIN public.sales s ON s.id=l.sale_id AND s.organization_id=o
JOIN public.products p ON p.id=l.product_id AND p.organization_id=o
JOIN public.branches b ON b.id=s.branch_id AND b.organization_id=o
LEFT JOIN public.customers c ON c.id=s.customer_id AND c.organization_id=o
LEFT JOIN public.units u ON u.id=l.unit_id AND u.organization_id=o WHERE l.id=i AND l.organization_id=o;
$$;
REVOKE ALL ON FUNCTION app.warranty_line_json(uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION app.warranty_claim_json(o uuid,i uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
SELECT jsonb_build_object('id',w.id,'number',w.number,'branch_id',w.branch_id,'sale_line_id',w.sale_line_id,
    'unit_id',w.unit_id,'replacement_unit_id',w.replacement_unit_id,'status',w.status,'issue',w.issue,'resolution',w.resolution,
    'out_of_warranty',w.out_of_warranty,'created_at',w.created_at,'closed_at',w.closed_at,
    'line',app.warranty_line_json(o,w.sale_line_id),
    'files',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',f.id,'purpose',f.purpose,'mime',f.mime,'sizeBytes',f.size_bytes,
        'originalName',f.original_name,'entityType',f.entity_type,'entityId',f.entity_id,'createdAt',f.created_at) ORDER BY f.created_at,f.id)
        FROM public.files f WHERE f.organization_id=o AND f.entity_type='warranty_claim' AND f.entity_id=w.id AND f.purpose='other'),'[]'::jsonb),
    'history',COALESCE((SELECT jsonb_agg(jsonb_build_object('action',a.action,'at',a.created_at,'note',a.after->>'note') ORDER BY a.created_at,a.id)
        FROM public.audit_log a WHERE a.organization_id=o AND a.entity_type='warranty_claim' AND a.entity_id=w.id),'[]'::jsonb))
FROM public.warranty_claims w WHERE w.organization_id=o AND w.id=i;
$$;
REVOKE ALL ON FUNCTION app.warranty_claim_json(uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.warranty_lookup(p_serial text DEFAULT NULL,p_phone text DEFAULT NULL,p_sale_number text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE e uuid:=app.require_permission('warranty.manage'); o uuid:=app.current_org_id(); v jsonb;
BEGIN
    IF num_nonnulls(NULLIF(btrim(p_serial),''),NULLIF(btrim(p_phone),''),NULLIF(btrim(p_sale_number),''))<>1 THEN
        RAISE EXCEPTION 'LOOKUP_ONE_KEY' USING ERRCODE='P0001'; END IF;
    SELECT COALESCE(jsonb_agg(app.warranty_line_json(o,l.id) ORDER BY s.issued_at DESC,l.line_no),'[]') INTO v
    FROM public.sale_lines l JOIN public.sales s ON s.id=l.sale_id AND s.organization_id=o
    LEFT JOIN public.customers c ON c.id=s.customer_id AND c.organization_id=o
    WHERE l.organization_id=o AND app.has_branch_access(s.branch_id) AND (
        (p_sale_number IS NOT NULL AND s.number=btrim(p_sale_number)) OR
        (p_phone IS NOT NULL AND EXISTS(SELECT 1 FROM unnest(c.phones) ph WHERE app.normalize_customer_phone(ph)=app.normalize_customer_phone(p_phone))) OR
        (p_serial IS NOT NULL AND EXISTS(SELECT 1 FROM public.units u WHERE u.organization_id=o AND u.serial=upper(btrim(p_serial)) AND
            (u.id=l.unit_id OR EXISTS(SELECT 1 FROM public.warranty_claims w WHERE w.organization_id=o AND w.sale_line_id=l.id AND (w.unit_id=u.id OR w.replacement_unit_id=u.id))))));
    RETURN jsonb_build_object('items',v);
END $$;

CREATE FUNCTION public.get_warranty_claim(p_claim_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE e uuid:=app.require_permission('warranty.manage'); o uuid:=app.current_org_id(); b uuid;
BEGIN
    SELECT branch_id INTO b FROM public.warranty_claims WHERE organization_id=o AND id=p_claim_id;
    IF NOT FOUND OR NOT app.has_branch_access(b) THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
    PERFORM app.require_branch_access(b);
    RETURN app.warranty_claim_json(o,p_claim_id);
END $$;

CREATE FUNCTION public.list_warranty_claims(p_status public.claim_status DEFAULT NULL,p_branch_id uuid DEFAULT NULL,
    p_out_of_warranty boolean DEFAULT NULL,p_limit integer DEFAULT 20,p_offset integer DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE e uuid:=app.require_permission('warranty.manage'); o uuid:=app.current_org_id(); v jsonb; n bigint;
BEGIN
    IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR p_offset IS NULL OR p_offset<0 THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
    IF p_branch_id IS NOT NULL THEN PERFORM app.require_branch_access(p_branch_id); END IF;
    SELECT count(*) INTO n FROM public.warranty_claims w WHERE w.organization_id=o AND app.has_branch_access(w.branch_id)
      AND (p_branch_id IS NULL OR w.branch_id=p_branch_id) AND (p_status IS NULL OR w.status=p_status) AND (p_out_of_warranty IS NULL OR w.out_of_warranty=p_out_of_warranty);
    SELECT COALESCE(jsonb_agg(app.warranty_claim_json(o,x.id) ORDER BY x.created_at DESC,x.id DESC),'[]') INTO v FROM (
        SELECT w.id,w.created_at FROM public.warranty_claims w WHERE w.organization_id=o AND app.has_branch_access(w.branch_id)
        AND (p_branch_id IS NULL OR w.branch_id=p_branch_id) AND (p_status IS NULL OR w.status=p_status) AND (p_out_of_warranty IS NULL OR w.out_of_warranty=p_out_of_warranty)
        ORDER BY w.created_at DESC,w.id DESC LIMIT p_limit OFFSET p_offset) x;
    RETURN jsonb_build_object('items',v,'total',n);
END $$;

CREATE FUNCTION public.open_warranty_claim(p_sale_line_id uuid,p_unit_id uuid,p_issue text,p_condition text,p_idempotency_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE e uuid:=app.require_permission('warranty.manage'); o uuid:=app.current_org_id(); l public.sale_lines; s public.sales; w public.warranty_claims; u public.units;
BEGIN
    PERFORM app.lock_idempotency_key(o,p_idempotency_key);
    SELECT * INTO l FROM public.sale_lines WHERE organization_id=o AND id=p_sale_line_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SALE_LINE_NOT_FOUND' USING ERRCODE='P0001'; END IF;
    SELECT * INTO s FROM public.sales WHERE organization_id=o AND id=l.sale_id;
    PERFORM app.require_branch_access(s.branch_id);
    SELECT * INTO w FROM public.warranty_claims WHERE organization_id=o AND idempotency_key=p_idempotency_key;
    IF FOUND THEN
        IF w.sale_line_id<>l.id OR w.unit_id IS DISTINCT FROM p_unit_id OR w.issue IS DISTINCT FROM btrim(p_issue) OR (SELECT a.after->>'condition' FROM public.audit_log a WHERE a.organization_id=o AND a.entity_id=w.id AND a.action='warranty_claim.opened' ORDER BY a.id LIMIT 1) IS DISTINCT FROM btrim(p_condition) THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='P0001'; END IF;
        RETURN jsonb_build_object('claim_id',w.id,'number',w.number,'out_of_warranty',w.out_of_warranty);
    END IF;
    IF p_issue IS NULL OR length(btrim(p_issue)) NOT BETWEEN 3 AND 500 OR p_condition IS NULL OR length(btrim(p_condition)) NOT BETWEEN 3 AND 300 THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
    IF l.unit_id IS NULL THEN
        IF p_unit_id IS NOT NULL THEN RAISE EXCEPTION 'CLAIM_UNIT_MISMATCH' USING ERRCODE='P0001'; END IF;
        IF (SELECT count(*) FROM public.warranty_claims WHERE organization_id=o AND sale_line_id=l.id AND (status NOT IN ('closed','rejected') OR (status='closed' AND resolution LIKE E'%\nreplaced:%')))>=l.quantity THEN
            RAISE EXCEPTION 'CLAIM_QTY_EXCEEDED' USING ERRCODE='P0001'; END IF;
    ELSE
        IF p_unit_id IS NULL OR NOT (p_unit_id=l.unit_id OR EXISTS(SELECT 1 FROM public.warranty_claims WHERE organization_id=o AND sale_line_id=l.id AND replacement_unit_id=p_unit_id)) THEN
            RAISE EXCEPTION 'CLAIM_UNIT_MISMATCH' USING ERRCODE='P0001'; END IF;
        SELECT * INTO u FROM public.units WHERE organization_id=o AND id=p_unit_id FOR UPDATE;
        IF EXISTS(SELECT 1 FROM public.warranty_claims WHERE organization_id=o AND unit_id=p_unit_id AND status NOT IN ('closed','rejected')) THEN RAISE EXCEPTION 'CLAIM_ALREADY_OPEN' USING ERRCODE='P0001'; END IF;
        IF u.status<>'sold' OR u.product_id<>l.product_id THEN RAISE EXCEPTION 'CLAIM_UNIT_MISMATCH' USING ERRCODE='P0001'; END IF;
    END IF;
    INSERT INTO public.warranty_claims(organization_id,number,branch_id,sale_line_id,unit_id,customer_id,issue,resolution,out_of_warranty,idempotency_key,created_by)
    VALUES(o,app.next_document_number(o,s.branch_id,'warranty_claim'),s.branch_id,l.id,p_unit_id,s.customer_id,btrim(p_issue),'Received: '||btrim(p_condition),
        l.warranty_until IS NULL OR app.org_today(o)>l.warranty_until,p_idempotency_key,e) RETURNING * INTO w;
    PERFORM app.write_audit('warranty_claim.opened','warranty_claim',w.id,NULL,jsonb_build_object('number',w.number,'out_of_warranty',w.out_of_warranty,'condition',btrim(p_condition)));
    RETURN jsonb_build_object('claim_id',w.id,'number',w.number,'out_of_warranty',w.out_of_warranty);
END $$;

CREATE FUNCTION public.move_warranty_claim(p_claim_id uuid,p_to public.claim_status,p_note text,p_replacement_unit_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE e uuid:=app.require_permission('warranty.manage'); o uuid:=app.current_org_id(); w public.warranty_claims; l public.sale_lines; u public.units; prev public.claim_status;
BEGIN
    SELECT * INTO w FROM public.warranty_claims WHERE id=p_claim_id AND organization_id=o;
    IF NOT FOUND OR NOT app.has_branch_access(w.branch_id) THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
    PERFORM app.require_branch_access(w.branch_id);
    SELECT * INTO l FROM public.sale_lines WHERE id=w.sale_line_id AND organization_id=o FOR UPDATE;
    SELECT * INTO w FROM public.warranty_claims WHERE id=p_claim_id AND organization_id=o FOR UPDATE;
    prev:=w.status;
    -- Repeating a completed stock-changing move returns its result without posting twice.
    IF w.status=p_to AND p_to='replaced' AND w.replacement_unit_id IS NOT DISTINCT FROM p_replacement_unit_id THEN RETURN app.warranty_claim_json(o,w.id); END IF;
    IF p_to IS NULL OR NOT ((w.status='open' AND p_to IN ('in_repair','replaced','rejected')) OR (w.status='in_repair' AND p_to IN ('repaired','replaced','rejected')) OR (w.status IN ('repaired','replaced') AND p_to='closed')) THEN
        RAISE EXCEPTION 'CLAIM_BAD_TRANSITION' USING ERRCODE='P0001'; END IF;
    IF w.out_of_warranty AND p_to<>'rejected' AND NOT app.has_permission('discount.above_cap') THEN RAISE EXCEPTION 'OUT_OF_WARRANTY_NEEDS_MANAGER' USING ERRCODE='42501'; END IF;
    IF p_to IN ('rejected','replaced') AND length(COALESCE(btrim(p_note),''))<1 THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
    IF p_to<>'replaced' AND p_replacement_unit_id IS NOT NULL THEN RAISE EXCEPTION 'REPLACEMENT_UNIT_INVALID' USING ERRCODE='P0001'; END IF;
    PERFORM 1 FROM public.units WHERE organization_id=o AND id IN (w.unit_id,p_replacement_unit_id) ORDER BY id FOR UPDATE;
    IF p_to='replaced' THEN
        IF w.unit_id IS NOT NULL THEN
            SELECT * INTO u FROM public.units WHERE id=p_replacement_unit_id AND organization_id=o;
            IF NOT FOUND OR u.id=w.unit_id OR u.product_id<>l.product_id OR u.branch_id<>w.branch_id OR u.status<>'in_stock' THEN RAISE EXCEPTION 'REPLACEMENT_UNIT_INVALID' USING ERRCODE='P0001'; END IF;
        ELSIF p_replacement_unit_id IS NOT NULL THEN RAISE EXCEPTION 'REPLACEMENT_UNIT_INVALID' USING ERRCODE='P0001'; END IF;
        PERFORM 1 FROM public.stock_levels WHERE organization_id=o AND branch_id=w.branch_id AND product_id=l.product_id ORDER BY stock_state FOR UPDATE;
        INSERT INTO public.stock_movements(organization_id,product_id,branch_id,unit_id,quantity,type,stock_state,unit_cost,source_type,source_id,business_date,created_by)
        VALUES(o,l.product_id,w.branch_id,w.unit_id,1,'claim_in','damaged',l.unit_cost,'warranty_claim',w.id,app.org_today(o),e);
        INSERT INTO public.stock_movements(organization_id,product_id,branch_id,unit_id,quantity,type,stock_state,unit_cost,source_type,source_id,business_date,created_by)
        VALUES(o,l.product_id,w.branch_id,p_replacement_unit_id,-1,'claim_out','sellable',COALESCE(u.cost,l.unit_cost),'warranty_claim',w.id,app.org_today(o),e);
    ELSIF w.unit_id IS NOT NULL AND p_to IN ('in_repair','repaired','rejected') THEN
        -- Customer-owned repair: no shop stock enters/leaves. Only this checked definer writes status.
        UPDATE public.units SET status=CASE WHEN p_to='in_repair' THEN 'in_repair' ELSE 'sold' END::public.unit_status,updated_at=now(),updated_by=e WHERE id=w.unit_id AND organization_id=o;
    END IF;
    UPDATE public.warranty_claims SET status=p_to,replacement_unit_id=CASE WHEN p_to='replaced' THEN p_replacement_unit_id ELSE replacement_unit_id END,
        resolution=resolution||E'\n'||p_to::text||': '||COALESCE(btrim(p_note),'')||CASE WHEN p_to='replaced' THEN E'\nWarranty until: '||COALESCE(l.warranty_until::text,'none') ELSE '' END,
        closed_at=CASE WHEN p_to='closed' THEN clock_timestamp() ELSE closed_at END,updated_at=clock_timestamp(),updated_by=e WHERE id=w.id;
    PERFORM app.write_audit('warranty_claim.moved','warranty_claim',w.id,jsonb_build_object('status',prev),jsonb_build_object('status',p_to,'moved_at',clock_timestamp(),'note',COALESCE(btrim(p_note),''),'replacement_unit_id',p_replacement_unit_id));
    RETURN app.warranty_claim_json(o,w.id);
END $$;

CREATE FUNCTION public.request_claim_refund(p_claim_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE e uuid:=app.require_permission('warranty.manage'); o uuid:=app.current_org_id(); b uuid;
BEGIN
    SELECT branch_id INTO b FROM public.warranty_claims WHERE id=p_claim_id AND organization_id=o;
    IF NOT FOUND OR NOT app.has_branch_access(b) THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
    PERFORM app.require_branch_access(b);
    RAISE EXCEPTION 'CLAIM_REFUND_NEEDS_RETURN' USING ERRCODE='P0001';
END $$;

REVOKE ALL ON FUNCTION public.warranty_lookup(text,text,text),public.get_warranty_claim(uuid),public.list_warranty_claims(public.claim_status,uuid,boolean,integer,integer),public.open_warranty_claim(uuid,uuid,text,text,text),public.move_warranty_claim(uuid,public.claim_status,text,uuid),public.request_claim_refund(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.warranty_lookup(text,text,text),public.get_warranty_claim(uuid),public.list_warranty_claims(public.claim_status,uuid,boolean,integer,integer),public.open_warranty_claim(uuid,uuid,text,text,text),public.move_warranty_claim(uuid,public.claim_status,text,uuid),public.request_claim_refund(uuid) TO authenticated;

-- F14: approved warranty-only permission specialization; all other behavior unchanged.
CREATE OR REPLACE FUNCTION public.register_file(
    p_id          uuid,
    p_path        text,
    p_original_name text,
    p_mime        text,
    p_size_bytes  bigint,
    p_sha256      text,
    p_purpose     public.file_purpose,
    p_entity_type text,
    p_entity_id   uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid := app.require_permission(CASE p_purpose
        WHEN 'logo'             THEN 'org.settings_manage'
        WHEN 'product_image'    THEN 'catalog.manage'
        WHEN 'customer_id'      THEN 'customer.create'
        WHEN 'survey_photo'     THEN 'survey.submit'
        WHEN 'signature'        THEN 'installment.create'
        WHEN 'contract_pdf'     THEN 'installment.create'
        WHEN 'promissory_note'  THEN 'installment.create'
        WHEN 'delivery_proof'   THEN 'delivery.manage'
        WHEN 'expense_receipt'  THEN 'expense.create'
        WHEN 'legal_document'   THEN 'legal.manage'
        WHEN 'import'           THEN 'import.data'
        WHEN 'export'           THEN 'export.data'
        WHEN 'other'            THEN CASE WHEN p_entity_type='warranty_claim' THEN 'warranty.manage' ELSE 'org.settings_manage' END
    END);
    v_org   uuid := app.current_org_id();
    v_table text;
    v_found boolean;
    v_branch uuid;
BEGIN
    IF p_id IS NULL OR p_path IS NULL OR p_mime IS NULL OR p_size_bytes IS NULL
       OR p_size_bytes < 0 OR p_purpose IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: id, path, mime, size and purpose are required'
            USING ERRCODE = 'P0001';
    END IF;

    -- The object must sit under the caller's own shop: '<org id>/...', no '.', '..' or backslash.
    IF left(p_path, length(v_org::text) + 1) <> v_org::text || '/'
       OR p_path ~ '\\' OR p_path ~ '(^|/)\.{1,2}(/|$)' THEN
        RAISE EXCEPTION 'FILE_PATH_INVALID: the path must start with the shop id' USING ERRCODE = 'P0001';
    END IF;

    -- EC-142: the record the file points at. Same entity types as the API (files.rules.ts ENTITY_TABLES).
    IF p_entity_id IS NOT NULL AND p_entity_type IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: an entity type is needed with an entity id' USING ERRCODE = 'P0001';
    END IF;
    IF p_entity_type IS NOT NULL THEN
        v_table := CASE p_entity_type
            WHEN 'customer'   THEN 'customers'
            WHEN 'product'    THEN 'products'
            WHEN 'expense'    THEN 'expenses'
            WHEN 'contract'   THEN 'contracts'
            WHEN 'legal_case' THEN 'legal_cases'
            WHEN 'delivery'   THEN 'deliveries'
            WHEN 'warranty_claim' THEN 'warranty_claims'
        END;
        IF v_table IS NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: unknown entity type' USING ERRCODE = 'P0001';
        END IF;
        IF p_entity_id IS NOT NULL THEN
            EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I WHERE id = $1 AND organization_id = $2)', v_table)
                INTO v_found USING p_entity_id, v_org;
            IF NOT v_found THEN
                RAISE EXCEPTION 'NOT_FOUND: entity' USING ERRCODE = 'P0002';
            END IF;
        END IF;
    END IF;

    IF p_entity_type='warranty_claim' THEN
        IF p_entity_id IS NULL OR p_purpose<>'other' THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
        SELECT branch_id INTO v_branch FROM public.warranty_claims WHERE id=p_entity_id AND organization_id=v_org FOR UPDATE;
        PERFORM app.require_branch_access(v_branch);
        IF (SELECT count(*) FROM public.files WHERE organization_id=v_org AND entity_type='warranty_claim' AND entity_id=p_entity_id)>=5 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: at most five claim photos' USING ERRCODE='P0001'; END IF;
    END IF;

    INSERT INTO public.files (id, organization_id, bucket, path, original_name, mime, size_bytes,
                              sha256, purpose, entity_type, entity_id, created_by)
    VALUES (p_id, v_org, 'tenant-files', p_path, p_original_name, p_mime, p_size_bytes,
            p_sha256, p_purpose, p_entity_type, p_entity_id, v_emp);

    PERFORM app.write_audit('file.upload', 'file', p_id, NULL,
        jsonb_build_object('purpose', p_purpose, 'size', p_size_bytes,
                           'entity_type', p_entity_type, 'entity_id', p_entity_id));
    RETURN p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.register_file(uuid, text, text, text, bigint, text,
                                               public.file_purpose, text, uuid) TO authenticated;
