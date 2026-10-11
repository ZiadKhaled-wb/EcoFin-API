-- =============================================================================
-- S03 · Discounts (EC-70, D65)
--
-- A line can carry a discount (an amount or a percent of its gross) and the whole sale can carry
-- one (an amount or a percent of the net subtotal after the line discounts). The order is fixed:
-- line discounts first, then the sale discount is spread over the lines by their net after the
-- line discount (largest remainder in piasters, ties to the lower line), so the parts add up
-- exactly. T01 then taxes each line on its discounted amount. Every line's effective percent
-- (its whole discount / its gross) must be within the caller's cap (org_settings.discount_caps
-- by role; OWNER none; a role not listed 0): above it needs discount.above_cap, or an approval
-- that a manager gave from their own session: a request that stores the cart's fingerprint
-- (SHA-256 over the sorted lines and the discounts, computed here and nowhere else), valid for
-- 15 minutes, for the requester, branch and cart it was asked for, and for ONE sale (the sale's
-- id goes into approvals.entity_id in the sale's transaction). Any discount needs a reason.
--
-- A line's discount is within the cap when it is at most the cap's percent of the gross rounded
-- half-up to the piaster, the same rule that turned a percent into an amount (5 % of 33.33 is
-- 1.67 and is allowed at a 5 % cap).
--
-- The sale functions gain optional parameters at the end; the discount logic lives in the helpers.
-- approvals is the baseline table: only its freeze trigger changes, to let the one sale id be
-- written on an approved discount approval. No table or column changes.
-- =============================================================================

-- 1. The approval row may be used once after it is decided --------------------------------------------

DROP TRIGGER trg_approvals_final ON public.approvals;
CREATE FUNCTION app.approvals_freeze()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    IF OLD.status IN ('approved', 'rejected', 'cancelled') THEN
        -- The one change after the decision: an approved discount approval is used by a sale.
        IF OLD.kind = 'discount_above_cap' AND OLD.status = 'approved'
           AND OLD.entity_id IS NULL AND NEW.entity_id IS NOT NULL
           AND (to_jsonb(NEW) - 'entity_id' - 'updated_at') = (to_jsonb(OLD) - 'entity_id' - 'updated_at') THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'DOCUMENT_FINAL: %.% is % and can no longer change',
            TG_TABLE_SCHEMA, TG_TABLE_NAME, OLD.status USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_approvals_final BEFORE UPDATE ON public.approvals
    FOR EACH ROW EXECUTE FUNCTION app.approvals_freeze();

-- 2. Helpers (schema app, no grants) -------------------------------------------------------------------

-- p_total split over the weights by largest remainder, in piasters; the parts add up to p_total
-- exactly and a tie goes to the lower index. Same method as the T01 engine's document discount.
CREATE FUNCTION app.allocate_amount(p_total numeric, p_weights numeric[])
RETURNS numeric[] LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE
    v_n integer := COALESCE(array_length(p_weights, 1), 0); v_w numeric := 0; v_pias numeric;
    v_floor numeric[] := '{}'; v_rem numeric[] := '{}'; v_left integer; v_out numeric[] := '{}'; i integer;
BEGIN
    IF v_n = 0 OR p_total IS NULL OR p_total < 0 OR p_total <> round(p_total, 2) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: allocation' USING ERRCODE = 'P0001';
    END IF;
    FOR i IN 1..v_n LOOP
        IF p_weights[i] IS NULL OR p_weights[i] < 0 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: allocation' USING ERRCODE = 'P0001';
        END IF;
        v_w := v_w + p_weights[i];
    END LOOP;
    IF v_w = 0 THEN
        IF p_total <> 0 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: allocation' USING ERRCODE = 'P0001';
        END IF;
        RETURN array_fill(0::numeric, ARRAY[v_n]);
    END IF;
    v_pias := p_total * 100;
    FOR i IN 1..v_n LOOP
        v_floor := v_floor || div(v_pias * p_weights[i], v_w);
        v_rem := v_rem || (v_pias * p_weights[i] - v_floor[i] * v_w);
    END LOOP;
    v_left := (v_pias - (SELECT sum(f) FROM unnest(v_floor) f))::integer;
    FOR i IN SELECT o FROM unnest(v_rem) WITH ORDINALITY u(r, o) ORDER BY r DESC, o LIMIT v_left LOOP
        v_floor[i] := v_floor[i] + 1;
    END LOOP;
    FOR i IN 1..v_n LOOP
        v_out := v_out || (v_floor[i] / 100);
    END LOOP;
    RETURN v_out;
END;
$$;

-- A discount object {type: 'amount'|'percent', value} as an amount of p_base (a percent is
-- rounded half-up to 2 decimals). NULL or JSON null = none. Negative, a percent above 100, more
-- than p_base, an unknown key or type = DISCOUNT_INVALID.
CREATE FUNCTION app.discount_value(p_d jsonb, p_base numeric)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v_type text; v_val text; v_amt numeric;
BEGIN
    IF p_d IS NULL OR p_d = 'null'::jsonb THEN
        RETURN 0;
    END IF;
    IF jsonb_typeof(p_d) <> 'object'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_d) k WHERE k NOT IN ('type', 'value'))
       OR jsonb_typeof(p_d -> 'type') IS DISTINCT FROM 'string'
       OR COALESCE(jsonb_typeof(p_d -> 'value'), 'null') NOT IN ('string', 'number') THEN
        RAISE EXCEPTION 'DISCOUNT_INVALID' USING ERRCODE = 'P0001';
    END IF;
    v_type := p_d ->> 'type';
    v_val := p_d ->> 'value';
    IF v_type NOT IN ('amount', 'percent') OR v_val !~ '^\d{1,16}(\.\d{1,2})?$'
       OR (v_type = 'percent' AND v_val::numeric > 100) THEN
        RAISE EXCEPTION 'DISCOUNT_INVALID' USING ERRCODE = 'P0001';
    END IF;
    v_amt := CASE v_type WHEN 'percent' THEN round(p_base * v_val::numeric / 100, 2) ELSE v_val::numeric END;
    IF v_amt > p_base THEN
        RAISE EXCEPTION 'DISCOUNT_INVALID' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_amt;
END;
$$;

