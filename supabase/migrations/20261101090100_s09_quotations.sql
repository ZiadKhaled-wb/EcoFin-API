-- S09: offers have no stock, shift, reservation or cash effects.
ALTER TABLE public.quotations
  ADD COLUMN prices_include_vat boolean NOT NULL DEFAULT true,
  ADD COLUMN status_reason text,
  ADD COLUMN sent_at timestamptz,
  ADD COLUMN accepted_at timestamptz,
  ADD CHECK (status NOT IN ('rejected','cancelled') OR status_reason IS NOT NULL),
  ADD CHECK (total = subtotal - discount_total + CASE WHEN prices_include_vat THEN 0 ELSE tax_total END);
ALTER TABLE public.quotation_lines
  ADD COLUMN tax_class_id uuid NOT NULL,
  ADD COLUMN tax_rate numeric(5,2) NOT NULL CHECK (tax_rate BETWEEN 0 AND 100),
  ADD FOREIGN KEY (tax_class_id, organization_id) REFERENCES public.tax_classes(id, organization_id);
DROP TRIGGER trg_quotations_final ON public.quotations;
CREATE TRIGGER trg_quotations_final BEFORE UPDATE ON public.quotations
  FOR EACH ROW EXECUTE FUNCTION app.freeze_when_status('accepted','expired','cancelled','rejected');
DROP TRIGGER trg_quotation_lines_final ON public.quotation_lines;
CREATE TRIGGER trg_quotation_lines_final BEFORE INSERT OR UPDATE OR DELETE ON public.quotation_lines
  FOR EACH ROW EXECUTE FUNCTION app.freeze_lines_when_parent_status('quotations','quotation_id','accepted','expired','cancelled','rejected');
-- Reads are RPC-only, including customer projection: never expose national_id.
REVOKE ALL ON public.quotations, public.quotation_lines FROM anon, authenticated;

