-- T01 VAT engine (EC-89, D41). Default tax classes per shop, tax class management, the tax
-- calculation every posting function calls (app.compute_document_tax), the exact reversal for
-- returns (app.return_line_tax), and the accountant settings (markup, delivery fee, deposits).

-- 1. Accountant settings (defaults to be confirmed with the client's accountant) ---------------
ALTER TABLE public.org_settings
    -- VAT on installment markup: not taxed again (default) or taxed at the line's rate.
    ADD COLUMN installment_markup_vat text NOT NULL DEFAULT 'not_taxed'
        CHECK (installment_markup_vat IN ('not_taxed', 'taxed')),
    -- Class for delivery fees (default: the shop's standard class).
    ADD COLUMN delivery_fee_tax_class_id uuid,
    -- When an order deposit is taxed: when the goods are delivered (default) or when it's paid.
    ADD COLUMN deposit_vat_timing text NOT NULL DEFAULT 'on_delivery'
        CHECK (deposit_vat_timing IN ('on_delivery', 'on_deposit')),
    ADD CONSTRAINT org_settings_delivery_fee_tax_fk
        FOREIGN KEY (delivery_fee_tax_class_id, organization_id) REFERENCES public.tax_classes (id, organization_id);

-- 2. Default classes: standard 14%, zero-rated, exempt (ETA codes to be confirmed) --------------
CREATE FUNCTION app.seed_tax_classes(p_org uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_standard uuid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.tax_classes WHERE organization_id = p_org) THEN
        INSERT INTO public.tax_classes (organization_id, name, kind, rate, eta_tax_type, eta_subtype) VALUES
            (p_org, 'ضريبة القيمة المضافة 14%', 'standard', 14, 'T1', 'V009'),
            (p_org, 'خاضع بسعر صفر', 'zero', 0, 'T1', 'V001'),
            (p_org, 'معفى', 'exempt', 0, 'T1', 'V003');
    END IF;
    SELECT id INTO v_standard FROM public.tax_classes
    WHERE organization_id = p_org AND kind = 'standard' AND archived_at IS NULL
    ORDER BY created_at, id LIMIT 1;
    UPDATE public.org_settings SET
        default_tax_class_id = COALESCE(default_tax_class_id, v_standard),
        delivery_fee_tax_class_id = COALESCE(delivery_fee_tax_class_id, v_standard)
    WHERE organization_id = p_org;
END;
$$;

-- Every new shop gets them (P01 provisioning and the dev seeds both insert org_settings).
CREATE FUNCTION app.seed_tax_classes_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    PERFORM app.seed_tax_classes(NEW.organization_id);
    RETURN NULL;
END;
$$;
CREATE TRIGGER org_settings_seed_tax_classes AFTER INSERT ON public.org_settings
    FOR EACH ROW EXECUTE FUNCTION app.seed_tax_classes_trigger();

-- Existing shops.
SELECT app.seed_tax_classes(organization_id) FROM public.org_settings;

REVOKE ALL ON FUNCTION app.seed_tax_classes(uuid), app.seed_tax_classes_trigger() FROM PUBLIC, anon, authenticated;

-- 3. Tax class management (catalog.manage) -------------------------------------------------------
CREATE FUNCTION app.tax_class_json(t public.tax_classes)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object('id', t.id, 'name', t.name, 'kind', t.kind, 'rate', t.rate::text,
        'eta_tax_type', t.eta_tax_type, 'eta_subtype', t.eta_subtype,
        'archived_at', t.archived_at, 'updated_at', t.updated_at)
$$;
REVOKE ALL ON FUNCTION app.tax_class_json(public.tax_classes) FROM PUBLIC, anon, authenticated;

-- Any employee (the POS and product forms need them); archived ones last.
CREATE FUNCTION public.list_tax_classes()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    RETURN COALESCE((SELECT jsonb_agg(app.tax_class_json(t) ORDER BY t.archived_at NULLS FIRST, t.name, t.id)
                     FROM public.tax_classes t WHERE t.organization_id = app.current_org_id()), '[]'::jsonb);
END;
$$;

CREATE FUNCTION public.create_tax_class(p_name text, p_kind public.tax_kind, p_rate numeric,
                                        p_eta_tax_type text, p_eta_subtype text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_id uuid;
BEGIN
    v_emp := app.require_permission('catalog.manage');
    v_org := app.current_org_id();
    IF NULLIF(btrim(p_name), '') IS NULL OR length(btrim(p_name)) > 60 THEN
        RAISE EXCEPTION 'NAME_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.tax_classes WHERE organization_id = v_org AND name = btrim(p_name)) THEN
        RAISE EXCEPTION 'TAX_CLASS_NAME_TAKEN' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO public.tax_classes (organization_id, name, kind, rate, eta_tax_type, eta_subtype, created_by, updated_by)
    VALUES (v_org, btrim(p_name), p_kind, p_rate, btrim(p_eta_tax_type), btrim(p_eta_subtype), v_emp, v_emp)
    RETURNING id INTO v_id;
    PERFORM app.write_audit('tax_class.created', 'tax_class', v_id,
        p_after => (SELECT app.tax_class_json(t) FROM public.tax_classes t WHERE t.id = v_id));
    RETURN v_id;
EXCEPTION
    WHEN check_violation OR not_null_violation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: tax class' USING ERRCODE = 'P0001';
END;
$$;

-- Partial update. A new rate applies to new documents only: issued lines keep their snapshot.
CREATE FUNCTION public.update_tax_class(p_id uuid, p_changes jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_before public.tax_classes%ROWTYPE; v_key text; c jsonb := p_changes;
BEGIN
    v_emp := app.require_permission('catalog.manage');
    v_org := app.current_org_id();
    IF c IS NULL OR jsonb_typeof(c) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT k INTO v_key FROM jsonb_object_keys(c) k
    WHERE k <> ALL (ARRAY['name', 'kind', 'rate', 'eta_tax_type', 'eta_subtype']) LIMIT 1;
    IF v_key IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_before FROM public.tax_classes WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TAX_CLASS_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF c ? 'name' AND (NULLIF(btrim(c ->> 'name'), '') IS NULL OR length(btrim(c ->> 'name')) > 60) THEN
        RAISE EXCEPTION 'NAME_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    IF c ? 'name' AND EXISTS (SELECT 1 FROM public.tax_classes
                              WHERE organization_id = v_org AND name = btrim(c ->> 'name') AND id <> p_id) THEN
        RAISE EXCEPTION 'TAX_CLASS_NAME_TAKEN' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.tax_classes SET
        name         = CASE WHEN c ? 'name' THEN btrim(c ->> 'name') ELSE name END,
        kind         = CASE WHEN c ? 'kind' THEN (c ->> 'kind')::public.tax_kind ELSE kind END,
        rate         = CASE WHEN c ? 'rate' THEN (c ->> 'rate')::numeric(5,2) ELSE rate END,
        eta_tax_type = CASE WHEN c ? 'eta_tax_type' THEN btrim(c ->> 'eta_tax_type') ELSE eta_tax_type END,
        eta_subtype  = CASE WHEN c ? 'eta_subtype' THEN btrim(c ->> 'eta_subtype') ELSE eta_subtype END,
        updated_by   = v_emp
    WHERE id = p_id;
    PERFORM app.write_audit('tax_class.updated', 'tax_class', p_id, p_before => app.tax_class_json(v_before),
        p_after => (SELECT app.tax_class_json(t) FROM public.tax_classes t WHERE t.id = p_id));
EXCEPTION
    WHEN check_violation OR not_null_violation OR numeric_value_out_of_range
      OR invalid_text_representation OR invalid_parameter_value THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: tax class' USING ERRCODE = 'P0001';
END;
$$;

-- Archive or restore. The shop's default class, the delivery fee class and a class that active
-- products use can't be archived.
CREATE FUNCTION public.set_tax_class_archived(p_id uuid, p_archived boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_before public.tax_classes%ROWTYPE;
BEGIN
    v_emp := app.require_permission('catalog.manage');
    v_org := app.current_org_id();
    SELECT * INTO v_before FROM public.tax_classes WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TAX_CLASS_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF p_archived IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: archived' USING ERRCODE = 'P0001';
    END IF;
    IF (v_before.archived_at IS NOT NULL) = p_archived THEN
        RETURN;
    END IF;
    IF p_archived AND (
        EXISTS (SELECT 1 FROM public.org_settings s WHERE s.organization_id = v_org
                AND p_id IN (s.default_tax_class_id, s.delivery_fee_tax_class_id))
        OR EXISTS (SELECT 1 FROM public.products p WHERE p.organization_id = v_org
                   AND p.tax_class_id = p_id AND p.archived_at IS NULL)) THEN
        RAISE EXCEPTION 'TAX_CLASS_IN_USE' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.tax_classes SET archived_at = CASE WHEN p_archived THEN now() END, updated_by = v_emp
    WHERE id = p_id;
    PERFORM app.write_audit(CASE WHEN p_archived THEN 'tax_class.archived' ELSE 'tax_class.restored' END,
        'tax_class', p_id, p_before => jsonb_build_object('archived_at', v_before.archived_at),
        p_after => jsonb_build_object('archived', p_archived));
END;
$$;

REVOKE ALL ON FUNCTION public.list_tax_classes(), public.create_tax_class(text, public.tax_kind, numeric, text, text),
    public.update_tax_class(uuid, jsonb), public.set_tax_class_archived(uuid, boolean)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_tax_classes(), public.create_tax_class(text, public.tax_kind, numeric, text, text),
    public.update_tax_class(uuid, jsonb), public.set_tax_class_archived(uuid, boolean)
    TO authenticated;

-- 4. The engine ----------------------------------------------------------------------------------

-- Same calculation as computeDocumentTax in the contracts (golden cases: supabase/tests/fixtures).
-- Input: {prices_include_vat, document_discount, lines: [{unit_price, quantity, line_discount, tax_rate}]}.
-- Output: {lines: [{line_amount, discount_amount, tax_rate, net, tax, gross}], subtotal,
-- discount_total, net_total, tax_total, total}; money as 2-decimal strings.
CREATE FUNCTION app.compute_document_tax(p_doc jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE
    v_inc      boolean;
    v_disc     numeric;
    v_n        integer;
    v_amount   numeric[] := '{}';
    v_after    numeric[] := '{}';
    v_ldisc    numeric[] := '{}';
    v_rate     numeric[] := '{}';
    v_rate_txt text[] := '{}';
    v_share    numeric[];
    v_base     numeric := 0;
    v_line     jsonb;
    v_qty      numeric;
    v_price    numeric;
    i          integer;
    v_pias     numeric;
    v_total_w  numeric;
    v_floor    numeric[];
    v_rem      numeric[];
    v_left     integer;
    v_amt      numeric;
    v_net      numeric;
    v_tax      numeric;
    v_lines    jsonb := '[]';
    v_sub      numeric := 0;
    v_dtot     numeric := 0;
    v_ntot     numeric := 0;
    v_ttot     numeric := 0;
    v_gtot     numeric := 0;
BEGIN
    IF p_doc IS NULL OR jsonb_typeof(p_doc -> 'lines') <> 'array' OR jsonb_array_length(p_doc -> 'lines') = 0
       OR jsonb_typeof(p_doc -> 'prices_include_vat') <> 'boolean' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: tax document' USING ERRCODE = 'P0001';
    END IF;
    v_inc := (p_doc ->> 'prices_include_vat')::boolean;
    v_disc := COALESCE((p_doc ->> 'document_discount')::numeric, 0);
    v_n := jsonb_array_length(p_doc -> 'lines');
    FOR i IN 1..v_n LOOP
        v_line := p_doc -> 'lines' -> (i - 1);
        v_price := (v_line ->> 'unit_price')::numeric;
        v_qty := (v_line ->> 'quantity')::numeric;
        IF v_price IS NULL OR v_price < 0 OR v_price <> round(v_price, 2)
           OR v_qty IS NULL OR v_qty < 1 OR v_qty <> trunc(v_qty)
           OR (v_line ->> 'tax_rate')::numeric NOT BETWEEN 0 AND 100
           OR COALESCE((v_line ->> 'line_discount')::numeric, 0) < 0 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: tax line %', i USING ERRCODE = 'P0001';
        END IF;
        v_amount := v_amount || (v_price * v_qty);
        v_ldisc := v_ldisc || round(COALESCE((v_line ->> 'line_discount')::numeric, 0), 2);
        IF v_ldisc[i] > v_amount[i] THEN
            RAISE EXCEPTION 'TAX_DISCOUNT_TOO_LARGE' USING ERRCODE = 'P0001';
        END IF;
        v_after := v_after || (v_amount[i] - v_ldisc[i]);
        v_rate := v_rate || (v_line ->> 'tax_rate')::numeric;
        v_rate_txt := v_rate_txt || (v_line ->> 'tax_rate');
        v_base := v_base + v_after[i];
    END LOOP;
    v_disc := round(v_disc, 2);
    IF v_disc < 0 OR v_disc > v_base THEN
        RAISE EXCEPTION 'TAX_DISCOUNT_TOO_LARGE' USING ERRCODE = 'P0001';
    END IF;

    -- Document discount by largest remainder in piasters (exact integer arithmetic).
    v_share := array_fill(0::numeric, ARRAY[v_n]);
    IF v_disc > 0 THEN
        v_pias := v_disc * 100;
        v_total_w := v_base * 100;
        v_floor := array_fill(0::numeric, ARRAY[v_n]);
        v_rem := array_fill(0::numeric, ARRAY[v_n]);
        FOR i IN 1..v_n LOOP
            v_floor[i] := div(v_pias * (v_after[i] * 100), v_total_w);
            v_rem[i] := v_pias * (v_after[i] * 100) - v_floor[i] * v_total_w;
        END LOOP;
        v_left := (v_pias - (SELECT sum(f) FROM unnest(v_floor) f))::integer;
        FOR i IN SELECT o FROM unnest(v_rem) WITH ORDINALITY u(r, o) ORDER BY r DESC, o LIMIT v_left LOOP
            v_floor[i] := v_floor[i] + 1;
        END LOOP;
        FOR i IN 1..v_n LOOP
            v_share[i] := v_floor[i] / 100;
        END LOOP;
    END IF;

    FOR i IN 1..v_n LOOP
        v_amt := v_after[i] - v_share[i];
        IF v_inc THEN
            v_net := round(v_amt * 100 / (100 + v_rate[i]), 2);
            v_tax := v_amt - v_net;
        ELSE
            v_net := v_amt;
            v_tax := round(v_amt * v_rate[i] / 100, 2);
        END IF;
        v_lines := v_lines || jsonb_build_object(
            'line_amount', round(v_amount[i], 2)::numeric(18,2)::text,
            'discount_amount', (v_ldisc[i] + v_share[i])::numeric(18,2)::text,
            'tax_rate', v_rate_txt[i],
            'net', v_net::numeric(18,2)::text,
            'tax', v_tax::numeric(18,2)::text,
            'gross', (v_net + v_tax)::numeric(18,2)::text);
        v_sub := v_sub + v_amount[i];
        v_dtot := v_dtot + v_ldisc[i] + v_share[i];
        v_ntot := v_ntot + v_net;
        v_ttot := v_ttot + v_tax;
        v_gtot := v_gtot + v_net + v_tax;
    END LOOP;
    RETURN jsonb_build_object('lines', v_lines,
        'subtotal', v_sub::numeric(18,2)::text, 'discount_total', v_dtot::numeric(18,2)::text,
        'net_total', v_ntot::numeric(18,2)::text, 'tax_total', v_ttot::numeric(18,2)::text,
        'total', v_gtot::numeric(18,2)::text);
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: tax document' USING ERRCODE = 'P0001';
END;
$$;

-- Tax to reverse when p_return_qty units of an issued line come back (same rule as returnLineTax):
-- proportional, half-up; the return that empties the line takes what's left.
CREATE FUNCTION app.return_line_tax(p_qty integer, p_tax numeric, p_gross numeric,
                                    p_prev_qty integer, p_prev_tax numeric, p_prev_gross numeric,
                                    p_return_qty integer)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v_tax numeric; v_gross numeric;
BEGIN
    IF p_return_qty IS NULL OR p_return_qty < 1 OR p_prev_qty < 0 OR p_return_qty > p_qty - p_prev_qty THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: return quantity' USING ERRCODE = 'P0001';
    END IF;
    IF p_return_qty = p_qty - p_prev_qty THEN
        v_gross := p_gross - p_prev_gross;
        v_tax := p_tax - p_prev_tax;
    ELSE
        v_gross := round(p_gross * p_return_qty / p_qty, 2);
        v_tax := round(p_tax * p_return_qty / p_qty, 2);
    END IF;
    RETURN jsonb_build_object('net', (v_gross - v_tax)::numeric(18,2)::text,
        'tax', v_tax::numeric(18,2)::text, 'gross', v_gross::numeric(18,2)::text);
END;
$$;

REVOKE ALL ON FUNCTION app.compute_document_tax(jsonb),
    app.return_line_tax(integer, numeric, numeric, integer, numeric, numeric, integer)
    FROM PUBLIC, anon, authenticated;

-- 5. Settings: the three accountant settings in GET/PATCH /api/settings (replaces the P03 versions).

CREATE OR REPLACE FUNCTION public.get_shop_settings()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    RETURN (
        SELECT jsonb_build_object(
            'name', o.name, 'address', o.address, 'phone', o.phone,
            'timezone', o.timezone, 'default_language', o.default_language,
            'logo_file_id', o.logo_file_id, 'tax_registration_no', o.tax_registration_no,
            'receipt_header', s.receipt_header, 'receipt_footer', s.receipt_footer,
            'receipt_width_mm', s.receipt_width_mm, 'receipt_fields', s.receipt_fields,
            'prices_include_vat', s.prices_include_vat, 'default_tax_class_id', s.default_tax_class_id,
            'discount_caps', s.discount_caps,
            'return_policy_days', s.return_policy_days,
            'purchase_approval_threshold', s.purchase_approval_threshold::text,
            'credit_limit_income_multiple', s.credit_limit_income_multiple::text,
            'collector_commission_pct', s.collector_commission_pct::text,
            'allow_negative_bank', s.allow_negative_bank,
            'theme_color', s.theme_color, 'currency', s.currency,
            'credit_min_score', s.credit_min_score, 'credit_score_weights', s.credit_score_weights,
            'legal_referral_days', s.legal_referral_days,
            'customer_ban_days', s.customer_ban_days,
            'overdue_warning_interval_days', s.overdue_warning_interval_days,
            'global_min_stock', s.global_min_stock,
            'installment_markup_vat', s.installment_markup_vat,
            'delivery_fee_tax_class_id', s.delivery_fee_tax_class_id,
            'deposit_vat_timing', s.deposit_vat_timing,
            'updated_at', s.updated_at, 'updated_by', s.updated_by,
            'my_discount', jsonb_build_object(
                'cap_pct', app.discount_cap_pct(v_org, app.current_role()),
                'above_cap_allowed', app.has_permission('discount.above_cap')),
            'installment_policy', app.installment_policy_json(app.current_installment_policy(v_org)),
            'tax_class_options', COALESCE((
                SELECT jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'kind', t.kind,
                                                    'rate', t.rate::text) ORDER BY t.name, t.id)
                FROM public.tax_classes t
                WHERE t.organization_id = v_org AND t.archived_at IS NULL), '[]'::jsonb))
        FROM public.organizations o
        JOIN public.org_settings s ON s.organization_id = o.id
        WHERE o.id = v_org);
END;
$$;

CREATE OR REPLACE FUNCTION public.update_org_settings(p_changes jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    c        jsonb := p_changes;
    v_emp    uuid;
    v_org    uuid;
    v_old    jsonb;
    v_new    jsonb;
    v_before jsonb;
    v_after  jsonb;
    v_key    text;
    v_val    jsonb;
    v_keys   text[] := ARRAY['name', 'address', 'phone', 'timezone', 'default_language', 'logo_file_id',
        'tax_registration_no', 'receipt_header', 'receipt_footer', 'receipt_width_mm', 'receipt_fields',
        'prices_include_vat', 'default_tax_class_id', 'discount_caps', 'return_policy_days',
        'purchase_approval_threshold', 'credit_limit_income_multiple', 'collector_commission_pct',
        'allow_negative_bank', 'theme_color', 'credit_min_score', 'credit_score_weights',
        'legal_referral_days', 'customer_ban_days', 'overdue_warning_interval_days', 'global_min_stock',
        'installment_markup_vat', 'delivery_fee_tax_class_id', 'deposit_vat_timing'];
BEGIN
    v_emp := app.require_permission('org.settings_manage');
    v_org := app.current_org_id();
    IF c IS NULL OR jsonb_typeof(c) <> 'object' THEN
        RAISE EXCEPTION 'SETTINGS_INVALID: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT k INTO v_key FROM jsonb_object_keys(c) k WHERE k <> ALL (v_keys) LIMIT 1;
    IF v_key IS NOT NULL THEN
        RAISE EXCEPTION 'SETTINGS_INVALID: %', v_key USING ERRCODE = 'P0001';
    END IF;

    SELECT to_jsonb(o) || to_jsonb(s) INTO v_old
    FROM public.organizations o JOIN public.org_settings s ON s.organization_id = o.id
    WHERE o.id = v_org FOR UPDATE OF o, s;

    IF c ? 'name' AND (NULLIF(btrim(c ->> 'name'), '') IS NULL OR length(btrim(c ->> 'name')) > 100) THEN
        RAISE EXCEPTION 'NAME_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    IF c ? 'timezone' AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = c ->> 'timezone') THEN
        RAISE EXCEPTION 'SETTINGS_INVALID: timezone' USING ERRCODE = 'P0001';
    END IF;
    IF c ? 'logo_file_id' AND jsonb_typeof(c -> 'logo_file_id') <> 'null' AND NOT EXISTS (
        SELECT 1 FROM public.files f
        WHERE f.id = (c ->> 'logo_file_id')::uuid AND f.organization_id = v_org AND f.purpose = 'logo') THEN
        RAISE EXCEPTION 'FILE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF c ? 'default_tax_class_id' AND jsonb_typeof(c -> 'default_tax_class_id') <> 'null' AND NOT EXISTS (
        SELECT 1 FROM public.tax_classes t
        WHERE t.id = (c ->> 'default_tax_class_id')::uuid AND t.organization_id = v_org AND t.archived_at IS NULL) THEN
        RAISE EXCEPTION 'TAX_CLASS_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF c ? 'delivery_fee_tax_class_id' AND jsonb_typeof(c -> 'delivery_fee_tax_class_id') <> 'null' AND NOT EXISTS (
        SELECT 1 FROM public.tax_classes t
        WHERE t.id = (c ->> 'delivery_fee_tax_class_id')::uuid AND t.organization_id = v_org AND t.archived_at IS NULL) THEN
        RAISE EXCEPTION 'TAX_CLASS_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF c ? 'discount_caps' THEN
        IF jsonb_typeof(c -> 'discount_caps') <> 'object' THEN
            RAISE EXCEPTION 'SETTINGS_INVALID: discount_caps' USING ERRCODE = 'P0001';
        END IF;
        FOR v_key, v_val IN SELECT * FROM jsonb_each(c -> 'discount_caps') LOOP
            IF v_key = 'OWNER' OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_enum e
                    WHERE e.enumtypid = 'public.employee_role'::regtype AND e.enumlabel = v_key)
               OR jsonb_typeof(v_val) <> 'number' OR v_val::numeric < 0 OR v_val::numeric > 100 THEN
                RAISE EXCEPTION 'SETTINGS_INVALID: discount_caps.%', v_key USING ERRCODE = 'P0001';
            END IF;
        END LOOP;
    END IF;
    IF c ? 'receipt_fields' THEN
        IF jsonb_typeof(c -> 'receipt_fields') <> 'object' THEN
            RAISE EXCEPTION 'SETTINGS_INVALID: receipt_fields' USING ERRCODE = 'P0001';
        END IF;
        FOR v_key, v_val IN SELECT * FROM jsonb_each(c -> 'receipt_fields') LOOP
            IF NOT ((v_old -> 'receipt_fields') ? v_key) OR jsonb_typeof(v_val) <> 'boolean' THEN
                RAISE EXCEPTION 'SETTINGS_INVALID: receipt_fields.%', v_key USING ERRCODE = 'P0001';
            END IF;
        END LOOP;
    END IF;
    IF c ? 'credit_score_weights' THEN
        IF jsonb_typeof(c -> 'credit_score_weights') <> 'object'
           OR (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(c -> 'credit_score_weights') k)
              IS DISTINCT FROM ARRAY['guarantors', 'identity', 'income', 'residence']
           OR EXISTS (SELECT 1 FROM jsonb_each(c -> 'credit_score_weights') w
                      WHERE jsonb_typeof(w.value) <> 'number' OR w.value::numeric < 0
                         OR w.value::numeric <> trunc(w.value::numeric))
           OR (SELECT sum(w.value::numeric) FROM jsonb_each(c -> 'credit_score_weights') w) <> 100 THEN
            RAISE EXCEPTION 'SETTINGS_INVALID: credit_score_weights' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    IF c ? 'legal_referral_days' THEN
        IF jsonb_typeof(c -> 'legal_referral_days') <> 'object' OR EXISTS (
            SELECT 1 FROM jsonb_each(c -> 'legal_referral_days') d
            WHERE d.key::text NOT IN (SELECT e.enumlabel FROM pg_catalog.pg_enum e
                                      WHERE e.enumtypid = 'public.installment_frequency'::regtype)
               OR jsonb_typeof(d.value) <> 'number' OR d.value::numeric < 1
               OR d.value::numeric <> trunc(d.value::numeric)) THEN
            RAISE EXCEPTION 'SETTINGS_INVALID: legal_referral_days' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    UPDATE public.organizations SET
        name                = CASE WHEN c ? 'name' THEN btrim(c ->> 'name') ELSE name END,
        address             = CASE WHEN c ? 'address' THEN NULLIF(btrim(c ->> 'address'), '') ELSE address END,
        phone               = CASE WHEN c ? 'phone' THEN NULLIF(btrim(c ->> 'phone'), '') ELSE phone END,
        timezone            = CASE WHEN c ? 'timezone' THEN c ->> 'timezone' ELSE timezone END,
        default_language    = CASE WHEN c ? 'default_language' THEN c ->> 'default_language' ELSE default_language END,
        logo_file_id        = CASE WHEN c ? 'logo_file_id' THEN (c ->> 'logo_file_id')::uuid ELSE logo_file_id END,
        tax_registration_no = CASE WHEN c ? 'tax_registration_no'
                                   THEN NULLIF(btrim(c ->> 'tax_registration_no'), '') ELSE tax_registration_no END
    WHERE id = v_org;

    UPDATE public.org_settings SET
        receipt_header      = CASE WHEN c ? 'receipt_header' THEN NULLIF(c ->> 'receipt_header', '') ELSE receipt_header END,
        receipt_footer      = CASE WHEN c ? 'receipt_footer' THEN NULLIF(c ->> 'receipt_footer', '') ELSE receipt_footer END,
        receipt_width_mm    = CASE WHEN c ? 'receipt_width_mm' THEN (c ->> 'receipt_width_mm')::integer ELSE receipt_width_mm END,
        receipt_fields      = CASE WHEN c ? 'receipt_fields' THEN receipt_fields || (c -> 'receipt_fields') ELSE receipt_fields END,
        prices_include_vat  = CASE WHEN c ? 'prices_include_vat' THEN (c ->> 'prices_include_vat')::boolean ELSE prices_include_vat END,
        default_tax_class_id = CASE WHEN c ? 'default_tax_class_id' THEN (c ->> 'default_tax_class_id')::uuid ELSE default_tax_class_id END,
        discount_caps       = CASE WHEN c ? 'discount_caps' THEN c -> 'discount_caps' ELSE discount_caps END,
        return_policy_days  = CASE WHEN c ? 'return_policy_days' THEN (c ->> 'return_policy_days')::integer ELSE return_policy_days END,
        purchase_approval_threshold = CASE WHEN c ? 'purchase_approval_threshold'
                                      THEN (c ->> 'purchase_approval_threshold')::numeric(18,2) ELSE purchase_approval_threshold END,
        credit_limit_income_multiple = CASE WHEN c ? 'credit_limit_income_multiple'
                                       THEN (c ->> 'credit_limit_income_multiple')::numeric(6,2) ELSE credit_limit_income_multiple END,
        collector_commission_pct = CASE WHEN c ? 'collector_commission_pct'
                                   THEN (c ->> 'collector_commission_pct')::numeric(5,2) ELSE collector_commission_pct END,
        allow_negative_bank = CASE WHEN c ? 'allow_negative_bank' THEN (c ->> 'allow_negative_bank')::boolean ELSE allow_negative_bank END,
        theme_color         = CASE WHEN c ? 'theme_color' THEN c ->> 'theme_color' ELSE theme_color END,
        credit_min_score    = CASE WHEN c ? 'credit_min_score' THEN (c ->> 'credit_min_score')::integer ELSE credit_min_score END,
        credit_score_weights = CASE WHEN c ? 'credit_score_weights' THEN c -> 'credit_score_weights' ELSE credit_score_weights END,
        legal_referral_days = CASE WHEN c ? 'legal_referral_days' THEN legal_referral_days || (c -> 'legal_referral_days') ELSE legal_referral_days END,
        customer_ban_days   = CASE WHEN c ? 'customer_ban_days' THEN (c ->> 'customer_ban_days')::integer ELSE customer_ban_days END,
        overdue_warning_interval_days = CASE WHEN c ? 'overdue_warning_interval_days'
                                        THEN (c ->> 'overdue_warning_interval_days')::integer ELSE overdue_warning_interval_days END,
        global_min_stock    = CASE WHEN c ? 'global_min_stock' THEN (c ->> 'global_min_stock')::integer ELSE global_min_stock END,
        installment_markup_vat = CASE WHEN c ? 'installment_markup_vat' THEN c ->> 'installment_markup_vat' ELSE installment_markup_vat END,
        delivery_fee_tax_class_id = CASE WHEN c ? 'delivery_fee_tax_class_id'
                                    THEN (c ->> 'delivery_fee_tax_class_id')::uuid ELSE delivery_fee_tax_class_id END,
        deposit_vat_timing  = CASE WHEN c ? 'deposit_vat_timing' THEN c ->> 'deposit_vat_timing' ELSE deposit_vat_timing END,
        updated_by          = v_emp
    WHERE organization_id = v_org;

    SELECT to_jsonb(o) || to_jsonb(s) INTO v_new
    FROM public.organizations o JOIN public.org_settings s ON s.organization_id = o.id
    WHERE o.id = v_org;
    SELECT jsonb_object_agg(k, v_old -> k), jsonb_object_agg(k, v_new -> k) INTO v_before, v_after
    FROM jsonb_object_keys(c) k
    WHERE (v_old -> k) IS DISTINCT FROM (v_new -> k);
    IF v_after IS NULL THEN
        RETURN;
    END IF;
    PERFORM app.write_audit('org.settings_updated', 'organization', v_org, p_before => v_before, p_after => v_after);
EXCEPTION
    -- Bad values the checks above don't name (casts, CHECK constraints): never a raw DB message.
    WHEN invalid_text_representation OR check_violation OR numeric_value_out_of_range
      OR invalid_parameter_value OR datetime_field_overflow OR not_null_violation THEN
        RAISE EXCEPTION 'SETTINGS_INVALID' USING ERRCODE = 'P0001';
END;
$$;