-- The discounts of a cart, pure: p_lines [{line_no, unit_price, quantity, discount?}], p_sale_discount
-- an object or NULL. Line discounts first (on the line's gross), then the sale discount (on the net
-- subtotal) spread by the lines' net. Returns {lines: [{line_no, gross, line_discount,
-- discount_amount, effective_pct}], sale_discount, discount_total, max_effective_pct}; money and
-- percents as 2-decimal strings. No tax here (T01 does that on discount_amount).
CREATE FUNCTION app.apply_discounts(p_lines jsonb, p_sale_discount jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE
    v_n integer := jsonb_array_length(p_lines); v_gross numeric[] := '{}'; v_ld numeric[] := '{}';
    v_net numeric[] := '{}'; v_net_sub numeric := 0; v_sale numeric; v_share numeric[]; v_out jsonb := '[]';
    v_total numeric := 0; v_max numeric := 0; v_pct numeric; v_disc numeric; i integer; v_l jsonb;
BEGIN
    FOR i IN 1..v_n LOOP
        v_l := p_lines -> (i - 1);
        v_gross := v_gross || ((v_l ->> 'unit_price')::numeric * (v_l ->> 'quantity')::numeric);
        v_ld := v_ld || app.discount_value(v_l -> 'discount', v_gross[i]);
        v_net := v_net || (v_gross[i] - v_ld[i]);
        v_net_sub := v_net_sub + v_net[i];
    END LOOP;
    v_sale := app.discount_value(p_sale_discount, v_net_sub);
    v_share := app.allocate_amount(v_sale, v_net);
    FOR i IN 1..v_n LOOP
        v_disc := v_ld[i] + v_share[i];
        v_pct := CASE WHEN v_gross[i] = 0 THEN 0 ELSE round(v_disc * 100 / v_gross[i], 2) END;
        v_total := v_total + v_disc;
        v_max := greatest(v_max, v_pct);
        v_out := v_out || jsonb_build_object(
            'line_no', (p_lines -> (i - 1) ->> 'line_no')::integer, 'gross', v_gross[i]::numeric(18,2)::text,
            'line_discount', v_ld[i]::numeric(18,2)::text, 'discount_amount', v_disc::numeric(18,2)::text,
            'effective_pct', v_pct::numeric(18,2)::text);
    END LOOP;
    RETURN jsonb_build_object('lines', v_out, 'sale_discount', v_sale::numeric(18,2)::text,
        'discount_total', v_total::numeric(18,2)::text, 'max_effective_pct', v_max::numeric(18,2)::text);
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'DISCOUNT_INVALID' USING ERRCODE = 'P0001';
END;
$$;

-- The cart's fingerprint: SHA-256 (hex) over the lines sorted by (product, unit, quantity, line
-- discount) and the sale discount. Server side only; the client never sends one.
CREATE FUNCTION app.cart_fingerprint(p_lines jsonb, p_sale_discount jsonb)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT encode(sha256(convert_to(
        COALESCE((SELECT string_agg(k.s, '|' ORDER BY k.s) FROM (
            SELECT concat_ws(',', l ->> 'product_id', COALESCE(l ->> 'unit_id', ''), l ->> 'quantity',
                             COALESCE(l -> 'discount' ->> 'type', ''),
                             COALESCE(((l -> 'discount' ->> 'value')::numeric)::numeric(18,2)::text, '')) AS s
            FROM jsonb_array_elements(p_lines) l) k), '')
        || '#' || COALESCE(p_sale_discount ->> 'type', '')
        || ',' || COALESCE(((p_sale_discount ->> 'value')::numeric)::numeric(18,2)::text, ''), 'UTF8')), 'hex')
$$;

-- The caller's discount cap in percent: NULL for OWNER (no cap), else the role's value in the
-- shop's discount_caps, 0 when the role is not listed (or the employee is unknown).
CREATE FUNCTION app.discount_cap_pct(p_employee uuid)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_e public.employees; v_cap numeric;
BEGIN
    SELECT * INTO v_e FROM public.employees e WHERE e.id = p_employee;
    IF NOT FOUND THEN
        RETURN 0;
    END IF;
    IF v_e.role = 'OWNER' THEN
        RETURN NULL;
    END IF;
    SELECT (s.discount_caps ->> v_e.role::text)::numeric INTO v_cap
    FROM public.org_settings s WHERE s.organization_id = v_e.organization_id;
    RETURN COALESCE(v_cap, 0);
END;
$$;

-- The first line (by line_no) of an app.apply_discounts result above the cap, as
-- {line_no, cap_pct, effective_pct}; NULL when every line is within it.
CREATE FUNCTION app.discount_over_cap(p_result jsonb, p_cap numeric)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object('line_no', (l ->> 'line_no')::integer, 'cap_pct', p_cap::numeric(18,2)::text,
                              'effective_pct', l ->> 'effective_pct')
    FROM jsonb_array_elements(p_result -> 'lines') l
    WHERE p_cap IS NOT NULL
      AND (l ->> 'discount_amount')::numeric > round((l ->> 'gross')::numeric * p_cap / 100, 2)
    ORDER BY (l ->> 'line_no')::integer LIMIT 1
$$;

