-- S10 sales orders, part 1: create (direct or from an accepted quote), link to-order lines to a
-- purchase order line, reserve to-order lines once stock arrives, and the reads.
-- Stock is only held through stock_reservations (the trigger keeps stock_levels.reserved and the
-- unit status). Deposits and cancellation are appended below by part 2.

-- Decision 2: one order per quote.
CREATE UNIQUE INDEX sales_orders_quotation_key ON public.sales_orders (quotation_id) WHERE quotation_id IS NOT NULL;

-- Decision 5: a reserved unit can't leave stock until its reservation is released. Body copied
-- from the baseline; only the outgoing status check changes (was NOT IN ('in_stock', 'reserved')).
CREATE OR REPLACE FUNCTION app.check_stock_movement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_serialized boolean;
    v_unit       public.units%ROWTYPE;
BEGIN
    SELECT p.is_serialized INTO v_serialized FROM public.products p
    WHERE p.id = NEW.product_id AND p.organization_id = NEW.organization_id;
    IF v_serialized AND NEW.unit_id IS NULL THEN
        RAISE EXCEPTION 'UNIT_REQUIRED: product % is serialized', NEW.product_id USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_serialized AND NEW.unit_id IS NOT NULL THEN
        RAISE EXCEPTION 'UNIT_NOT_ALLOWED: product % is not serialized', NEW.product_id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.unit_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_unit FROM public.units u
    WHERE u.id = NEW.unit_id AND u.organization_id = NEW.organization_id FOR UPDATE;
    IF v_unit.product_id IS DISTINCT FROM NEW.product_id THEN
        RAISE EXCEPTION 'UNIT_PRODUCT_MISMATCH' USING ERRCODE = 'P0001';
    END IF;

    IF NEW.quantity < 0 THEN
        -- Out: the unit must be here and available (a reservation is released first).
        IF v_unit.branch_id <> NEW.branch_id OR v_unit.status <> 'in_stock' THEN
            RAISE EXCEPTION 'UNIT_NOT_AVAILABLE: % is % at another or same branch', v_unit.serial, v_unit.status
                USING ERRCODE = 'P0001';
        END IF;
    ELSE
        -- In: the unit must not already be in stock somewhere (first movement excepted).
        IF v_unit.status IN ('in_stock', 'reserved')
           AND EXISTS (SELECT 1 FROM public.stock_movements m WHERE m.unit_id = NEW.unit_id) THEN
            RAISE EXCEPTION 'UNIT_ALREADY_IN_STOCK: %', v_unit.serial USING ERRCODE = 'P0001';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- One line's fulfilment options, normalised to {fulfilment, unit_ids (array), po_line_id}.
