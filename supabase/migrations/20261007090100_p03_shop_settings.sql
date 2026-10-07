-- P03 shop settings (EC-36, D40). Refactors FinTech-Pro's settings screen (one untyped
-- config_data blob, written with the service role) onto typed columns written only through
-- permission-checked functions, and adds the FinTech-Pro rules the user kept.

-- 1. New columns -------------------------------------------------------------------------------

-- General tab: the shop's own address and phone (branches keep theirs).
ALTER TABLE public.organizations
    ADD COLUMN address text CHECK (address IS NULL OR length(address) <= 300),
    ADD COLUMN phone   text CHECK (phone IS NULL OR length(phone) <= 30);

ALTER TABLE public.org_settings
    -- Receipts: which fields the printed receipt shows.
    ADD COLUMN receipt_fields jsonb NOT NULL DEFAULT
        '{"logo":true,"address":true,"phone":true,"tax_registration_no":true,"branch":true,"cashier":true,"customer":true}'::jsonb,
    -- Appearance (FinTech-Pro identity tab). V1 sells in EGP only.
    ADD COLUMN theme_color text NOT NULL DEFAULT '#2563EB' CHECK (theme_color ~ '^#[0-9A-Fa-f]{6}$'),
    ADD COLUMN currency    text NOT NULL DEFAULT 'EGP' CHECK (currency = 'EGP'),
    -- Credit (FinTech-Pro creditPolicy, read by R03): minimum score and score weights (sum 100).
    ADD COLUMN credit_min_score     integer NOT NULL DEFAULT 50 CHECK (credit_min_score BETWEEN 0 AND 100),
    ADD COLUMN credit_score_weights jsonb NOT NULL DEFAULT
        '{"guarantors":40,"income":30,"residence":20,"identity":10}'::jsonb,
    -- Legal (FinTech-Pro legalPolicy, read by N04/L01): days overdue before a contract goes to
    -- legal, per installment frequency; ban period for a defaulted customer; warning interval.
    ADD COLUMN legal_referral_days jsonb NOT NULL DEFAULT '{"daily":35,"weekly":63,"monthly":63}'::jsonb,
    ADD COLUMN customer_ban_days             integer NOT NULL DEFAULT 180 CHECK (customer_ban_days >= 0),
    ADD COLUMN overdue_warning_interval_days integer NOT NULL DEFAULT 10 CHECK (overdue_warning_interval_days > 0),
    -- Inventory (FinTech-Pro): low-stock alert for products without their own minimum (C02).
    ADD COLUMN global_min_stock integer NOT NULL DEFAULT 3 CHECK (global_min_stock >= 0),
    ADD CONSTRAINT org_settings_json_shapes CHECK (
        jsonb_typeof(receipt_fields) = 'object' AND jsonb_typeof(credit_score_weights) = 'object'
        AND jsonb_typeof(legal_referral_days) = 'object' AND jsonb_typeof(discount_caps) = 'object');

-- Installment policy (FinTech-Pro salesTerms, read by N01). Versions stay immutable.
ALTER TABLE public.installment_policies
    -- Smallest sale that may be sold on installments.
    ADD COLUMN min_sale_amount numeric(18,2) NOT NULL DEFAULT 0 CHECK (min_sale_amount >= 0),
    -- Down payment cap (FinTech-Pro: 50%); NULL = no cap.
    ADD COLUMN max_down_payment_pct numeric(5,2) CHECK (max_down_payment_pct BETWEEN 0 AND 100),
    -- Per frequency: "percent" (min_down_payment_pct only), "one_installment" (one installment
    -- up front) or "installment_per_day_of_month" (daily only: one installment per day of the
    -- month so far). Missing frequency = "percent".
    ADD COLUMN down_payment_rules jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- Per frequency minimum installment, e.g. {"daily":"50.00","monthly":"500.00"}; a missing
    -- frequency falls back to min_installment.
    ADD COLUMN min_installment_by_frequency jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- Max months by sale amount, e.g. [{"up_to_amount":"100000.00","max_months":10}]; a sale
    -- above the last tier, or no tiers, uses max_months.
    ADD COLUMN amount_tiers jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD CONSTRAINT installment_policies_down_payment_range
        CHECK (max_down_payment_pct IS NULL OR max_down_payment_pct >= min_down_payment_pct),
    ADD CONSTRAINT installment_policies_json_shapes CHECK (
        jsonb_typeof(down_payment_rules) = 'object' AND jsonb_typeof(min_installment_by_frequency) = 'object'
        AND jsonb_typeof(amount_tiers) = 'array');