-- Decision 3 and 4. Within the caller's cap (or OWNER, or discount.above_cap): returns NULL.
-- Above it without either: DISCOUNT_ABOVE_CAP, or, with an approval id, the approval is validated
-- and locked (the caller's own, approved, this branch, decided less than 15 minutes ago, unused,
-- same cart fingerprint) else APPROVAL_INVALID. Returns the approval's id when it is used; the
-- sale writes its id into it in the same transaction.
CREATE FUNCTION app.check_discount_allowed(p_branch_id uuid, p_result jsonb, p_fingerprint text,
                                           p_approval_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid := app.current_employee_id(); v_org uuid := app.current_org_id();
    v_cap numeric; v_over jsonb; v_a public.approvals;
BEGIN
    v_cap := app.discount_cap_pct(v_emp);
    v_over := app.discount_over_cap(p_result, v_cap);
    IF v_over IS NULL OR app.has_permission('discount.above_cap') THEN
        RETURN NULL;
    END IF;
    IF p_approval_id IS NULL THEN
        RAISE EXCEPTION 'DISCOUNT_ABOVE_CAP: line % is at %, the cap is %', v_over ->> 'line_no',
            v_over ->> 'effective_pct', v_over ->> 'cap_pct'
            USING ERRCODE = 'P0001', DETAIL = v_over::text;
    END IF;
    SELECT * INTO v_a FROM public.approvals a
    WHERE a.id = p_approval_id AND a.organization_id = v_org AND a.kind = 'discount_above_cap' FOR UPDATE;
    IF NOT FOUND OR v_a.status <> 'approved' OR v_a.branch_id IS DISTINCT FROM p_branch_id
       OR v_a.requested_by <> v_emp OR v_a.decided_at < now() - interval '15 minutes'
       OR v_a.entity_id IS NOT NULL OR v_a.payload ->> 'fingerprint' IS DISTINCT FROM p_fingerprint THEN
        RAISE EXCEPTION 'APPROVAL_INVALID' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_a.id;
END;
$$;

-- An approval in the contract's DiscountApproval shape.
CREATE FUNCTION app.discount_approval_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', a.id, 'status', a.status, 'branch_id', a.branch_id, 'branch_name', b.name,
        'requested_by_name', re.full_name, 'requested_at', a.created_at,
        'max_effective_pct', a.amount::numeric(18,2)::text, 'cap_pct', a.payload ->> 'cap_pct',
        'discount_total', a.payload ->> 'discount_total', 'reason', a.reason,
        'lines', COALESCE(a.payload -> 'lines', '[]'::jsonb),
        'decided_by_name', de.full_name, 'decided_at', a.decided_at, 'decision_note', a.decision_note,
        'used', a.entity_id IS NOT NULL)
    FROM public.approvals a
    LEFT JOIN public.branches b ON b.id = a.branch_id AND b.organization_id = a.organization_id
    LEFT JOIN public.employees re ON re.id = a.requested_by AND re.organization_id = a.organization_id
    LEFT JOIN public.employees de ON de.id = a.decided_by AND de.organization_id = a.organization_id
    WHERE a.organization_id = p_org AND a.id = p_id AND a.kind = 'discount_above_cap'
$$;

-- 3. The sale: lines may carry a discount ------------------------------------------------------------------

-- S01's line check, plus the optional `discount` key (its contents are checked by app.apply_discounts).
CREATE OR REPLACE FUNCTION app.sale_lines_input(p_lines jsonb)
RETURNS TABLE (line_no integer, product_id uuid, quantity integer, unit_id uuid, unit_price numeric)
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE
    v_line jsonb; v_qty numeric; v_price text; i integer;
BEGIN
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array'
       OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END IF;
    FOR i IN 1..jsonb_array_length(p_lines) LOOP
        v_line := p_lines -> (i - 1);
        IF jsonb_typeof(v_line) <> 'object'
           OR EXISTS (SELECT 1 FROM jsonb_object_keys(v_line) k
                      WHERE k NOT IN ('product_id', 'quantity', 'unit_id', 'unit_price', 'discount'))
           OR jsonb_typeof(v_line -> 'product_id') IS DISTINCT FROM 'string'
           OR jsonb_typeof(v_line -> 'quantity') IS DISTINCT FROM 'number'
           OR COALESCE(jsonb_typeof(v_line -> 'unit_id'), 'null') NOT IN ('string', 'null')
           OR COALESCE(jsonb_typeof(v_line -> 'unit_price'), 'null') NOT IN ('string', 'number', 'null')
           OR COALESCE(jsonb_typeof(v_line -> 'discount'), 'null') NOT IN ('object', 'null') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: line %', i USING ERRCODE = 'P0001';
        END IF;
        v_qty := (v_line ->> 'quantity')::numeric;
        v_price := v_line ->> 'unit_price';
        IF v_qty <> trunc(v_qty) OR v_qty NOT BETWEEN 1 AND 100000
           OR (v_price IS NOT NULL AND v_price !~ '^\d{1,16}(\.\d{1,2})?$')
           OR (v_line ->> 'unit_id' IS NOT NULL AND v_qty <> 1) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: line %', i USING ERRCODE = 'P0001';
        END IF;
        line_no := i;
        product_id := (v_line ->> 'product_id')::uuid;
        quantity := v_qty::integer;
        unit_id := (v_line ->> 'unit_id')::uuid;
        unit_price := v_price::numeric;
        RETURN NEXT;
    END LOOP;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
END;
$$;

-- The new signatures replace S02's: drop the old ones first.
DROP FUNCTION public.post_sale(jsonb, text, text, uuid, jsonb);
DROP FUNCTION public.quote_sale(jsonb, uuid, jsonb);
DROP FUNCTION app.post_sale_core(uuid, uuid, public.shifts, jsonb, uuid, numeric, text, jsonb);
DROP FUNCTION app.sale_cart(uuid, uuid, jsonb, boolean);