CREATE FUNCTION public.get_quotation(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_q public.quotations; v_org uuid;
BEGIN
  PERFORM app.require_permission('quotation.manage');
  v_org := app.current_org_id();
  SELECT * INTO v_q FROM public.quotations q WHERE q.id=p_id AND q.organization_id=v_org;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTATION_NOT_FOUND'; END IF;
  IF NOT app.has_branch_access(v_q.branch_id) THEN RAISE EXCEPTION 'QUOTATION_NOT_FOUND'; END IF;
  RETURN (to_jsonb(v_q) - 'organization_id' - 'idempotency_key') || jsonb_build_object(
    'subtotal',v_q.subtotal::text,'discount_total',v_q.discount_total::text,
    'tax_total',v_q.tax_total::text,'total',v_q.total::text,
    'effective_status',CASE WHEN v_q.status='sent' AND v_q.valid_until<app.org_today(v_org) THEN 'expired' ELSE v_q.status::text END,
    'customer',(SELECT jsonb_build_object('id',c.id,'name',c.full_name,'phone',c.phones[1]) FROM public.customers c WHERE c.id=v_q.customer_id AND c.organization_id=v_org),
    'branch',(SELECT jsonb_build_object('id',b.id,'name',b.name,'address',b.address) FROM public.branches b WHERE b.id=v_q.branch_id AND b.organization_id=v_org),
    'shop',(SELECT jsonb_build_object('legal_name',COALESCE(o.legal_name,o.name)) FROM public.organizations o WHERE o.id=v_org),
    'lines',COALESCE((SELECT jsonb_agg((to_jsonb(l)-'organization_id') || jsonb_build_object(
      'unit_price',l.unit_price::text,'discount_amount',l.discount_amount::text,'tax_rate',l.tax_rate::text,
      'tax_amount',l.tax_amount::text,'line_total',l.line_total::text) ORDER BY l.line_no)
      FROM public.quotation_lines l WHERE l.quotation_id=p_id AND l.organization_id=v_org),'[]'::jsonb));
END $$;

-- Internal validator/pricer. Same S03 role lookup and T01 tax computation as a sale.
CREATE FUNCTION app.quotation_price(p_lines jsonb, p_inc boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_emp uuid; v_org uuid; v_l jsonb; v_p public.products; v_class uuid; v_rate numeric;
  v_qty numeric; v_price numeric; v_disc numeric; v_cap numeric; v_desc text;
  v_lines jsonb := '[]'; v_tax_lines jsonb := '[]'; v_tax jsonb; v_out jsonb := '[]'; i integer := 0;
BEGIN
  v_emp := app.require_permission('quotation.manage'); v_org := app.current_org_id();
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'QUOTATION_LINES_INVALID'; END IF;
  IF jsonb_array_length(p_lines) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'QUOTATION_LINES_INVALID'; END IF;
  v_cap := app.discount_cap_pct(v_emp);
  FOR v_l IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    IF jsonb_typeof(v_l) IS DISTINCT FROM 'object'
      OR COALESCE(v_l->>'quantity','') !~ '^[0-9]{1,10}$'
      OR COALESCE(v_l->>'unit_price','') !~ '^[0-9]{1,16}(\.[0-9]{1,2})?$'
      OR COALESCE(v_l->>'discount_amount','0') !~ '^[0-9]{1,16}(\.[0-9]{1,2})?$'
      OR COALESCE(jsonb_typeof(v_l->'description'),'null') NOT IN ('string','null')
      OR COALESCE(jsonb_typeof(v_l->'custom_notes'),'null') NOT IN ('string','null')
      OR length(COALESCE(v_l->>'custom_notes',''))>500 THEN RAISE EXCEPTION 'QUOTATION_LINES_INVALID'; END IF;
    v_qty := (v_l->>'quantity')::numeric; v_price := (v_l->>'unit_price')::numeric;
    v_disc := COALESCE(v_l->>'discount_amount','0')::numeric;
    IF v_qty<1 OR v_qty>2147483647 OR v_disc>v_qty*v_price THEN RAISE EXCEPTION 'QUOTATION_LINES_INVALID'; END IF;
    v_desc := NULLIF(btrim(v_l->>'description'),'');
    IF v_l->>'product_id' IS NOT NULL THEN
      SELECT * INTO v_p FROM public.products p WHERE p.id=(v_l->>'product_id')::uuid AND p.organization_id=v_org AND p.is_active AND p.archived_at IS NULL FOR SHARE;
      IF NOT FOUND THEN RAISE EXCEPTION 'PRODUCT_NOT_FOUND'; END IF;
      IF v_price<>v_p.cash_price AND NOT app.has_permission('price.override') THEN RAISE EXCEPTION 'PRICE_OVERRIDE_REQUIRED'; END IF;
      v_class:=v_p.tax_class_id; v_desc:=COALESCE(v_desc,v_p.name_ar);
    ELSE
      IF v_desc IS NULL THEN RAISE EXCEPTION 'QUOTATION_LINES_INVALID'; END IF;
      SELECT default_tax_class_id INTO v_class FROM public.org_settings WHERE organization_id=v_org;
    END IF;
    IF length(v_desc)>200 THEN RAISE EXCEPTION 'QUOTATION_LINES_INVALID'; END IF;
    IF v_qty*v_price>0 AND v_disc*100/(v_qty*v_price)>v_cap AND NOT app.has_permission('discount.above_cap') THEN RAISE EXCEPTION 'DISCOUNT_ABOVE_CAP'; END IF;
    SELECT rate INTO v_rate FROM public.tax_classes WHERE id=v_class AND organization_id=v_org;
    IF NOT FOUND THEN RAISE EXCEPTION 'QUOTATION_LINES_INVALID'; END IF;
    i:=i+1;
    v_lines:=v_lines||jsonb_build_object('line_no',i,'product_id',v_l->>'product_id','description',v_desc,
      'custom_notes',v_l->>'custom_notes','quantity',v_qty,'unit_price',v_price::numeric(18,2)::text,
      'discount_amount',v_disc::numeric(18,2)::text,'tax_class_id',v_class,'tax_rate',v_rate::text);
    v_tax_lines:=v_tax_lines||jsonb_build_object('unit_price',v_price::text,'quantity',v_qty,'line_discount',v_disc::text,'tax_rate',v_rate::text);
  END LOOP;
  v_tax:=app.compute_document_tax(jsonb_build_object('prices_include_vat',p_inc,'document_discount','0','lines',v_tax_lines));
  FOR i IN 0..jsonb_array_length(v_lines)-1 LOOP
    v_out:=v_out||((v_lines->i)||jsonb_build_object('tax_amount',v_tax->'lines'->i->>'tax','line_total',v_tax->'lines'->i->>'gross'));
  END LOOP;
  RETURN v_tax || jsonb_build_object('lines',v_out);
END $$;

CREATE FUNCTION app.quotation_replace(p_id uuid,p_customer_id uuid,p_valid_until date,p_notes text,p_lines jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid; v_q public.quotations; v_date date; v_cart jsonb; v_l jsonb; v_emp uuid;
BEGIN
  v_emp:=app.require_permission('quotation.manage'); v_org:=app.current_org_id();
  SELECT * INTO v_q FROM public.quotations WHERE id=p_id AND organization_id=v_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTATION_NOT_FOUND'; END IF;
  PERFORM app.require_branch_access(v_q.branch_id);
  IF v_q.status<>'draft' THEN RAISE EXCEPTION 'QUOTATION_NOT_DRAFT'; END IF;
  v_date:=COALESCE(p_valid_until,app.org_today(v_org)+14);
  IF v_date<app.org_today(v_org) OR v_date>app.org_today(v_org)+180 THEN RAISE EXCEPTION 'QUOTATION_VALIDITY_INVALID'; END IF;
  IF p_customer_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.customers WHERE id=p_customer_id AND organization_id=v_org) THEN RAISE EXCEPTION 'CUSTOMER_NOT_FOUND'; END IF;
  v_cart:=app.quotation_price(p_lines,v_q.prices_include_vat);
  DELETE FROM public.quotation_lines WHERE quotation_id=p_id AND organization_id=v_org;
  FOR v_l IN SELECT value FROM jsonb_array_elements(v_cart->'lines') LOOP
    INSERT INTO public.quotation_lines(organization_id,quotation_id,line_no,product_id,description,custom_notes,quantity,unit_price,discount_amount,tax_class_id,tax_rate,tax_amount,line_total,created_by)
    VALUES(v_org,p_id,(v_l->>'line_no')::integer,(v_l->>'product_id')::uuid,v_l->>'description',v_l->>'custom_notes',(v_l->>'quantity')::integer,
      (v_l->>'unit_price')::numeric,(v_l->>'discount_amount')::numeric,(v_l->>'tax_class_id')::uuid,(v_l->>'tax_rate')::numeric,(v_l->>'tax_amount')::numeric,(v_l->>'line_total')::numeric,v_emp);
  END LOOP;
  UPDATE public.quotations SET customer_id=p_customer_id,valid_until=v_date,notes=p_notes,
    subtotal=(SELECT sum(quantity*unit_price) FROM public.quotation_lines WHERE quotation_id=p_id),
    discount_total=(SELECT sum(discount_amount) FROM public.quotation_lines WHERE quotation_id=p_id),
    tax_total=(v_cart->>'tax_total')::numeric,total=(v_cart->>'total')::numeric,updated_at=clock_timestamp(),updated_by=v_emp WHERE id=p_id;
END $$;

CREATE FUNCTION public.create_quotation(p_branch_id uuid,p_customer_id uuid,p_valid_until date,p_notes text,p_lines jsonb,p_idempotency_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid; v_emp uuid; v_q public.quotations; v_inc boolean;
BEGIN
  v_emp:=app.require_permission('quotation.manage'); v_org:=app.current_org_id();
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'VALIDATION_FAILED'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('quotation/'||v_org::text||'/'||p_idempotency_key,0));
  SELECT * INTO v_q FROM public.quotations WHERE organization_id=v_org AND idempotency_key=p_idempotency_key FOR UPDATE;
  IF FOUND THEN
    PERFORM app.require_branch_access(v_q.branch_id);
    RETURN jsonb_build_object('id',v_q.id,'number',v_q.number);
  END IF;
  PERFORM app.require_branch_access(p_branch_id);
  SELECT prices_include_vat INTO v_inc FROM public.org_settings WHERE organization_id=v_org;
  INSERT INTO public.quotations(organization_id,number,branch_id,idempotency_key,prices_include_vat,created_by,updated_by)
    VALUES(v_org,app.next_document_number(v_org,p_branch_id,'quotation'),p_branch_id,p_idempotency_key,v_inc,v_emp,v_emp) RETURNING * INTO v_q;
  PERFORM app.quotation_replace(v_q.id,p_customer_id,p_valid_until,p_notes,p_lines);
  PERFORM app.write_audit('quotation.created','quotation',v_q.id,NULL,jsonb_build_object('number',v_q.number),NULL,p_branch_id);
  RETURN jsonb_build_object('id',v_q.id,'number',v_q.number);
END $$;

CREATE FUNCTION public.update_quotation_draft(p_id uuid,p_customer_id uuid,p_valid_until date,p_notes text,p_lines jsonb,p_expected_updated_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid; v_q public.quotations;
BEGIN
  PERFORM app.require_permission('quotation.manage'); v_org:=app.current_org_id();
  SELECT * INTO v_q FROM public.quotations WHERE id=p_id AND organization_id=v_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTATION_NOT_FOUND'; END IF;
  PERFORM app.require_branch_access(v_q.branch_id);
  IF v_q.status<>'draft' THEN RAISE EXCEPTION 'QUOTATION_NOT_DRAFT'; END IF;
  IF v_q.updated_at IS DISTINCT FROM p_expected_updated_at THEN RAISE EXCEPTION 'QUOTATION_STALE'; END IF;
  PERFORM app.quotation_replace(p_id,p_customer_id,p_valid_until,p_notes,p_lines);
  PERFORM app.write_audit('quotation.updated','quotation',p_id,NULL,jsonb_build_object('number',v_q.number),NULL,v_q.branch_id);
  RETURN public.get_quotation(p_id);
END $$;

CREATE FUNCTION app.quotation_move(p_id uuid,p_to text,p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid; v_emp uuid; v_q public.quotations;
BEGIN
  v_emp:=app.require_permission('quotation.manage'); v_org:=app.current_org_id();
  SELECT * INTO v_q FROM public.quotations WHERE id=p_id AND organization_id=v_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTATION_NOT_FOUND'; END IF;
  PERFORM app.require_branch_access(v_q.branch_id);
  IF NOT ((v_q.status='draft' AND p_to IN ('sent','cancelled')) OR (v_q.status='sent' AND p_to IN ('accepted','rejected','cancelled'))) THEN RAISE EXCEPTION 'QUOTATION_BAD_TRANSITION'; END IF;
  IF p_to='accepted' AND v_q.valid_until<app.org_today(v_org) THEN RAISE EXCEPTION 'QUOTATION_EXPIRED'; END IF;
  IF p_to IN ('rejected','cancelled') AND (p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 500) THEN RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
  IF p_to='sent' THEN
    IF v_q.customer_id IS NULL THEN RAISE EXCEPTION 'QUOTATION_CUSTOMER_REQUIRED'; END IF;
    IF v_q.valid_until IS NULL OR v_q.valid_until<app.org_today(v_org) THEN RAISE EXCEPTION 'QUOTATION_VALIDITY_INVALID'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.quotation_lines WHERE quotation_id=p_id) THEN RAISE EXCEPTION 'QUOTATION_LINES_INVALID'; END IF;
  END IF;
  UPDATE public.quotations SET status=p_to::public.quotation_status,status_reason=CASE WHEN p_to IN ('rejected','cancelled') THEN btrim(p_reason) ELSE NULL END,
    sent_at=CASE WHEN p_to='sent' THEN clock_timestamp() ELSE sent_at END,
    accepted_at=CASE WHEN p_to='accepted' THEN clock_timestamp() ELSE accepted_at END,
    updated_at=clock_timestamp(),updated_by=v_emp WHERE id=p_id;
  PERFORM app.write_audit('quotation.'||p_to,'quotation',p_id,NULL,jsonb_build_object('number',v_q.number,'reason',p_reason),p_reason,v_q.branch_id);
  RETURN public.get_quotation(p_id);
END $$;
CREATE FUNCTION public.send_quotation(p_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$ BEGIN PERFORM app.require_permission('quotation.manage'); RETURN app.quotation_move(p_id,'sent'); END $$;
CREATE FUNCTION public.accept_quotation(p_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$ BEGIN PERFORM app.require_permission('quotation.manage'); RETURN app.quotation_move(p_id,'accepted'); END $$;
CREATE FUNCTION public.reject_quotation(p_id uuid,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$ BEGIN PERFORM app.require_permission('quotation.manage'); RETURN app.quotation_move(p_id,'rejected',p_reason); END $$;
CREATE FUNCTION public.cancel_quotation(p_id uuid,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$ BEGIN PERFORM app.require_permission('quotation.manage'); RETURN app.quotation_move(p_id,'cancelled',p_reason); END $$;

CREATE FUNCTION public.list_quotations(p_status text DEFAULT NULL,p_branch_id uuid DEFAULT NULL,p_customer_id uuid DEFAULT NULL,p_from date DEFAULT NULL,p_to date DEFAULT NULL,p_search text DEFAULT NULL,p_limit integer DEFAULT 20,p_offset integer DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid; v_result jsonb;
BEGIN
  PERFORM app.require_permission('quotation.manage'); v_org:=app.current_org_id();
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR p_offset IS NULL OR p_offset<0 THEN RAISE EXCEPTION 'VALIDATION_FAILED'; END IF;
  IF p_branch_id IS NOT NULL AND NOT app.has_branch_access(p_branch_id) THEN RAISE EXCEPTION 'BRANCH_DENIED'; END IF;
  WITH filtered AS (
    SELECT q.id,q.created_at FROM public.quotations q LEFT JOIN public.customers c ON c.id=q.customer_id AND c.organization_id=v_org
    WHERE q.organization_id=v_org AND app.has_branch_access(q.branch_id)
      AND (p_status IS NULL OR p_status=CASE WHEN q.status='sent' AND q.valid_until<app.org_today(v_org) THEN 'expired' ELSE q.status::text END)
      AND (p_branch_id IS NULL OR q.branch_id=p_branch_id) AND (p_customer_id IS NULL OR q.customer_id=p_customer_id)
      AND (p_from IS NULL OR (q.created_at AT TIME ZONE (SELECT timezone FROM public.organizations WHERE id=v_org))::date>=p_from)
      AND (p_to IS NULL OR (q.created_at AT TIME ZONE (SELECT timezone FROM public.organizations WHERE id=v_org))::date<=p_to)
      AND (p_search IS NULL OR q.number ILIKE '%'||p_search||'%' OR c.full_name ILIKE '%'||p_search||'%' OR EXISTS(SELECT 1 FROM unnest(c.phones) ph WHERE ph ILIKE '%'||p_search||'%'))
  ) SELECT jsonb_build_object('total',(SELECT count(*) FROM filtered),'items',COALESCE((SELECT jsonb_agg(public.get_quotation(f.id) ORDER BY f.created_at DESC,f.id DESC) FROM (SELECT * FROM filtered ORDER BY created_at DESC,id DESC LIMIT p_limit OFFSET p_offset) f),'[]'::jsonb)) INTO v_result;
  RETURN v_result;
END $$;

-- Worker exception to session permission/org derivation: service role only, all shops.
CREATE FUNCTION public.expire_quotations() RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_q public.quotations; v_count integer:=0;
BEGIN
  FOR v_q IN SELECT * FROM public.quotations q WHERE q.status='sent' AND q.valid_until<app.org_today(q.organization_id) ORDER BY q.id FOR UPDATE SKIP LOCKED LOOP
    UPDATE public.quotations SET status='expired',updated_at=clock_timestamp() WHERE id=v_q.id;
    PERFORM app.write_audit('quotation.expired','quotation',v_q.id,NULL,jsonb_build_object('number',v_q.number),NULL,v_q.branch_id,'info',v_q.organization_id);
    v_count:=v_count+1;
  END LOOP;
  RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION app.quotation_price(jsonb,boolean),app.quotation_replace(uuid,uuid,date,text,jsonb),app.quotation_move(uuid,text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.get_quotation(uuid),public.create_quotation(uuid,uuid,date,text,jsonb,text),public.update_quotation_draft(uuid,uuid,date,text,jsonb,timestamptz),public.send_quotation(uuid),public.accept_quotation(uuid),public.reject_quotation(uuid,text),public.cancel_quotation(uuid,text),public.list_quotations(text,uuid,uuid,date,date,text,integer,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_quotation(uuid),public.create_quotation(uuid,uuid,date,text,jsonb,text),public.update_quotation_draft(uuid,uuid,date,text,jsonb,timestamptz),public.send_quotation(uuid),public.accept_quotation(uuid),public.reject_quotation(uuid,text),public.cancel_quotation(uuid,text),public.list_quotations(text,uuid,uuid,date,date,text,integer,integer) TO authenticated;
REVOKE ALL ON FUNCTION public.expire_quotations() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.expire_quotations() TO service_role;