-- 2. Read helpers (used by the API now and by S/N/R/L slices later) -----------------------------

-- The policy new contracts use: the newest version already in effect.
CREATE FUNCTION app.current_installment_policy(p_org uuid)
RETURNS public.installment_policies LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT * FROM public.installment_policies
    WHERE organization_id = p_org AND effective_from <= now()
    ORDER BY version DESC LIMIT 1
$$;

-- Discount cap % for a role. OWNER has no cap; a role missing from discount_caps gets 0.
CREATE FUNCTION app.discount_cap_pct(p_org uuid, p_role public.employee_role)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT CASE WHEN p_role = 'OWNER' THEN 100::numeric
                ELSE COALESCE((SELECT (s.discount_caps ->> p_role::text)::numeric
                               FROM public.org_settings s WHERE s.organization_id = p_org), 0) END
$$;

-- Sales functions call this before posting a discount. Above the caller's role cap needs
-- discount.above_cap (the approval flow for everyone else comes with the sales slices).
CREATE FUNCTION app.check_discount(p_pct numeric)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_cap numeric;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF p_pct IS NULL OR p_pct < 0 OR p_pct > 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: discount' USING ERRCODE = 'P0001';
    END IF;
    v_cap := app.discount_cap_pct(app.current_org_id(), app.current_role());
    IF p_pct > v_cap AND NOT app.has_permission('discount.above_cap') THEN
        RAISE EXCEPTION 'DISCOUNT_ABOVE_CAP: %', v_cap USING ERRCODE = 'P0001';
    END IF;
END;
$$;

-- API shape of a policy: numeric columns as decimal strings.
CREATE FUNCTION app.installment_policy_json(p public.installment_policies)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT CASE WHEN p.id IS NULL THEN NULL ELSE jsonb_build_object(
        'id', p.id, 'version', p.version,
        'min_down_payment_pct', p.min_down_payment_pct::text,
        'max_down_payment_pct', p.max_down_payment_pct::text,
        'down_payment_rules', p.down_payment_rules,
        'max_months', p.max_months,
        'amount_tiers', p.amount_tiers,
        'markup_tiers', p.markup_tiers,
        'allowed_frequencies', to_jsonb(p.allowed_frequencies),
        'min_sale_amount', p.min_sale_amount::text,
        'min_installment', p.min_installment::text,
        'min_installment_by_frequency', p.min_installment_by_frequency,
        'rounding_step', p.rounding_step::text,
        'late_fee_type', p.late_fee_type,
        'late_fee_value', p.late_fee_value::text,
        'late_fee_recurring', p.late_fee_recurring,
        'late_fee_cap', p.late_fee_cap::text,
        'grace_days', p.grace_days,
        'early_settlement_rule', p.early_settlement_rule,
        'early_settlement_pct', p.early_settlement_pct::text,
        'guarantor_required_above', p.guarantor_required_above::text,
        'survey_required_above', p.survey_required_above::text,
        'effective_from', p.effective_from,
        'created_at', p.created_at,
        'created_by', p.created_by) END
$$;

REVOKE ALL ON FUNCTION app.current_installment_policy(uuid), app.discount_cap_pct(uuid, public.employee_role),
    app.check_discount(numeric), app.installment_policy_json(public.installment_policies)
    FROM PUBLIC, anon, authenticated;

-- 3. GET /api/settings ------------------------------------------------------------------------

-- Any employee of the shop may read its settings (the POS needs receipt, VAT and discount rules).
CREATE FUNCTION public.get_shop_settings()
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

-- 4. PATCH /api/settings ----------------------------------------------------------------------

-- Partial update: only the keys present in p_changes change. One audit row with the changed
-- keys only; no change, no audit row.
CREATE FUNCTION public.update_org_settings(p_changes jsonb)
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
        'legal_referral_days', 'customer_ban_days', 'overdue_warning_interval_days', 'global_min_stock'];
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

-- 5. POST /api/settings/installment-policies --------------------------------------------------