-- S01's cart, with the discounts: after every line is priced, app.apply_discounts gives each
-- line's discount (its own plus its share of the sale discount) and T01 taxes the discounted
-- amounts. Lines also carry discount_amount and effective_pct; the cart carries discount_total,
-- max_effective_pct and the whole `discount` result (for the cap check; the quote removes it).
CREATE FUNCTION app.sale_cart(p_org uuid, p_branch uuid, p_lines jsonb, p_can_override boolean,
                              p_sale_discount jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    r record; v_p public.products; v_u public.units; v_rate numeric; v_price numeric;
    v_inc boolean; v_available integer; v_tax jsonb; v_lines jsonb := '[]'; v_tax_lines jsonb := '[]';
    v_out jsonb := '[]'; v_disc_in jsonb := '[]'; v_res jsonb; i integer;
BEGIN
    IF EXISTS (SELECT 1 FROM app.sale_lines_input(p_lines) l WHERE l.unit_id IS NOT NULL
               GROUP BY l.unit_id HAVING count(*) > 1)
       OR EXISTS (SELECT 1 FROM app.sale_lines_input(p_lines) l
                  GROUP BY l.product_id HAVING count(*) > 1 AND bool_or(l.unit_id IS NULL)) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a product or a unit appears twice' USING ERRCODE = 'P0001';
    END IF;
    SELECT s.prices_include_vat INTO v_inc FROM public.org_settings s WHERE s.organization_id = p_org;

    FOR r IN SELECT * FROM app.sale_lines_input(p_lines) ORDER BY line_no LOOP
        SELECT * INTO v_p FROM public.products p WHERE p.id = r.product_id AND p.organization_id = p_org;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF v_p.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'PRODUCT_ARCHIVED: %', v_p.sku USING ERRCODE = 'P0001';
        END IF;

        v_u := NULL;
        IF v_p.is_serialized THEN
            IF r.unit_id IS NULL THEN
                RAISE EXCEPTION 'UNIT_REQUIRED: product % is serialized', v_p.sku USING ERRCODE = 'P0001';
            END IF;
            SELECT * INTO v_u FROM public.units u WHERE u.id = r.unit_id AND u.organization_id = p_org;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'UNIT_NOT_FOUND' USING ERRCODE = 'P0001';
            END IF;
            IF v_u.product_id <> v_p.id THEN
                RAISE EXCEPTION 'UNIT_PRODUCT_MISMATCH' USING ERRCODE = 'P0001';
            END IF;
            -- A reserved unit waits for its order (S10): a walk-in sale doesn't take it.
            IF v_u.branch_id <> p_branch OR v_u.status <> 'in_stock' THEN
                RAISE EXCEPTION 'UNIT_NOT_AVAILABLE: % is not in stock in this branch', v_u.serial
                    USING ERRCODE = 'P0001';
            END IF;
        ELSIF r.unit_id IS NOT NULL THEN
            RAISE EXCEPTION 'UNIT_NOT_ALLOWED: product % is not serialized', v_p.sku USING ERRCODE = 'P0001';
        END IF;

        v_price := v_p.cash_price;
        IF r.unit_price IS NOT NULL AND r.unit_price <> v_p.cash_price THEN
            IF NOT COALESCE(p_can_override, false) THEN
                RAISE EXCEPTION 'PRICE_OVERRIDE_DENIED: %', v_p.sku USING ERRCODE = '42501';
            END IF;
            v_price := r.unit_price;
        END IF;

        SELECT t.rate INTO v_rate FROM public.tax_classes t
        WHERE t.id = v_p.tax_class_id AND t.organization_id = p_org;
        SELECT COALESCE(sum(sl.on_hand - sl.reserved), 0)::integer INTO v_available
        FROM public.stock_levels sl
        WHERE sl.organization_id = p_org AND sl.product_id = v_p.id AND sl.branch_id = p_branch
          AND sl.stock_state = 'sellable';

        v_disc_in := v_disc_in || jsonb_build_object('line_no', r.line_no, 'unit_price', v_price::numeric(18,2)::text,
            'quantity', r.quantity, 'discount', p_lines -> (r.line_no - 1) -> 'discount');
        v_lines := v_lines || jsonb_build_object(
            'product_id', v_p.id, 'name_ar', v_p.name_ar, 'name_en', v_p.name_en, 'sku', v_p.sku,
            'is_serialized', v_p.is_serialized, 'unit_id', v_u.id, 'serial', v_u.serial,
            'quantity', r.quantity, 'list_price', v_p.cash_price::numeric(18,2)::text,
            'unit_price', v_price::numeric(18,2)::text, 'overridden', v_price <> v_p.cash_price,
            'tax_rate', v_rate::numeric(5,2)::text, 'available', v_available,
            'tax_class_id', v_p.tax_class_id, 'warranty_months', v_p.warranty_months,
            'unit_cost', CASE WHEN v_u.id IS NOT NULL THEN v_u.cost ELSE v_p.avg_cost END::numeric(18,4)::text);
    END LOOP;

    v_res := app.apply_discounts(v_disc_in, p_sale_discount);
    FOR i IN 0..jsonb_array_length(v_lines) - 1 LOOP
        v_tax_lines := v_tax_lines || jsonb_build_object('unit_price', v_lines -> i ->> 'unit_price',
            'quantity', (v_lines -> i ->> 'quantity')::integer,
            'line_discount', v_res -> 'lines' -> i ->> 'discount_amount', 'tax_rate', v_lines -> i ->> 'tax_rate');
    END LOOP;
    v_tax := app.compute_document_tax(jsonb_build_object(
        'prices_include_vat', v_inc, 'document_discount', '0', 'lines', v_tax_lines));
    FOR i IN 0..jsonb_array_length(v_lines) - 1 LOOP
        v_out := v_out || ((v_lines -> i) || jsonb_build_object(
            'discount_amount', v_res -> 'lines' -> i ->> 'discount_amount',
            'effective_pct', v_res -> 'lines' -> i ->> 'effective_pct',
            'tax_amount', v_tax -> 'lines' -> i ->> 'tax', 'line_total', v_tax -> 'lines' -> i ->> 'gross'));
    END LOOP;
    RETURN jsonb_build_object('prices_include_vat', v_inc, 'lines', v_out,
        'subtotal', v_tax ->> 'subtotal', 'discount_total', v_res ->> 'discount_total',
        'max_effective_pct', v_res ->> 'max_effective_pct', 'tax_total', v_tax ->> 'tax_total',
        'total', v_tax ->> 'total', 'discount', v_res);
END;
$$;

-- S02's sale JSON plus each line's discount_amount (its own and its share of the sale discount)
-- and the sale's discount_reason.
CREATE OR REPLACE FUNCTION app.sale_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', s.id, 'number', s.number, 'branch_id', s.branch_id, 'shift_id', s.shift_id,
        'shift_number', sh.number, 'customer_id', s.customer_id, 'customer_name', c.full_name,
        'prices_include_vat', s.prices_include_vat, 'subtotal', s.subtotal::text,
        'discount_total', s.discount_total::text, 'discount_reason', s.discount_reason,
        'tax_total', s.tax_total::text, 'total', s.total::text,
        'business_date', s.business_date, 'issued_at', s.issued_at, 'created_by_name', e.full_name,
        'lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', l.id, 'line_no', l.line_no, 'product_id', l.product_id, 'name_ar', p.name_ar,
                'name_en', p.name_en, 'sku', p.sku, 'is_serialized', p.is_serialized,
                'unit_id', l.unit_id, 'serial', u.serial, 'quantity', l.quantity,
                'unit_price', l.unit_price::text, 'discount_amount', l.discount_amount::text,
                'tax_rate', l.tax_rate::numeric(5,2)::text,
                'tax_amount', l.tax_amount::text, 'line_total', l.line_total::text,
                'warranty_until', l.warranty_until) ORDER BY l.line_no)
            FROM public.sale_lines l
            JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
            LEFT JOIN public.units u ON u.id = l.unit_id AND u.organization_id = l.organization_id
            WHERE l.organization_id = p_org AND l.sale_id = s.id), '[]'::jsonb),
        'payments', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', pay.id, 'number', pay.number, 'method', pay.method, 'amount', a.amount::text,
                'cash_account_id', pay.cash_account_id, 'cash_account_name', ca.name,
                'reference', pay.reference, 'tendered', pay.tendered::text,
                'change', (pay.tendered - a.amount)::numeric(18,2)::text) ORDER BY pay.number)
            FROM public.payment_allocations a
            JOIN public.payments pay ON pay.id = a.payment_id AND pay.organization_id = a.organization_id
            LEFT JOIN public.cash_accounts ca ON ca.id = pay.cash_account_id
                                             AND ca.organization_id = pay.organization_id
            WHERE a.organization_id = p_org AND a.sale_id = s.id), '[]'::jsonb),
        'paid_total', COALESCE((
            SELECT sum(a.amount) FROM public.payment_allocations a
            WHERE a.organization_id = p_org AND a.sale_id = s.id), 0)::numeric(18,2)::text,
        'change_total', COALESCE((
            SELECT sum(pay.tendered - a.amount) FROM public.payment_allocations a
            JOIN public.payments pay ON pay.id = a.payment_id AND pay.organization_id = a.organization_id
            WHERE a.organization_id = p_org AND a.sale_id = s.id), 0)::numeric(18,2)::text)
    FROM public.sales s
    LEFT JOIN public.shifts sh ON sh.id = s.shift_id AND sh.organization_id = s.organization_id
    LEFT JOIN public.customers c ON c.id = s.customer_id AND c.organization_id = s.organization_id
    LEFT JOIN public.employees e ON e.id = s.created_by AND e.organization_id = s.organization_id
    WHERE s.organization_id = p_org AND s.id = p_id