CREATE FUNCTION app.s10_line_options(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_f text; v_units jsonb; v_po jsonb;
  c_uuid constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
BEGIN
  PERFORM app.require_permission('order.manage');
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'ORDER_LINES_INVALID'; END IF;
  IF COALESCE(jsonb_typeof(p->'fulfilment'),'null') NOT IN ('string','null') THEN RAISE EXCEPTION 'ORDER_LINES_INVALID'; END IF;
  v_f := COALESCE(p->>'fulfilment','from_stock');
  IF v_f NOT IN ('from_stock','to_order') THEN RAISE EXCEPTION 'ORDER_LINES_INVALID'; END IF;
  v_units := COALESCE(NULLIF(p->'unit_ids','null'::jsonb),'[]'::jsonb);
  IF jsonb_typeof(v_units)<>'array' OR jsonb_array_length(v_units)>200
     OR EXISTS(SELECT 1 FROM jsonb_array_elements(v_units) u WHERE jsonb_typeof(u)<>'string' OR u#>>'{}' !~ c_uuid) THEN
    RAISE EXCEPTION 'ORDER_LINES_INVALID';
  END IF;
  v_po := COALESCE(p->'po_line_id','null'::jsonb);
  IF v_po<>'null'::jsonb AND (jsonb_typeof(v_po)<>'string' OR v_po#>>'{}' !~ c_uuid) THEN RAISE EXCEPTION 'ORDER_LINES_INVALID'; END IF;
  IF (v_f='from_stock' AND v_po<>'null'::jsonb) OR (v_f='to_order' AND jsonb_array_length(v_units)>0) THEN
    RAISE EXCEPTION 'ORDER_LINES_INVALID';
  END IF;
  RETURN jsonb_build_object('fulfilment',v_f,'unit_ids',v_units,'po_line_id',v_po);
END $$;

-- Decision 1 pricing: the S09 rules (cash price unless price.override, line discount within the role
-- cap unless discount.above_cap or OWNER), tax and totals from the T01 engine. Product lines only.
CREATE FUNCTION app.s10_price(p_lines jsonb, p_inc boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_emp uuid; v_org uuid; v_l jsonb; v_p public.products; v_rate numeric;
  v_qty numeric; v_price numeric; v_disc numeric; v_cap numeric;
  v_lines jsonb := '[]'; v_tax_lines jsonb := '[]'; v_tax jsonb; v_out jsonb := '[]'; i integer := 0;
BEGIN
  v_emp := app.require_permission('order.manage'); v_org := app.current_org_id();
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'ORDER_LINES_INVALID'; END IF;
  IF jsonb_array_length(p_lines) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'ORDER_LINES_INVALID'; END IF;
  v_cap := app.discount_cap_pct(v_emp);   -- NULL for OWNER: no cap
  FOR v_l IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    IF jsonb_typeof(v_l) IS DISTINCT FROM 'object'
      OR jsonb_typeof(v_l->'product_id') IS DISTINCT FROM 'string'
      OR v_l->>'product_id' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      OR COALESCE(v_l->>'quantity','') !~ '^[0-9]{1,10}$'
      OR COALESCE(v_l->>'unit_price','') !~ '^[0-9]{1,16}(\.[0-9]{1,2})?$'
      OR COALESCE(v_l->>'discount_amount','0') !~ '^[0-9]{1,16}(\.[0-9]{1,2})?$'
      OR COALESCE(jsonb_typeof(v_l->'custom_notes'),'null') NOT IN ('string','null')
      OR length(COALESCE(v_l->>'custom_notes',''))>500 THEN RAISE EXCEPTION 'ORDER_LINES_INVALID'; END IF;
    v_qty := (v_l->>'quantity')::numeric; v_price := (v_l->>'unit_price')::numeric;
    v_disc := COALESCE(v_l->>'discount_amount','0')::numeric;
    IF v_qty<1 OR v_qty>2147483647 OR v_disc>v_qty*v_price THEN RAISE EXCEPTION 'ORDER_LINES_INVALID'; END IF;
    SELECT * INTO v_p FROM public.products p WHERE p.id=(v_l->>'product_id')::uuid AND p.organization_id=v_org AND p.is_active AND p.archived_at IS NULL FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PRODUCT_NOT_FOUND'; END IF;
    IF v_price<>v_p.cash_price AND NOT app.has_permission('price.override') THEN RAISE EXCEPTION 'PRICE_OVERRIDE_REQUIRED'; END IF;
    IF v_cap IS NOT NULL AND v_qty*v_price>0 AND v_disc*100/(v_qty*v_price)>v_cap AND NOT app.has_permission('discount.above_cap') THEN
      RAISE EXCEPTION 'DISCOUNT_ABOVE_CAP';
    END IF;
    SELECT rate INTO v_rate FROM public.tax_classes WHERE id=v_p.tax_class_id AND organization_id=v_org;
    IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_LINES_INVALID'; END IF;
    i:=i+1;
    v_lines:=v_lines||jsonb_build_object('line_no',i,'product_id',v_p.id,'custom_notes',v_l->>'custom_notes','quantity',v_qty,
      'unit_price',v_price::numeric(18,2)::text,'discount_amount',v_disc::numeric(18,2)::text,'tax_class_id',v_p.tax_class_id,
      'tax_rate',v_rate::text,'options',app.s10_line_options(v_l - 'product_id' - 'custom_notes' - 'quantity' - 'unit_price' - 'discount_amount'));
    v_tax_lines:=v_tax_lines||jsonb_build_object('unit_price',v_price::text,'quantity',v_qty,'line_discount',v_disc::text,'tax_rate',v_rate::text);
  END LOOP;
  v_tax:=app.compute_document_tax(jsonb_build_object('prices_include_vat',p_inc,'document_discount','0','lines',v_tax_lines));
  FOR i IN 0..jsonb_array_length(v_lines)-1 LOOP
    v_out:=v_out||((v_lines->i)||jsonb_build_object('tax_amount',v_tax->'lines'->i->>'tax','line_total',v_tax->'lines'->i->>'gross'));
  END LOOP;
  RETURN v_tax || jsonb_build_object('lines',v_out);
END $$;

-- Decision 3: hold stock for one from_stock line at the order's branch. Serialized: exactly
-- `quantity` distinct units of the product, in stock there, one reservation per unit (by unit id).
-- The reservation trigger's errors (NOT_ENOUGH_STOCK_TO_RESERVE, ...) pass through.
CREATE FUNCTION app.s10_reserve_line(p_org uuid, p_emp uuid, p_line public.sales_order_lines, p_branch uuid, p_unit_ids uuid[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_ser boolean; v_units uuid[] := COALESCE(p_unit_ids,'{}'); v_found integer;
BEGIN
  PERFORM app.require_permission('order.manage');
  SELECT p.is_serialized INTO v_ser FROM public.products p WHERE p.id=p_line.product_id AND p.organization_id=p_org;
  IF v_ser THEN
    IF cardinality(v_units)<>p_line.quantity
       OR (SELECT count(DISTINCT u) FROM unnest(v_units) u WHERE u IS NOT NULL)<>p_line.quantity THEN
      RAISE EXCEPTION 'UNITS_REQUIRED';
    END IF;
    SELECT count(*) INTO v_found FROM (SELECT u.id FROM public.units u WHERE u.organization_id=p_org AND u.id=ANY(v_units) ORDER BY u.id FOR UPDATE) x;
    IF v_found<>p_line.quantity THEN RAISE EXCEPTION 'UNIT_NOT_FOUND'; END IF;
    IF EXISTS(SELECT 1 FROM public.units u WHERE u.organization_id=p_org AND u.id=ANY(v_units)
              AND (u.product_id<>p_line.product_id OR u.status<>'in_stock' OR u.branch_id<>p_branch)) THEN
      RAISE EXCEPTION 'UNIT_NOT_AVAILABLE_TO_RESERVE';
    END IF;
    INSERT INTO public.stock_reservations(organization_id,product_id,branch_id,unit_id,order_line_id,quantity,created_by,updated_by)
      SELECT p_org,p_line.product_id,p_branch,u,p_line.id,1,p_emp,p_emp FROM unnest(v_units) u ORDER BY u;
  ELSE
    IF cardinality(v_units)>0 THEN RAISE EXCEPTION 'VALIDATION_FAILED: unit_ids are for serialized products'; END IF;
    INSERT INTO public.stock_reservations(organization_id,product_id,branch_id,order_line_id,quantity,created_by,updated_by)
      VALUES(p_org,p_line.product_id,p_branch,p_line.id,p_line.quantity,p_emp,p_emp);
  END IF;
END $$;

-- Decision 6 checks after the order/line ones: the PO line is the shop's, same product, its PO is
-- open, and the open order lines linked to it (this one included) don't exceed its quantity.
CREATE FUNCTION app.s10_link(p_org uuid, p_line public.sales_order_lines, p_po_line_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_pol public.purchase_order_lines; v_status public.po_status; v_used bigint;
BEGIN
  PERFORM app.require_permission('order.manage');
  SELECT l.* INTO v_pol FROM public.purchase_order_lines l WHERE l.id=p_po_line_id AND l.organization_id=p_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PO_NOT_FOUND'; END IF;
  SELECT o.status INTO v_status FROM public.purchase_orders o WHERE o.id=v_pol.po_id AND o.organization_id=p_org;
  IF v_pol.product_id<>p_line.product_id THEN RAISE EXCEPTION 'PO_LINE_PRODUCT_MISMATCH'; END IF;
  IF v_status NOT IN ('draft','sent','partially_received') THEN RAISE EXCEPTION 'PO_NOT_OPEN'; END IF;
  SELECT COALESCE(sum(sl.quantity),0) INTO v_used FROM public.sales_order_lines sl
    JOIN public.sales_orders so ON so.id=sl.order_id AND so.organization_id=sl.organization_id
   WHERE sl.organization_id=p_org AND sl.po_line_id=p_po_line_id AND sl.id<>p_line.id AND so.status<>'cancelled';
  IF v_used+p_line.quantity>v_pol.quantity THEN RAISE EXCEPTION 'PO_LINE_OVERCOMMITTED'; END IF;
  UPDATE public.sales_order_lines SET po_line_id=p_po_line_id WHERE id=p_line.id AND organization_id=p_org;
END $$;

-- Decisions 3 and 4 for a new order: lock the named units by id, then reserve the from_stock lines
-- in product_id order and link the to_order lines that name a PO line. p_opts: {line_id: options}.
CREATE FUNCTION app.s10_fulfil(p_org uuid, p_emp uuid, p_order public.sales_orders, p_opts jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_line public.sales_order_lines; v_o jsonb;
BEGIN
  PERFORM app.require_permission('order.manage');
  PERFORM 1 FROM public.units u WHERE u.organization_id=p_org
    AND u.id IN (SELECT (x#>>'{}')::uuid FROM jsonb_each(p_opts) e, jsonb_array_elements(e.value->'unit_ids') x)
    ORDER BY u.id FOR UPDATE;
  FOR v_line IN SELECT * FROM public.sales_order_lines l WHERE l.order_id=p_order.id AND l.organization_id=p_org ORDER BY l.product_id,l.line_no LOOP
    v_o := p_opts->(v_line.id::text);
    IF v_line.fulfilment='from_stock' THEN
      PERFORM app.s10_reserve_line(p_org,p_emp,v_line,p_order.branch_id,ARRAY(SELECT (x#>>'{}')::uuid FROM jsonb_array_elements(v_o->'unit_ids') x));
    ELSIF v_o->>'po_line_id' IS NOT NULL THEN
      PERFORM app.s10_link(p_org,v_line,(v_o->>'po_line_id')::uuid);
    END IF;
  END LOOP;
END $$;

-- Decision 10: one order as the API returns it. Money as text; customer name and phone only.
CREATE FUNCTION public.get_sales_order(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_o public.sales_orders; v_org uuid;
BEGIN
  PERFORM app.require_permission('order.manage');
  v_org := app.current_org_id();
  SELECT * INTO v_o FROM public.sales_orders o WHERE o.id=p_id AND o.organization_id=v_org;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  IF NOT app.has_branch_access(v_o.branch_id) THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  RETURN (to_jsonb(v_o) - 'organization_id' - 'idempotency_key') || jsonb_build_object(
    'subtotal',v_o.subtotal::text,'discount_total',v_o.discount_total::text,
    'tax_total',v_o.tax_total::text,'total',v_o.total::text,
    'customer',(SELECT jsonb_build_object('id',c.id,'name',c.full_name,'phone',c.phones[1]) FROM public.customers c WHERE c.id=v_o.customer_id AND c.organization_id=v_org),
    'branch',(SELECT jsonb_build_object('id',b.id,'name',b.name,'address',b.address) FROM public.branches b WHERE b.id=v_o.branch_id AND b.organization_id=v_org),
    'quotation',(SELECT jsonb_build_object('id',q.id,'number',q.number) FROM public.quotations q WHERE q.id=v_o.quotation_id AND q.organization_id=v_org),
    'lines',COALESCE((SELECT jsonb_agg((to_jsonb(l)-'organization_id') || jsonb_build_object(
      'unit_price',l.unit_price::text,'discount_amount',l.discount_amount::text,'tax_rate',l.tax_rate::text,
      'tax_amount',l.tax_amount::text,'line_total',l.line_total::text,
      'product',(SELECT jsonb_build_object('id',p.id,'sku',p.sku,'name_ar',p.name_ar,'name_en',p.name_en,'is_serialized',p.is_serialized)
                 FROM public.products p WHERE p.id=l.product_id AND p.organization_id=v_org),
      'delivered',f.delivered,'reserved',f.reserved,'remaining',f.remaining,
      'purchase_order',app.sales_order_line_po_status(v_org,l.id),
      'reserved_units',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',u.id,'serial',u.serial) ORDER BY u.serial)
                 FROM public.stock_reservations r JOIN public.units u ON u.id=r.unit_id AND u.organization_id=r.organization_id
                 WHERE r.order_line_id=l.id AND r.organization_id=v_org AND r.status='active'),'[]'::jsonb)) ORDER BY l.line_no)
      FROM public.sales_order_lines l JOIN public.v_order_line_fulfilment f ON f.order_line_id=l.id
      WHERE l.order_id=p_id AND l.organization_id=v_org),'[]'::jsonb),
    'payments',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',p.id,'number',p.number,'direction',p.direction,'method',p.method,
      'amount',a.amount::text,'reference',p.reference,'paid_at',p.paid_at) ORDER BY p.paid_at,p.number)
      FROM public.payment_allocations a JOIN public.payments p ON p.id=a.payment_id AND p.organization_id=a.organization_id
      WHERE a.order_id=p_id AND a.organization_id=v_org),'[]'::jsonb),
    'balances',(SELECT jsonb_build_object('deposits_paid',b.deposits_paid::text,'financed',b.financed::text,
      'delivered_value',b.delivered_value::text,'unpaid',b.unpaid::text) FROM public.v_order_balances b WHERE b.order_id=p_id));
END $$;

-- Decision 1.
CREATE FUNCTION public.create_sales_order(p_branch_id uuid, p_customer_id uuid, p_delivery_address text, p_notes text,
                                          p_lines jsonb, p_idempotency_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid; v_emp uuid; v_o public.sales_orders; v_inc boolean; v_cart jsonb; v_l jsonb;
  v_line uuid; v_opts jsonb := '{}';
BEGIN
  v_emp:=app.require_permission('order.manage'); v_org:=app.current_org_id();
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'VALIDATION_FAILED'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('sales_order/'||v_org::text||'/'||p_idempotency_key,0));
  SELECT * INTO v_o FROM public.sales_orders WHERE organization_id=v_org AND idempotency_key=p_idempotency_key;
  IF FOUND THEN
    PERFORM app.require_branch_access(v_o.branch_id);
    RETURN public.get_sales_order(v_o.id);
  END IF;
  PERFORM app.require_branch_access(p_branch_id);
  IF p_customer_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.customers WHERE id=p_customer_id AND organization_id=v_org) THEN
    RAISE EXCEPTION 'CUSTOMER_NOT_FOUND';
  END IF;
  IF length(p_delivery_address)>500 OR length(p_notes)>1000 THEN RAISE EXCEPTION 'VALIDATION_FAILED'; END IF;
  SELECT prices_include_vat INTO v_inc FROM public.org_settings WHERE organization_id=v_org;
  v_cart:=app.s10_price(p_lines,v_inc);
  INSERT INTO public.sales_orders(organization_id,number,customer_id,branch_id,prices_include_vat,subtotal,discount_total,tax_total,total,
                                  delivery_address,notes,idempotency_key,created_by,updated_by)
  SELECT v_org,app.next_document_number(v_org,p_branch_id,'sales_order'),p_customer_id,p_branch_id,v_inc,
         sum((l->>'quantity')::numeric*(l->>'unit_price')::numeric),sum((l->>'discount_amount')::numeric),
         (v_cart->>'tax_total')::numeric,(v_cart->>'total')::numeric,NULLIF(btrim(p_delivery_address),''),NULLIF(btrim(p_notes),''),
         p_idempotency_key,v_emp,v_emp
    FROM jsonb_array_elements(v_cart->'lines') l
  RETURNING * INTO v_o;
  FOR v_l IN SELECT value FROM jsonb_array_elements(v_cart->'lines') LOOP
    INSERT INTO public.sales_order_lines(organization_id,order_id,line_no,product_id,custom_notes,quantity,unit_price,discount_amount,
                                         tax_class_id,tax_rate,tax_amount,line_total,fulfilment,created_by)
    VALUES(v_org,v_o.id,(v_l->>'line_no')::integer,(v_l->>'product_id')::uuid,v_l->>'custom_notes',(v_l->>'quantity')::integer,
           (v_l->>'unit_price')::numeric,(v_l->>'discount_amount')::numeric,(v_l->>'tax_class_id')::uuid,(v_l->>'tax_rate')::numeric,
           (v_l->>'tax_amount')::numeric,(v_l->>'line_total')::numeric,(v_l->'options'->>'fulfilment')::public.fulfilment_mode,v_emp)
    RETURNING id INTO v_line;
    v_opts:=v_opts||jsonb_build_object(v_line::text,v_l->'options');
  END LOOP;
  PERFORM app.s10_fulfil(v_org,v_emp,v_o,v_opts);
  PERFORM app.write_audit('sales_order.created','sales_order',v_o.id,NULL,
    jsonb_build_object('number',v_o.number,'customer_id',v_o.customer_id,'total',v_o.total::text),NULL,v_o.branch_id);
  RETURN public.get_sales_order(v_o.id);
END $$;

-- Decision 2. p_line_options: {"<line_no>": {product_id (custom lines only), fulfilment, unit_ids?, po_line_id?}}.
CREATE FUNCTION public.create_order_from_quotation(p_quotation_id uuid, p_delivery_address text, p_line_options jsonb,
                                                   p_idempotency_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid; v_emp uuid; v_o public.sales_orders; v_q public.quotations; v_ql public.quotation_lines;
  v_all jsonb := COALESCE(p_line_options,'{}'::jsonb); v_lo jsonb; v_product uuid; v_line uuid; v_opts jsonb := '{}';
  v_constraint text;
BEGIN
  v_emp:=app.require_permission('order.manage'); v_org:=app.current_org_id();
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'VALIDATION_FAILED'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('sales_order/'||v_org::text||'/'||p_idempotency_key,0));
  SELECT * INTO v_o FROM public.sales_orders WHERE organization_id=v_org AND idempotency_key=p_idempotency_key;
  IF FOUND THEN
    PERFORM app.require_branch_access(v_o.branch_id);
    RETURN public.get_sales_order(v_o.id);
  END IF;
  SELECT * INTO v_q FROM public.quotations q WHERE q.id=p_quotation_id AND q.organization_id=v_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTATION_NOT_FOUND'; END IF;
  PERFORM app.require_branch_access(v_q.branch_id);
  IF v_q.status<>'accepted' THEN RAISE EXCEPTION 'QUOTATION_NOT_ACCEPTED'; END IF;
  IF EXISTS(SELECT 1 FROM public.sales_orders o WHERE o.quotation_id=v_q.id) THEN RAISE EXCEPTION 'QUOTATION_ALREADY_ORDERED'; END IF;
  IF length(p_delivery_address)>500 THEN RAISE EXCEPTION 'VALIDATION_FAILED'; END IF;
  IF jsonb_typeof(v_all)<>'object' OR EXISTS(SELECT 1 FROM jsonb_object_keys(v_all) k
       WHERE NOT EXISTS(SELECT 1 FROM public.quotation_lines ql WHERE ql.quotation_id=v_q.id AND ql.line_no::text=k)) THEN
    RAISE EXCEPTION 'ORDER_LINES_INVALID';
  END IF;
  BEGIN
    INSERT INTO public.sales_orders(organization_id,number,customer_id,branch_id,quotation_id,prices_include_vat,subtotal,discount_total,
                                    tax_total,total,delivery_address,idempotency_key,created_by,updated_by)
    VALUES(v_org,app.next_document_number(v_org,v_q.branch_id,'sales_order'),v_q.customer_id,v_q.branch_id,v_q.id,v_q.prices_include_vat,
           v_q.subtotal,v_q.discount_total,v_q.tax_total,v_q.total,NULLIF(btrim(p_delivery_address),''),p_idempotency_key,v_emp,v_emp)
    RETURNING * INTO v_o;
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    IF v_constraint='sales_orders_quotation_key' THEN RAISE EXCEPTION 'QUOTATION_ALREADY_ORDERED'; END IF;
    RAISE;
  END;
  FOR v_ql IN SELECT * FROM public.quotation_lines l WHERE l.quotation_id=v_q.id AND l.organization_id=v_org ORDER BY l.line_no LOOP
    v_lo := COALESCE(v_all->(v_ql.line_no::text),'{}'::jsonb);
    IF jsonb_typeof(v_lo)<>'object' THEN RAISE EXCEPTION 'ORDER_LINES_INVALID'; END IF;
    IF v_ql.product_id IS NULL THEN
      IF COALESCE(v_lo->>'product_id','')='' THEN RAISE EXCEPTION 'QUOTE_LINE_NEEDS_PRODUCT'; END IF;
      IF jsonb_typeof(v_lo->'product_id')<>'string'
         OR v_lo->>'product_id' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
        RAISE EXCEPTION 'ORDER_LINES_INVALID';
      END IF;
      SELECT p.id INTO v_product FROM public.products p WHERE p.id=(v_lo->>'product_id')::uuid AND p.organization_id=v_org
        AND p.is_active AND p.archived_at IS NULL FOR SHARE;
      IF NOT FOUND THEN RAISE EXCEPTION 'PRODUCT_NOT_FOUND'; END IF;
    ELSE
      IF v_lo ? 'product_id' AND v_lo->>'product_id' IS DISTINCT FROM v_ql.product_id::text THEN RAISE EXCEPTION 'ORDER_LINES_INVALID'; END IF;
      v_product := v_ql.product_id;
    END IF;
    INSERT INTO public.sales_order_lines(organization_id,order_id,line_no,product_id,custom_notes,quantity,unit_price,discount_amount,
                                         tax_class_id,tax_rate,tax_amount,line_total,fulfilment,created_by)
    VALUES(v_org,v_o.id,v_ql.line_no,v_product,
           CASE WHEN v_ql.description IS NOT NULL AND v_ql.custom_notes IS NOT NULL THEN v_ql.description||' — '||v_ql.custom_notes
                ELSE COALESCE(v_ql.description,v_ql.custom_notes) END,
           v_ql.quantity,v_ql.unit_price,v_ql.discount_amount,v_ql.tax_class_id,v_ql.tax_rate,v_ql.tax_amount,v_ql.line_total,
           (app.s10_line_options(v_lo - 'product_id')->>'fulfilment')::public.fulfilment_mode,v_emp)
    RETURNING id INTO v_line;
    v_opts:=v_opts||jsonb_build_object(v_line::text,app.s10_line_options(v_lo - 'product_id'));
  END LOOP;
  PERFORM app.s10_fulfil(v_org,v_emp,v_o,v_opts);
  PERFORM app.write_audit('sales_order.created','sales_order',v_o.id,NULL,
    jsonb_build_object('number',v_o.number,'customer_id',v_o.customer_id,'total',v_o.total::text,'quotation_id',v_q.id),NULL,v_o.branch_id);
  RETURN public.get_sales_order(v_o.id);
END $$;

-- Decision 6.
CREATE FUNCTION public.link_order_line_to_po(p_order_line_id uuid, p_po_line_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid; v_emp uuid; v_o public.sales_orders; v_line public.sales_order_lines;
BEGIN
  v_emp:=app.require_permission('order.manage'); v_org:=app.current_org_id();
  SELECT o.* INTO v_o FROM public.sales_orders o JOIN public.sales_order_lines l ON l.order_id=o.id AND l.organization_id=o.organization_id
   WHERE l.id=p_order_line_id AND l.organization_id=v_org;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  SELECT * INTO v_o FROM public.sales_orders WHERE id=v_o.id AND organization_id=v_org FOR UPDATE;
  PERFORM app.require_branch_access(v_o.branch_id);
  IF v_o.status<>'open' THEN RAISE EXCEPTION 'ORDER_NOT_OPEN'; END IF;
  SELECT * INTO v_line FROM public.sales_order_lines WHERE id=p_order_line_id AND organization_id=v_org FOR UPDATE;
  IF v_line.fulfilment<>'to_order' THEN RAISE EXCEPTION 'LINE_NOT_TO_ORDER'; END IF;
  IF p_po_line_id IS NULL THEN RAISE EXCEPTION 'VALIDATION_FAILED'; END IF;
  PERFORM app.s10_link(v_org,v_line,p_po_line_id);
  PERFORM app.write_audit('sales_order.line_linked','sales_order',v_o.id,
    jsonb_build_object('order_line_id',v_line.id,'po_line_id',v_line.po_line_id),
    jsonb_build_object('order_line_id',v_line.id,'po_line_id',p_po_line_id),NULL,v_o.branch_id);
  RETURN public.get_sales_order(v_o.id);
END $$;

-- Decision 7.
CREATE FUNCTION public.reserve_order_line(p_order_line_id uuid, p_unit_ids uuid[] DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid; v_emp uuid; v_o public.sales_orders; v_line public.sales_order_lines;
BEGIN
  v_emp:=app.require_permission('order.manage'); v_org:=app.current_org_id();
  SELECT o.* INTO v_o FROM public.sales_orders o JOIN public.sales_order_lines l ON l.order_id=o.id AND l.organization_id=o.organization_id
   WHERE l.id=p_order_line_id AND l.organization_id=v_org;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  SELECT * INTO v_o FROM public.sales_orders WHERE id=v_o.id AND organization_id=v_org FOR UPDATE;
  PERFORM app.require_branch_access(v_o.branch_id);
  IF v_o.status<>'open' THEN RAISE EXCEPTION 'ORDER_NOT_OPEN'; END IF;
  SELECT * INTO v_line FROM public.sales_order_lines WHERE id=p_order_line_id AND organization_id=v_org FOR UPDATE;
  IF v_line.fulfilment<>'to_order' OR EXISTS(SELECT 1 FROM public.stock_reservations r
       WHERE r.order_line_id=v_line.id AND r.organization_id=v_org AND r.status='active') THEN
    RAISE EXCEPTION 'LINE_NOT_TO_ORDER';
  END IF;
  PERFORM 1 FROM public.units u WHERE u.organization_id=v_org AND u.id=ANY(COALESCE(p_unit_ids,'{}')) ORDER BY u.id FOR UPDATE;
  PERFORM app.s10_reserve_line(v_org,v_emp,v_line,v_o.branch_id,p_unit_ids);
  UPDATE public.sales_order_lines SET fulfilment='from_stock' WHERE id=v_line.id AND organization_id=v_org;
  PERFORM app.write_audit('sales_order.line_reserved','sales_order',v_o.id,
    jsonb_build_object('order_line_id',v_line.id,'fulfilment','to_order'),
    jsonb_build_object('order_line_id',v_line.id,'fulfilment','from_stock','unit_ids',to_jsonb(COALESCE(p_unit_ids,'{}'))),NULL,v_o.branch_id);
  RETURN public.get_sales_order(v_o.id);
END $$;

-- Decision 10.
CREATE FUNCTION public.list_sales_orders(p_status text DEFAULT NULL, p_branch_id uuid DEFAULT NULL, p_customer_id uuid DEFAULT NULL,
                                         p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_search text DEFAULT NULL,
                                         p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid; v_result jsonb;
BEGIN
  PERFORM app.require_permission('order.manage'); v_org:=app.current_org_id();
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR p_offset IS NULL OR p_offset<0 THEN RAISE EXCEPTION 'VALIDATION_FAILED'; END IF;
  IF p_status IS NOT NULL AND p_status NOT IN ('open','partially_delivered','delivered','cancelled') THEN RAISE EXCEPTION 'VALIDATION_FAILED'; END IF;
  IF p_branch_id IS NOT NULL AND NOT app.has_branch_access(p_branch_id) THEN RAISE EXCEPTION 'BRANCH_DENIED'; END IF;
  WITH filtered AS (
    SELECT o.id,o.created_at FROM public.sales_orders o JOIN public.customers c ON c.id=o.customer_id AND c.organization_id=v_org
    WHERE o.organization_id=v_org AND app.has_branch_access(o.branch_id)
      AND (p_status IS NULL OR o.status::text=p_status)
      AND (p_branch_id IS NULL OR o.branch_id=p_branch_id) AND (p_customer_id IS NULL OR o.customer_id=p_customer_id)
      AND (p_from IS NULL OR (o.created_at AT TIME ZONE (SELECT timezone FROM public.organizations WHERE id=v_org))::date>=p_from)
      AND (p_to IS NULL OR (o.created_at AT TIME ZONE (SELECT timezone FROM public.organizations WHERE id=v_org))::date<=p_to)
      AND (p_search IS NULL OR o.number ILIKE '%'||p_search||'%' OR c.full_name ILIKE '%'||p_search||'%' OR EXISTS(SELECT 1 FROM unnest(c.phones) ph WHERE ph ILIKE '%'||p_search||'%'))
  ) SELECT jsonb_build_object('total',(SELECT count(*) FROM filtered),'items',COALESCE((SELECT jsonb_agg(public.get_sales_order(f.id) ORDER BY f.created_at DESC,f.id DESC) FROM (SELECT * FROM filtered ORDER BY created_at DESC,id DESC LIMIT p_limit OFFSET p_offset) f),'[]'::jsonb)) INTO v_result;
  RETURN v_result;
END $$;

-- Reads by org (baseline <table>_tenant_read) AND branch access (missing until now).
CREATE POLICY sales_orders_branch_read ON public.sales_orders AS RESTRICTIVE FOR SELECT TO authenticated
  USING (app.has_branch_access(branch_id));
CREATE POLICY sales_order_lines_branch_read ON public.sales_order_lines AS RESTRICTIVE FOR SELECT TO authenticated
  USING (EXISTS(SELECT 1 FROM public.sales_orders o WHERE o.id=order_id AND o.organization_id=sales_order_lines.organization_id AND app.has_branch_access(o.branch_id)));
CREATE POLICY stock_reservations_branch_read ON public.stock_reservations AS RESTRICTIVE FOR SELECT TO authenticated
  USING (app.has_branch_access(branch_id));
REVOKE INSERT, UPDATE, DELETE ON public.sales_orders, public.sales_order_lines, public.stock_reservations, public.payments, public.payment_allocations FROM anon, authenticated;

REVOKE ALL ON FUNCTION app.s10_line_options(jsonb), app.s10_price(jsonb,boolean),
  app.s10_reserve_line(uuid,uuid,public.sales_order_lines,uuid,uuid[]), app.s10_link(uuid,public.sales_order_lines,uuid),
  app.s10_fulfil(uuid,uuid,public.sales_orders,jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION app.check_stock_movement() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_sales_order(uuid), public.create_sales_order(uuid,uuid,text,text,jsonb,text),
  public.create_order_from_quotation(uuid,text,jsonb,text), public.link_order_line_to_po(uuid,uuid),
  public.reserve_order_line(uuid,uuid[]), public.list_sales_orders(text,uuid,uuid,date,date,text,integer,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_sales_order(uuid), public.create_sales_order(uuid,uuid,text,text,jsonb,text),
  public.create_order_from_quotation(uuid,text,jsonb,text), public.link_order_line_to_po(uuid,uuid),
  public.reserve_order_line(uuid,uuid[]), public.list_sales_orders(text,uuid,uuid,date,date,text,integer,integer) TO authenticated;

-- ================================================================ part 2: deposits and cancelling
-- Decisions 8 and 9. S02's payment-line parser, shop checks and numbering are reused; its posting
-- step is sale-bound, so the ledger rows are written here as N03 does (S02 row shapes). p_direction
-- 'in' = deposit (cash/bank +, store credit -), 'out' = refund (cash/bank -, store credit +). The
-- cash and store-credit triggers refuse a negative drawer / balance. Offline: online only, like N03.
CREATE FUNCTION app.s10_post_order_payments(p_org uuid, p_emp uuid, p_order public.sales_orders, p_shift public.shifts,
                                            p_payments jsonb, p_direction text, p_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r record; v_branch uuid := COALESCE(p_shift.branch_id, p_order.branch_id); v_date date := app.org_today(p_org);
  v_sign numeric := CASE p_direction WHEN 'in' THEN 1 ELSE -1 END; v_account uuid; v_pid uuid; v_number text;
  v_balance numeric; v_out jsonb := '[]';
BEGIN
  PERFORM app.require_permission(CASE p_direction WHEN 'in' THEN 'order.manage' ELSE 'order.cancel' END);
  PERFORM app.sale_payments_check(p_org, v_branch, p_order.customer_id, p_payments);
  PERFORM 1 FROM public.cash_accounts ca WHERE ca.organization_id=p_org
     AND ca.id IN (SELECT l.cash_account_id FROM app.sale_payments_input(p_payments) l WHERE l.cash_account_id IS NOT NULL)
   ORDER BY ca.id FOR SHARE;
  FOR r IN SELECT * FROM app.sale_payments_input(p_payments) ORDER BY line_no LOOP
    v_account := CASE r.method WHEN 'cash' THEN p_shift.drawer_account_id WHEN 'bank_transfer' THEN r.cash_account_id END;
    IF r.method='store_credit' AND p_direction='in' THEN
      SELECT b.balance INTO v_balance FROM public.store_credit_balances b WHERE b.customer_id=p_order.customer_id FOR UPDATE;
      v_balance := COALESCE(v_balance,0);
      IF v_balance<r.amount THEN
        RAISE EXCEPTION 'INSUFFICIENT_STORE_CREDIT: the balance is %', v_balance USING ERRCODE='P0001',
          DETAIL=jsonb_build_object('balance',v_balance::numeric(18,2)::text)::text;
      END IF;
    END IF;
    v_number := app.next_document_number(p_org, v_branch, 'payment');
    INSERT INTO public.payments(organization_id,number,branch_id,direction,method,amount,customer_id,cash_account_id,shift_id,
                                reference,tendered,received_by,business_date,idempotency_key,created_by)
    VALUES(p_org,v_number,v_branch,p_direction::public.payment_direction,r.method::public.payment_method,r.amount,p_order.customer_id,
           v_account,p_shift.id,r.reference,CASE WHEN p_direction='in' AND r.method='cash' THEN r.tendered END,p_emp,v_date,
           CASE WHEN r.line_no=1 THEN p_key ELSE 'system:order:'||md5(p_key)||':'||r.line_no END,p_emp)
    RETURNING id INTO v_pid;
    INSERT INTO public.payment_allocations(organization_id,payment_id,amount,order_id,created_by) VALUES(p_org,v_pid,r.amount,p_order.id,p_emp);
    IF r.method='store_credit' THEN
      INSERT INTO public.store_credit_movements(organization_id,customer_id,amount,source_type,source_id,branch_id,business_date,created_by,created_at)
      VALUES(p_org,p_order.customer_id,-v_sign*r.amount,'payment',v_pid,v_branch,v_date,p_emp,clock_timestamp());
    ELSE
      -- K02: only drawer rows carry the shift.
      INSERT INTO public.cash_movements(organization_id,cash_account_id,branch_id,shift_id,amount,type,source_type,source_id,note,business_date,created_by,created_at)
      VALUES(p_org,v_account,v_branch,CASE WHEN r.method='cash' THEN p_shift.id END,v_sign*r.amount,
             CASE p_direction WHEN 'in' THEN 'deposit' ELSE 'refund' END::public.cash_movement_type,'payment',v_pid,
             left(concat_ws(' ',v_number,p_order.number,r.reference),200),v_date,p_emp,clock_timestamp());
    END IF;
    v_out := v_out || jsonb_build_object('number',v_number,'method',r.method,'amount',r.amount::numeric(18,2)::text,
                                         'cash_account_id',v_account,'reference',r.reference);
  END LOOP;
  RETURN v_out;
END $$;

-- The caller's open shift, locked, on this device (as S02 post_sale).
CREATE FUNCTION app.s10_shift(p_org uuid, p_emp uuid, p_perm text) RETURNS public.shifts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_shift public.shifts;
BEGIN
  PERFORM app.require_permission(p_perm);
  v_shift := app.require_open_shift(p_org, p_emp);
  SELECT * INTO v_shift FROM public.shifts WHERE id=v_shift.id FOR UPDATE;
  IF v_shift.status<>'open' THEN RAISE EXCEPTION 'SHIFT_CLOSED' USING ERRCODE='P0001'; END IF;
  PERFORM app.require_shift_device(v_shift.id);
  RETURN v_shift;
END $$;

-- Decision 8.
CREATE FUNCTION public.record_order_deposit(p_order_id uuid, p_payments jsonb, p_idempotency_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid; v_emp uuid; v_o public.sales_orders; v_b public.v_order_balances; v_sum numeric; v_shift public.shifts; v_posted jsonb;
BEGIN
  v_emp:=app.require_permission('order.manage'); v_org:=app.current_org_id();
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'VALIDATION_FAILED'; END IF;
  PERFORM app.lock_idempotency_key(v_org,p_idempotency_key);
  SELECT * INTO v_o FROM public.sales_orders WHERE id=p_order_id AND organization_id=v_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  PERFORM app.require_branch_access(v_o.branch_id);
  IF EXISTS(SELECT 1 FROM public.payments p JOIN public.payment_allocations a ON a.payment_id=p.id AND a.organization_id=p.organization_id
            WHERE p.organization_id=v_org AND p.idempotency_key=p_idempotency_key AND a.order_id=v_o.id) THEN
    RETURN public.get_sales_order(v_o.id);
  END IF;
  IF v_o.status NOT IN ('open','partially_delivered') THEN RAISE EXCEPTION 'ORDER_NOT_OPEN'; END IF;
  SELECT COALESCE(sum(l.amount),0) INTO v_sum FROM app.sale_payments_input(p_payments) l;
  SELECT * INTO v_b FROM public.v_order_balances WHERE order_id=v_o.id;
  IF v_b.deposits_paid+v_sum>v_b.total-v_b.delivered_value THEN
    RAISE EXCEPTION 'DEPOSIT_EXCEEDS_BALANCE' USING ERRCODE='P0001',
      DETAIL=jsonb_build_object('max',(v_b.total-v_b.delivered_value-v_b.deposits_paid)::numeric(18,2)::text)::text;
  END IF;
  v_shift:=app.s10_shift(v_org,v_emp,'order.manage');
  v_posted:=app.s10_post_order_payments(v_org,v_emp,v_o,v_shift,p_payments,'in',p_idempotency_key);
  PERFORM app.write_audit('sales_order.deposit','sales_order',v_o.id,NULL,
    jsonb_build_object('amount',v_sum::numeric(18,2)::text,'payments',v_posted),NULL,v_o.branch_id);
  RETURN public.get_sales_order(v_o.id);
END $$;

-- Decision 9. p_refund: '[]' when there are no deposits; else lines that add up to them exactly.
-- A shift (and this device) is needed only for a cash refund line.
CREATE FUNCTION public.cancel_sales_order(p_order_id uuid, p_reason text, p_refund jsonb, p_idempotency_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid; v_emp uuid; v_o public.sales_orders; v_dep numeric; v_sum numeric := 0; v_shift public.shifts; v_res record;
  v_refund jsonb := COALESCE(p_refund,'[]'::jsonb); v_posted jsonb := '[]'; v_reason text := btrim(p_reason);
  v_dep_cash_bank numeric := 0; v_ref_cash_bank numeric := 0;
BEGIN
  v_emp:=app.require_permission('order.cancel'); v_org:=app.current_org_id();
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'VALIDATION_FAILED'; END IF;
  PERFORM app.lock_idempotency_key(v_org,p_idempotency_key);
  SELECT * INTO v_o FROM public.sales_orders WHERE id=p_order_id AND organization_id=v_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  PERFORM app.require_branch_access(v_o.branch_id);
  IF v_o.status='cancelled' AND EXISTS(SELECT 1 FROM public.audit_log l WHERE l.organization_id=v_org AND l.entity_id=v_o.id
       AND l.action='sales_order.cancelled' AND l.after->>'idempotency_key'=p_idempotency_key) THEN
    RETURN public.get_sales_order(v_o.id);
  END IF;
  IF v_o.status='partially_delivered' THEN RAISE EXCEPTION 'ORDER_HAS_DELIVERIES'; END IF;
  IF v_o.status<>'open' THEN RAISE EXCEPTION 'ORDER_NOT_OPEN'; END IF;
  IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 500 THEN RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
  IF jsonb_typeof(v_refund)<>'array' THEN RAISE EXCEPTION 'VALIDATION_FAILED: refund'; END IF;
  SELECT deposits_paid INTO v_dep FROM public.v_order_balances WHERE order_id=v_o.id;
  IF jsonb_array_length(v_refund)>0 THEN
    SELECT sum(l.amount) INTO v_sum FROM app.sale_payments_input(v_refund) l;
  END IF;
  IF v_sum<>v_dep OR (v_dep=0 AND jsonb_array_length(v_refund)>0) THEN
    RAISE EXCEPTION 'REFUND_MUST_EQUAL_DEPOSITS' USING ERRCODE='P0001',
      DETAIL=jsonb_build_object('deposits',v_dep::numeric(18,2)::text,'refund',v_sum::numeric(18,2)::text)::text;
  END IF;
  -- A store-credit deposit goes back only as store credit: the cash + bank refund lines can't exceed the
  -- net deposits paid in cash + bank (read under the order lock). Cash/bank deposits may go back any way.
  IF v_sum>0 THEN
    SELECT COALESCE(sum(CASE WHEN p.direction='in' THEN a.amount ELSE -a.amount END),0) INTO v_dep_cash_bank
      FROM public.payment_allocations a JOIN public.payments p ON p.id=a.payment_id AND p.organization_id=a.organization_id
     WHERE a.order_id=v_o.id AND a.organization_id=v_org AND p.method IN ('cash','bank_transfer');
    SELECT COALESCE(sum(l.amount),0) INTO v_ref_cash_bank FROM app.sale_payments_input(v_refund) l WHERE l.method IN ('cash','bank_transfer');
    IF v_ref_cash_bank>v_dep_cash_bank THEN
      RAISE EXCEPTION 'REFUND_METHOD_NOT_ALLOWED' USING ERRCODE='P0001',
        DETAIL=jsonb_build_object('cash_bank_max',greatest(v_dep_cash_bank,0)::numeric(18,2)::text,'cash_bank_refund',v_ref_cash_bank::numeric(18,2)::text)::text;
    END IF;
  END IF;
  IF v_sum>0 AND EXISTS(SELECT 1 FROM app.sale_payments_input(v_refund) l WHERE l.method='cash') THEN
    v_shift:=app.s10_shift(v_org,v_emp,'order.cancel');
  END IF;
  FOR v_res IN SELECT r.id FROM public.stock_reservations r JOIN public.sales_order_lines l ON l.id=r.order_line_id AND l.organization_id=r.organization_id
               WHERE l.order_id=v_o.id AND r.organization_id=v_org AND r.status='active' ORDER BY r.product_id,r.id FOR UPDATE OF r LOOP
    UPDATE public.stock_reservations SET status='released',released_at=now(),updated_at=now(),updated_by=v_emp WHERE id=v_res.id;
  END LOOP;
  IF v_sum>0 THEN
    v_posted:=app.s10_post_order_payments(v_org,v_emp,v_o,v_shift,v_refund,'out',p_idempotency_key);
  END IF;
  UPDATE public.sales_orders SET status='cancelled',cancelled_reason=v_reason,updated_at=now(),updated_by=v_emp WHERE id=v_o.id AND organization_id=v_org;
  PERFORM app.write_audit('sales_order.cancelled','sales_order',v_o.id,jsonb_build_object('status',v_o.status),
    jsonb_build_object('status','cancelled','refund_total',v_sum::numeric(18,2)::text,'refunds',v_posted,'idempotency_key',p_idempotency_key),
    v_reason,v_o.branch_id);
  RETURN public.get_sales_order(v_o.id);
END $$;

REVOKE ALL ON FUNCTION app.s10_post_order_payments(uuid,uuid,public.sales_orders,public.shifts,jsonb,text,text),
  app.s10_shift(uuid,uuid,text), public.record_order_deposit(uuid,jsonb,text), public.cancel_sales_order(uuid,text,jsonb,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_order_deposit(uuid,jsonb,text), public.cancel_sales_order(uuid,text,jsonb,text) TO authenticated;