-- Publishes a new immutable version: the previous version plus the keys in p_policy. Contracts
-- keep the policy_id they used, so a new version only affects new contracts. Publishing the
-- same terms again returns the current version without a new one.
CREATE FUNCTION public.publish_installment_policy(p_policy jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp   uuid;
    v_org   uuid;
    v_prev  public.installment_policies%ROWTYPE;
    v_row   public.installment_policies%ROWTYPE;
    v_freqs text[];
    v_key   text;
    v_val   jsonb;
    v_meta  text[] := ARRAY['id', 'organization_id', 'version', 'effective_from', 'created_at', 'created_by'];
    v_keys  text[] := ARRAY['min_down_payment_pct', 'max_down_payment_pct', 'down_payment_rules', 'max_months',
        'amount_tiers', 'markup_tiers', 'allowed_frequencies', 'min_sale_amount', 'min_installment',
        'min_installment_by_frequency', 'rounding_step', 'late_fee_type', 'late_fee_value',
        'late_fee_recurring', 'late_fee_cap', 'grace_days', 'early_settlement_rule', 'early_settlement_pct',
        'guarantor_required_above', 'survey_required_above'];
BEGIN
    v_emp := app.require_permission('org.settings_manage');
    PERFORM app.require_module('installments');
    v_org := app.current_org_id();
    IF p_policy IS NULL OR jsonb_typeof(p_policy) <> 'object' THEN
        RAISE EXCEPTION 'POLICY_INVALID: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT k INTO v_key FROM jsonb_object_keys(p_policy) k WHERE k <> ALL (v_keys) LIMIT 1;
    IF v_key IS NOT NULL THEN
        RAISE EXCEPTION 'POLICY_INVALID: %', v_key USING ERRCODE = 'P0001';
    END IF;

    PERFORM 1 FROM public.organizations WHERE id = v_org FOR UPDATE;   -- one publisher at a time
    SELECT * INTO v_prev FROM public.installment_policies
    WHERE organization_id = v_org ORDER BY version DESC LIMIT 1;
    IF v_prev.id IS NULL THEN
        -- No version yet (shops made before P01): start from P01's version 1 terms.
        v_row := jsonb_populate_record(NULL::public.installment_policies, jsonb_build_object(
            'min_down_payment_pct', 0, 'max_months', 12, 'markup_tiers', '[{"up_to_months":12,"pct":0}]'::jsonb,
            'allowed_frequencies', '["monthly"]'::jsonb, 'min_installment', 0, 'rounding_step', 1,
            'late_fee_type', 'none', 'late_fee_value', 0, 'late_fee_recurring', false, 'grace_days', 0,
            'early_settlement_rule', 'no_discount', 'min_sale_amount', 0, 'down_payment_rules', '{}'::jsonb,
            'min_installment_by_frequency', '{}'::jsonb, 'amount_tiers', '[]'::jsonb) || p_policy);
    ELSE
        v_row := jsonb_populate_record(v_prev, p_policy);
    END IF;

    -- Frequencies first: the per-frequency rules below are checked against them.
    v_freqs := v_row.allowed_frequencies::text[];
    IF cardinality(v_freqs) = 0 OR cardinality(v_freqs) <> (SELECT count(DISTINCT f) FROM unnest(v_freqs) f) THEN
        RAISE EXCEPTION 'POLICY_INVALID: allowed_frequencies' USING ERRCODE = 'P0001';
    END IF;
    -- Markup tiers: [{up_to_months, pct}], months strictly rising, the last one covers max_months.
    IF jsonb_typeof(v_row.markup_tiers) <> 'array' OR jsonb_array_length(v_row.markup_tiers) = 0
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_row.markup_tiers) AS e(t)
                  WHERE jsonb_typeof(t) <> 'object'
                     OR (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(t) k) IS DISTINCT FROM ARRAY['pct', 'up_to_months']
                     OR jsonb_typeof(t -> 'up_to_months') <> 'number' OR jsonb_typeof(t -> 'pct') <> 'number'
                     OR (t ->> 'up_to_months')::numeric <> trunc((t ->> 'up_to_months')::numeric)
                     OR (t ->> 'up_to_months')::numeric NOT BETWEEN 1 AND 120
                     OR (t ->> 'pct')::numeric NOT BETWEEN 0 AND 500)
       OR EXISTS (SELECT 1 FROM (SELECT (t ->> 'up_to_months')::numeric m,
                                        lag((t ->> 'up_to_months')::numeric) OVER (ORDER BY o) prev
                                 FROM jsonb_array_elements(v_row.markup_tiers) WITH ORDINALITY x(t, o)) s
                  WHERE s.m <= s.prev)
       OR (v_row.markup_tiers -> -1 ->> 'up_to_months')::numeric < v_row.max_months THEN
        RAISE EXCEPTION 'POLICY_INVALID: markup_tiers' USING ERRCODE = 'P0001';
    END IF;
    -- Amount tiers: [{up_to_amount, max_months}], amounts strictly rising, months within max_months.
    IF jsonb_typeof(v_row.amount_tiers) <> 'array'
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_row.amount_tiers) AS e(t)
                  WHERE jsonb_typeof(t) <> 'object'
                     OR (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(t) k) IS DISTINCT FROM ARRAY['max_months', 'up_to_amount']
                     OR jsonb_typeof(t -> 'up_to_amount') <> 'string' OR jsonb_typeof(t -> 'max_months') <> 'number'
                     OR (t ->> 'up_to_amount') !~ '^\d{1,16}(\.\d{1,2})?$' OR (t ->> 'up_to_amount')::numeric <= 0
                     OR (t ->> 'max_months')::numeric <> trunc((t ->> 'max_months')::numeric)
                     OR (t ->> 'max_months')::numeric NOT BETWEEN 1 AND v_row.max_months)
       OR EXISTS (SELECT 1 FROM (SELECT (t ->> 'up_to_amount')::numeric a,
                                        lag((t ->> 'up_to_amount')::numeric) OVER (ORDER BY o) prev
                                 FROM jsonb_array_elements(v_row.amount_tiers) WITH ORDINALITY x(t, o)) s
                  WHERE s.a <= s.prev) THEN
        RAISE EXCEPTION 'POLICY_INVALID: amount_tiers' USING ERRCODE = 'P0001';
    END IF;
    -- Per-frequency minimum installment: only allowed frequencies, money strings.
    FOR v_key, v_val IN SELECT * FROM jsonb_each(v_row.min_installment_by_frequency) LOOP
        IF v_key <> ALL (v_freqs) OR jsonb_typeof(v_val) <> 'string' OR (v_val #>> '{}') !~ '^\d{1,16}(\.\d{1,2})?$' THEN
            RAISE EXCEPTION 'POLICY_INVALID: min_installment_by_frequency.%', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    -- Per-frequency down payment rule; "installment_per_day_of_month" only makes sense for daily.
    FOR v_key, v_val IN SELECT * FROM jsonb_each(v_row.down_payment_rules) LOOP
        IF v_key <> ALL (v_freqs) OR jsonb_typeof(v_val) <> 'string'
           OR (v_val #>> '{}') NOT IN ('percent', 'one_installment', 'installment_per_day_of_month')
           OR ((v_val #>> '{}') = 'installment_per_day_of_month' AND v_key <> 'daily') THEN
            RAISE EXCEPTION 'POLICY_INVALID: down_payment_rules.%', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    IF v_row.late_fee_type = 'percent' AND v_row.late_fee_value > 100 THEN
        RAISE EXCEPTION 'POLICY_INVALID: late_fee_value' USING ERRCODE = 'P0001';
    END IF;

    IF v_prev.id IS NOT NULL AND (to_jsonb(v_row) - v_meta) = (to_jsonb(v_prev) - v_meta) THEN
        RETURN v_prev.id;
    END IF;
    v_row.id := gen_random_uuid();
    v_row.organization_id := v_org;
    v_row.version := COALESCE(v_prev.version, 0) + 1;
    v_row.effective_from := now();
    v_row.created_at := now();
    v_row.created_by := v_emp;
    INSERT INTO public.installment_policies SELECT (v_row).*;
    PERFORM app.write_audit('installment_policy.published', 'installment_policy', v_row.id,
        p_before => CASE WHEN v_prev.id IS NULL THEN NULL ELSE to_jsonb(v_prev) END,
        p_after => to_jsonb(v_row));
    RETURN v_row.id;
EXCEPTION
    WHEN invalid_text_representation OR check_violation OR numeric_value_out_of_range
      OR invalid_parameter_value OR datatype_mismatch OR not_null_violation THEN
        RAISE EXCEPTION 'POLICY_INVALID' USING ERRCODE = 'P0001';
END;
$$;

-- Version history for the settings screen (newest first).
CREATE FUNCTION public.list_installment_policies()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    -- A read: works in a read-only (expired) shop too, so not require_permission.
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('org.settings_manage') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: org.settings_manage' USING ERRCODE = '42501';
    END IF;
    RETURN COALESCE((SELECT jsonb_agg(app.installment_policy_json(p) ORDER BY p.version DESC)
                     FROM public.installment_policies p
                     WHERE p.organization_id = app.current_org_id()), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.get_shop_settings(), public.update_org_settings(jsonb),
    public.publish_installment_policy(jsonb), public.list_installment_policies()
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_shop_settings(), public.update_org_settings(jsonb),
    public.publish_installment_policy(jsonb), public.list_installment_policies()
    TO authenticated;