$$;

-- S02's sale core with the discounts. p_payments NULL = paid in cash in full (of the discounted total).
CREATE FUNCTION app.post_sale_core(p_org uuid, p_emp uuid, p_shift public.shifts, p_lines jsonb,
                                   p_customer_id uuid, p_expected_total numeric, p_idempotency_key text,
                                   p_payments jsonb DEFAULT NULL, p_sale_discount jsonb DEFAULT NULL,
                                   p_discount_reason text DEFAULT NULL, p_discount_approval_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_cart jsonb; v_line jsonb; v_total numeric(18,2); v_date date; v_sale public.sales; v_line_id uuid;
    v_cost numeric := 0; v_overrides jsonb; v_paid jsonb; i integer;
    v_discount numeric; v_reason text; v_approval uuid;
BEGIN
    PERFORM app.sale_customer(p_org, p_customer_id);

    -- Locks, always in the same order so two tills can't deadlock: the cart's units by id, then
    -- its stock rows by product id. (app.sale_lines_input has already refused a malformed cart.)
    PERFORM 1 FROM public.units u
    WHERE u.organization_id = p_org
      AND u.id IN (SELECT l.unit_id FROM app.sale_lines_input(p_lines) l WHERE l.unit_id IS NOT NULL)
    ORDER BY u.id FOR UPDATE;
    PERFORM 1 FROM public.stock_levels sl
    WHERE sl.organization_id = p_org AND sl.branch_id = p_shift.branch_id AND sl.stock_state = 'sellable'
      AND sl.product_id IN (SELECT l.product_id FROM app.sale_lines_input(p_lines) l)
    ORDER BY sl.product_id FOR UPDATE;

    -- Priced and checked on what is committed now (a new statement after the locks).
    v_cart := app.sale_cart(p_org, p_shift.branch_id, p_lines, app.has_permission('price.override'),
                            p_sale_discount);
    v_total := (v_cart ->> 'total')::numeric;
    v_discount := (v_cart ->> 'discount_total')::numeric;
    IF v_discount > 0 THEN
        v_reason := btrim(p_discount_reason);
        IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 200 THEN
            RAISE EXCEPTION 'DISCOUNT_REASON_REQUIRED' USING ERRCODE = 'P0001';
        END IF;
        v_approval := app.check_discount_allowed(p_shift.branch_id, v_cart -> 'discount',
                          app.cart_fingerprint(p_lines, p_sale_discount), p_discount_approval_id);
    END IF;
    IF v_total <= 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a sale must total more than 0' USING ERRCODE = 'P0001';
    END IF;
    IF p_expected_total IS NULL OR p_expected_total <> v_total THEN
        RAISE EXCEPTION 'PRICE_CHANGED: expected %, the total is %', p_expected_total, v_total
            USING ERRCODE = 'P0001',
                  DETAIL = jsonb_build_object('expected_total', p_expected_total::numeric(18,2)::text,
                                              'total', v_total::text)::text;
    END IF;
    -- Availability per product (a serialized product may be on several lines), on locked rows.
    SELECT jsonb_build_object('product_id', k.product_id, 'requested', k.requested, 'available', k.available,
                              'sku', k.sku)
    INTO v_line
    FROM (SELECT l ->> 'product_id' AS product_id, min(l ->> 'sku') AS sku,
                 sum((l ->> 'quantity')::integer)::integer AS requested,
                 min((l ->> 'available')::integer) AS available
          FROM jsonb_array_elements(v_cart -> 'lines') l GROUP BY 1) k
    WHERE k.requested > k.available
    ORDER BY k.product_id LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'OUT_OF_STOCK: % (asked %, available %)', v_line ->> 'sku',
                v_line ->> 'requested', v_line ->> 'available'
            USING ERRCODE = 'P0001', DETAIL = (v_line - 'sku')::text;
    END IF;
    SELECT sum((l ->> 'quantity')::integer * (l ->> 'unit_cost')::numeric) INTO v_cost
    FROM jsonb_array_elements(v_cart -> 'lines') l;

    -- Everything is checked: now the number, the document and the ledgers.
    v_date := app.org_today(p_org);
    INSERT INTO public.sales (organization_id, number, branch_id, device_id, shift_id, customer_id, kind,
                              is_b2b, prices_include_vat, subtotal, discount_total, discount_reason, tax_total,
                              total, cost_total, issued_at, business_date, idempotency_key, created_by)
    VALUES (p_org, app.next_document_number(p_org, p_shift.branch_id, 'sale'), p_shift.branch_id,
            p_shift.device_id, p_shift.id, p_customer_id, 'pos', false,
            (v_cart ->> 'prices_include_vat')::boolean, (v_cart ->> 'subtotal')::numeric, v_discount, v_reason,
            (v_cart ->> 'tax_total')::numeric, v_total, round(v_cost, 2), clock_timestamp(), v_date,
            p_idempotency_key, p_emp)
    RETURNING * INTO v_sale;

    FOR i IN 0..jsonb_array_length(v_cart -> 'lines') - 1 LOOP
        v_line := v_cart -> 'lines' -> i;
        INSERT INTO public.sale_lines (organization_id, sale_id, line_no, product_id, unit_id, quantity,
                                       unit_price, discount_amount, tax_class_id, tax_rate, tax_amount,
                                       line_total, unit_cost, warranty_until, created_by)
        VALUES (p_org, v_sale.id, i + 1, (v_line ->> 'product_id')::uuid, (v_line ->> 'unit_id')::uuid,
                (v_line ->> 'quantity')::integer, (v_line ->> 'unit_price')::numeric,
                (v_line ->> 'discount_amount')::numeric,
                (v_line ->> 'tax_class_id')::uuid, (v_line ->> 'tax_rate')::numeric,
                (v_line ->> 'tax_amount')::numeric, (v_line ->> 'line_total')::numeric,
                (v_line ->> 'unit_cost')::numeric,
                CASE WHEN (v_line ->> 'warranty_months')::integer > 0
                     THEN (v_date + make_interval(months => (v_line ->> 'warranty_months')::integer))::date END,
                p_emp)
        RETURNING id INTO v_line_id;
        -- The stock ledger: the trigger lowers the level (never below what is reserved) and
        -- marks a unit sold; it refuses again if anything slipped past the checks above.
        INSERT INTO public.stock_movements (organization_id, product_id, branch_id, unit_id, quantity, type,
                                            unit_cost, source_type, source_id, source_line_id, business_date,
                                            created_by, created_at)
        VALUES (p_org, (v_line ->> 'product_id')::uuid, p_shift.branch_id, (v_line ->> 'unit_id')::uuid,
                -(v_line ->> 'quantity')::integer, 'sale_out', (v_line ->> 'unit_cost')::numeric, 'sale',
                v_sale.id, v_line_id, v_date, p_emp, clock_timestamp());
    END LOOP;

    v_paid := app.post_sale_payments(v_sale, p_shift, p_emp, p_payments, v_total);

    -- The approval is spent by this sale, in this transaction: it can't be used again.
    IF v_approval IS NOT NULL THEN
        UPDATE public.approvals a SET entity_id = v_sale.id WHERE a.id = v_approval;
    END IF;

    SELECT jsonb_agg(jsonb_build_object('product_id', l ->> 'product_id', 'sku', l ->> 'sku',
                                        'list_price', l ->> 'list_price', 'unit_price', l ->> 'unit_price'))
    INTO v_overrides
    FROM jsonb_array_elements(v_cart -> 'lines') l WHERE (l ->> 'overridden')::boolean;
    PERFORM app.write_audit('sale.created', 'sale', v_sale.id, NULL,
        jsonb_build_object('number', v_sale.number, 'total', v_sale.total::text,
                           'tax_total', v_sale.tax_total::text,
                           'discount_total', v_sale.discount_total::text, 'discount_reason', v_sale.discount_reason,
                           'discount_approval_id', v_approval,
                           'lines', jsonb_array_length(v_cart -> 'lines'), 'customer_id', p_customer_id,
                           'shift_id', p_shift.id, 'price_overrides', COALESCE(v_overrides, '[]'::jsonb),
                           'payments', v_paid),
        NULL, v_sale.branch_id,
        CASE WHEN v_overrides IS NULL THEN 'info' ELSE 'warning' END::public.audit_severity);
    RETURN v_sale.id;
END;
$$;

-- A sale by the caller, in their open shift. p_expected_total is the total the cashier saw (after
-- the discounts). p_payments: the payment lines; NULL = paid in cash in full. p_sale_discount: the
-- whole-sale discount {type, value}; p_discount_reason is needed with any discount;
-- p_discount_approval_id: an approved over-cap request (see request_discount_approval).
CREATE FUNCTION public.post_sale(p_lines jsonb, p_expected_total text, p_idempotency_key text,
                                 p_customer_id uuid DEFAULT NULL, p_payments jsonb DEFAULT NULL,
                                 p_sale_discount jsonb DEFAULT NULL, p_discount_reason text DEFAULT NULL,
                                 p_discount_approval_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_existing uuid; v_shift public.shifts; v_expected numeric;
    v_payments jsonb := CASE WHEN p_payments = 'null'::jsonb THEN NULL ELSE p_payments END;
    v_discount jsonb := CASE WHEN p_sale_discount = 'null'::jsonb THEN NULL ELSE p_sale_discount END;
BEGIN
    v_emp := app.require_permission('sale.create');
    v_org := app.current_org_id();
    PERFORM app.require_module('pos');
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT s.id INTO v_existing FROM public.sales s
    WHERE s.organization_id = v_org AND s.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.sale_json(v_org, v_existing);             -- a repeat sells nothing
    END IF;

    IF p_expected_total IS NULL OR p_expected_total !~ '^\d{1,16}(\.\d{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: expected_total' USING ERRCODE = 'P0001';
    END IF;
    v_expected := p_expected_total::numeric;
    PERFORM app.sale_lines_input(p_lines);                   -- a malformed cart stops here
    IF v_payments IS NOT NULL THEN
        PERFORM app.sale_payments_input(v_payments);         -- so does a malformed payment list
    END IF;

    -- The caller's open shift, locked: it can't be closed while this sale is being written.
    v_shift := app.require_open_shift(v_org, v_emp);
    SELECT * INTO v_shift FROM public.shifts s WHERE s.id = v_shift.id FOR UPDATE;
    IF v_shift.status <> 'open' THEN
        RAISE EXCEPTION 'SHIFT_CLOSED: the shift is closed' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_shift.branch_id);

    -- Two statements on purpose: the read below must start after the sale is written (a STABLE
    -- function called in the same statement as the write would not see it).
    v_existing := app.post_sale_core(v_org, v_emp, v_shift, p_lines, p_customer_id, v_expected,
                                     p_idempotency_key, v_payments, v_discount, p_discount_reason,
                                     p_discount_approval_id);
    RETURN app.sale_json(v_org, v_existing);
END;
$$;

-- S02's quote with the discounts: the lines carry discount_amount and effective_pct, the quote
-- discount_total and max_effective_pct. The cap is not checked here (only the sale does that).
CREATE FUNCTION public.quote_sale(p_lines jsonb, p_customer_id uuid DEFAULT NULL, p_payments jsonb DEFAULT NULL,
                                  p_sale_discount jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid := app.current_employee_id(); v_org uuid; v_shift public.shifts; v_cart jsonb; v_total numeric;
    v_paid numeric; v_change numeric; v_balance numeric;
    v_payments jsonb := CASE WHEN p_payments = 'null'::jsonb THEN NULL ELSE p_payments END;
    v_discount jsonb := CASE WHEN p_sale_discount = 'null'::jsonb THEN NULL ELSE p_sale_discount END;
BEGIN
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('sale.create') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: sale.create' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    PERFORM app.require_module('pos');
    v_shift := app.require_open_shift(v_org, v_emp);
    PERFORM app.sale_customer(v_org, p_customer_id);
    v_cart := app.sale_cart(v_org, v_shift.branch_id, p_lines, app.has_permission('price.override'), v_discount);
    v_total := (v_cart ->> 'total')::numeric;
    IF v_payments IS NULL THEN
        v_paid := v_total;
        v_change := 0;
    ELSE
        PERFORM app.sale_payments_check(v_org, v_shift.branch_id, p_customer_id, v_payments);
        SELECT COALESCE(sum(l.amount), 0), COALESCE(sum(l.tendered - l.amount), 0) INTO v_paid, v_change
        FROM app.sale_payments_input(v_payments) l;
    END IF;
    IF p_customer_id IS NOT NULL THEN
        SELECT COALESCE((SELECT b.balance FROM public.store_credit_balances b
                         WHERE b.customer_id = p_customer_id AND b.organization_id = v_org), 0)
        INTO v_balance;
    END IF;
    RETURN jsonb_set(v_cart - 'discount', '{lines}', (
        SELECT jsonb_agg(l - 'tax_class_id' - 'unit_cost' - 'warranty_months' ORDER BY o)
        FROM jsonb_array_elements(v_cart -> 'lines') WITH ORDINALITY x(l, o)))
        || jsonb_build_object('paid', v_paid::numeric(18,2)::text,
                              'remaining', (v_total - v_paid)::numeric(18,2)::text,
                              'change', v_change::numeric(18,2)::text,
                              'store_credit_balance', v_balance::numeric(18,2)::text);
END;
$$;

-- 4. The approval of an over-cap discount ----------------------------------------------------------------

-- The cashier asks for an approval of exactly this cart (the server prices it, finds the highest
-- effective percent and stores the cart's fingerprint). Answers {approval_id, max_effective_pct,
-- cap_pct}. APPROVAL_NOT_NEEDED when no line is above the caller's cap (or the caller needs none).
CREATE FUNCTION public.request_discount_approval(p_branch_id uuid, p_lines jsonb, p_sale_discount jsonb,
                                                 p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_cart jsonb; v_cap numeric; v_over jsonb; v_reason text; v_id uuid;
    v_discount jsonb := CASE WHEN p_sale_discount = 'null'::jsonb THEN NULL ELSE p_sale_discount END;
    v_lines jsonb; v_payload jsonb;
BEGIN
    v_emp := app.require_permission('sale.create');
    v_org := app.current_org_id();
    PERFORM app.require_module('pos');
    PERFORM app.require_branch_access(p_branch_id);
    v_reason := btrim(p_reason);
    IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 200 THEN
        RAISE EXCEPTION 'DISCOUNT_REASON_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.sale_lines_input(p_lines);
    v_cart := app.sale_cart(v_org, p_branch_id, p_lines, app.has_permission('price.override'), v_discount);
    v_cap := app.discount_cap_pct(v_emp);
    v_over := app.discount_over_cap(v_cart -> 'discount', v_cap);
    IF v_over IS NULL OR app.has_permission('discount.above_cap') THEN
        RAISE EXCEPTION 'APPROVAL_NOT_NEEDED' USING ERRCODE = 'P0001';
    END IF;

    SELECT jsonb_agg(jsonb_build_object('product_id', l ->> 'product_id', 'sku', l ->> 'sku',
        'name_ar', l ->> 'name_ar', 'name_en', l ->> 'name_en', 'quantity', (l ->> 'quantity')::integer,
        'unit_price', l ->> 'unit_price', 'discount_amount', l ->> 'discount_amount',
        'effective_pct', l ->> 'effective_pct') ORDER BY o)
    INTO v_lines FROM jsonb_array_elements(v_cart -> 'lines') WITH ORDINALITY x(l, o);
    v_payload := jsonb_build_object('fingerprint', app.cart_fingerprint(p_lines, v_discount),
        'cap_pct', v_cap::numeric(18,2)::text, 'discount_total', v_cart ->> 'discount_total',
        'sale_discount', v_cart -> 'discount' ->> 'sale_discount', 'lines', v_lines);
    INSERT INTO public.approvals (organization_id, branch_id, kind, entity_type, amount, payload, requested_by,
                                  reason, created_by)
    VALUES (v_org, p_branch_id, 'discount_above_cap', 'sale', (v_cart ->> 'max_effective_pct')::numeric,
            v_payload, v_emp, v_reason, v_emp)
    RETURNING id INTO v_id;
    PERFORM app.write_audit('approval.requested', 'approval', v_id, NULL,
        jsonb_build_object('kind', 'discount_above_cap', 'max_effective_pct', v_cart ->> 'max_effective_pct',
                           'cap_pct', v_cap::numeric(18,2)::text, 'discount_total', v_cart ->> 'discount_total'),
        v_reason, p_branch_id);
    RETURN jsonb_build_object('approval_id', v_id, 'max_effective_pct', v_cart ->> 'max_effective_pct',
                              'cap_pct', v_cap::numeric(18,2)::text);
END;
$$;

-- A manager (discount.above_cap, with access to the branch, not the requester) approves or rejects.
CREATE FUNCTION public.decide_discount_approval(p_approval_id uuid, p_approve boolean, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_a public.approvals; v_note text; v_status public.approval_status;
BEGIN
    v_emp := app.require_permission('discount.above_cap');
    v_org := app.current_org_id();
    IF p_approve IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: approve' USING ERRCODE = 'P0001';
    END IF;
    v_note := NULLIF(btrim(p_note), '');
    IF length(v_note) > 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: note' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_a FROM public.approvals a
    WHERE a.id = p_approval_id AND a.organization_id = v_org AND a.kind = 'discount_above_cap' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'APPROVAL_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_a.branch_id);
    IF v_a.status <> 'pending' THEN
        RAISE EXCEPTION 'APPROVAL_NOT_PENDING: the approval is %', v_a.status USING ERRCODE = 'P0001';
    END IF;
    IF v_a.requested_by = v_emp THEN
        RAISE EXCEPTION 'APPROVAL_SELF' USING ERRCODE = '42501';
    END IF;
    v_status := CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END;
    UPDATE public.approvals a SET status = v_status, decided_by = v_emp, decided_at = now(), decision_note = v_note
    WHERE a.id = p_approval_id;
    PERFORM app.write_audit('approval.decided', 'approval', p_approval_id,
        jsonb_build_object('status', 'pending'),
        jsonb_build_object('kind', 'discount_above_cap', 'status', v_status, 'requested_by', v_a.requested_by,
                           'max_effective_pct', v_a.amount::numeric(18,2)::text),
        v_note, v_a.branch_id);
    RETURN jsonb_build_object('status', v_status);
END;
$$;

-- The requester takes the request back while it is pending.
CREATE FUNCTION public.cancel_discount_approval(p_approval_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_a public.approvals;
BEGIN
    v_emp := app.require_permission('sale.create');
    v_org := app.current_org_id();
    SELECT * INTO v_a FROM public.approvals a
    WHERE a.id = p_approval_id AND a.organization_id = v_org AND a.kind = 'discount_above_cap'
      AND a.requested_by = v_emp FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'APPROVAL_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_a.status <> 'pending' THEN
        RAISE EXCEPTION 'APPROVAL_NOT_PENDING: the approval is %', v_a.status USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.approvals a SET status = 'cancelled' WHERE a.id = p_approval_id;
    PERFORM app.write_audit('approval.cancelled', 'approval', p_approval_id,
        jsonb_build_object('status', 'pending'), jsonb_build_object('kind', 'discount_above_cap', 'status', 'cancelled'),
        NULL, v_a.branch_id);
    RETURN jsonb_build_object('status', 'cancelled');
END;
$$;

-- One approval (sale.create or discount.above_cap): the requester's own, or any of a branch the
-- caller can access with discount.above_cap.
CREATE FUNCTION public.get_discount_approval(p_approval_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid := app.current_employee_id(); v_org uuid; v_a public.approvals;
BEGIN
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT (app.has_permission('sale.create') OR app.has_permission('discount.above_cap')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: sale.create' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    SELECT * INTO v_a FROM public.approvals a
    WHERE a.id = p_approval_id AND a.organization_id = v_org AND a.kind = 'discount_above_cap';
    IF NOT FOUND OR NOT (v_a.requested_by = v_emp
                         OR (app.has_permission('discount.above_cap') AND app.has_branch_access(v_a.branch_id))) THEN
        RAISE EXCEPTION 'APPROVAL_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.discount_approval_json(v_org, p_approval_id);
END;
$$;

-- The over-cap requests of the branches the caller can access, newest first (at most 100).
CREATE FUNCTION public.list_discount_approvals(p_status text DEFAULT 'pending')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    PERFORM app.require_permission('discount.above_cap');
    v_org := app.current_org_id();
    IF p_status NOT IN ('pending', 'approved', 'rejected', 'cancelled') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: status' USING ERRCODE = 'P0001';
    END IF;
    RETURN jsonb_build_object('items', COALESCE((
        SELECT jsonb_agg(app.discount_approval_json(v_org, k.id) ORDER BY k.created_at DESC, k.id)
        FROM (SELECT a.id, a.created_at FROM public.approvals a
              WHERE a.organization_id = v_org AND a.kind = 'discount_above_cap' AND a.status::text = p_status
                AND app.has_branch_access(a.branch_id)
              ORDER BY a.created_at DESC, a.id LIMIT 100) k), '[]'::jsonb));
END;
$$;

-- 5. Grants ------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.approvals_freeze(), app.allocate_amount(numeric, numeric[]),
    app.discount_value(jsonb, numeric), app.apply_discounts(jsonb, jsonb), app.cart_fingerprint(jsonb, jsonb),
    app.discount_cap_pct(uuid), app.discount_over_cap(jsonb, numeric),
    app.check_discount_allowed(uuid, jsonb, text, uuid), app.discount_approval_json(uuid, uuid),
    app.sale_cart(uuid, uuid, jsonb, boolean, jsonb),
    app.post_sale_core(uuid, uuid, public.shifts, jsonb, uuid, numeric, text, jsonb, jsonb, text, uuid)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.post_sale(jsonb, text, text, uuid, jsonb, jsonb, text, uuid),
    public.quote_sale(jsonb, uuid, jsonb, jsonb), public.request_discount_approval(uuid, jsonb, jsonb, text),
    public.decide_discount_approval(uuid, boolean, text), public.cancel_discount_approval(uuid),
    public.get_discount_approval(uuid), public.list_discount_approvals(text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.post_sale(jsonb, text, text, uuid, jsonb, jsonb, text, uuid),
    public.quote_sale(jsonb, uuid, jsonb, jsonb), public.request_discount_approval(uuid, jsonb, jsonb, text),
    public.decide_discount_approval(uuid, boolean, text), public.cancel_discount_approval(uuid),
    public.get_discount_approval(uuid), public.list_discount_approvals(text)
    TO authenticated;
