-- =============================================================================
-- R01 · Customers (EC-63, D63)
--
-- The shop's customer records: create, edit, block / unblock, list with search, read one.
-- National IDs are PII: the full number is returned only to a caller with customer.view_pii;
-- everyone else gets ten stars and the last four digits. ID photos are files rows (F14, purpose
-- customer_id, entity customer), read with customer.view_pii through the files API.
--
-- Numbered after the newest migration on main (D39). Everything below is NEW: the baseline's
-- customers table, its indexes (the unique national ID per shop included), the RLS tenant policy,
-- the column grants (national_id is not granted) and the updated_at trigger stay as they are.
-- No new tables, columns, enums or permission keys.
--
-- Rules (D62):
--   1. A national ID is optional, 14 digits, and must parse (app.parse_national_id): century digit
--      2 or 3, a real birth date that is not in the future, a known governorate code. The check
--      digit is not verified. With an ID, birth_date and gender always come from it; without one
--      they may be typed.
--   2. A national ID is unique per shop (the baseline index): CUSTOMER_NATIONAL_ID_TAKEN, with the
--      existing customer in the error detail.
--   3. customer.create may set the ID of a new customer and customer.edit may fill an empty one.
--      Sending national_id for a customer who already has one needs customer.view_pii as well,
--      whatever the value (so the answer never confirms a guess).
--   4. Phones: 1 to 5, stored normalised (ASCII digits; an Egyptian mobile as 01XXXXXXXXX), no
--      repeats inside one customer. The same phone may belong to several customers.
--   5. Status: active / blocked by hand with customer.edit (blocking needs a reason); watch is
--      left to the system. A blocked customer can't buy on installments (N02 enforces it).
--   6. Reads: any of the customer, sales, installment, collection, survey, legal or financial
--      report keys (app.can_read_customers). They check app.has_permission, so an expired
--      (read-only) shop can still read. Reads and writes need the plan module 'customers'.
--   7. Search: the name (contains; letter case and Arabic letter forms ignored), a phone
--      (contains, 3+ digits), or the national ID: all 14 digits for everyone, a prefix of 4+
--      digits only with customer.view_pii.
-- =============================================================================

-- 1. Pure helpers (no grants) -----------------------------------------------------------------

-- Arabic-Indic (U+0660..0669) and Persian (U+06F0..06F9) digits as 0-9.
CREATE FUNCTION app.ascii_digits(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT translate(p, U&'\0660\0661\0662\0663\0664\0665\0666\0667\0668\0669\06F0\06F1\06F2\06F3\06F4\06F5\06F6\06F7\06F8\06F9',
                     '01234567890123456789')
$$;

-- Name search key: lower case, alef forms as alef, taa marbuta as haa, alef maqsura as yaa,
-- tatweel and harakat removed. Used on both sides of the comparison only; nothing is stored.
CREATE FUNCTION app.search_text(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT regexp_replace(
        translate(lower(p), U&'\0623\0625\0622\0671\0629\0649', U&'\0627\0627\0627\0627\0647\064A'),
        U&'[\0640\064B-\0652]', '', 'g')
$$;

-- The birth date, gender and governorate code of a 14-digit national ID; all NULL when it is not
-- a valid one. The same rules as the contracts package (nationalId.ts); "not in the future" is
-- checked by the caller. The check digit (digit 14) is not verified.
CREATE FUNCTION app.parse_national_id(p_id text, OUT birth_date date, OUT gender text, OUT governorate_code text)
RETURNS record LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v_year integer; v_month integer; v_day integer; v_gov text;
BEGIN
    IF p_id IS NULL OR p_id !~ '^[0-9]{14}$' OR left(p_id, 1) NOT IN ('2', '3') THEN
        RETURN;
    END IF;
    v_year := CASE left(p_id, 1) WHEN '2' THEN 1900 ELSE 2000 END + substr(p_id, 2, 2)::integer;
    v_month := substr(p_id, 4, 2)::integer;
    v_day := substr(p_id, 6, 2)::integer;
    IF v_month NOT BETWEEN 1 AND 12 OR v_day < 1
       OR v_day > extract(day FROM make_date(v_year, v_month, 1) + interval '1 month' - interval '1 day') THEN
        RETURN;
    END IF;
    v_gov := substr(p_id, 8, 2);
    IF v_gov <> ALL (ARRAY['01', '02', '03', '04', '11', '12', '13', '14', '15', '16', '17', '18', '19',
                           '21', '22', '23', '24', '25', '26', '27', '28', '29',
                           '31', '32', '33', '34', '35', '88']) THEN
        RETURN;
    END IF;
    birth_date := make_date(v_year, v_month, v_day);
    gender := CASE WHEN substr(p_id, 13, 1)::integer % 2 = 1 THEN 'male' ELSE 'female' END;
    governorate_code := v_gov;
END;
$$;

-- What a caller without customer.view_pii sees: ten stars and the last four digits.
CREATE FUNCTION app.mask_national_id(p_id text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT CASE WHEN p_id IS NOT NULL THEN repeat('*', 10) || right(p_id, 4) END
$$;

-- A phone as it is stored: ASCII digits, no spaces, dashes, dots or brackets; an Egyptian mobile
-- (+20 / 0020 / 20 / 0 / nothing, then 1[0125] and 8 digits) always as 01XXXXXXXXX.
CREATE FUNCTION app.normalize_customer_phone(p text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v text := regexp_replace(app.ascii_digits(p), '[[:space:]().-]', '', 'g'); v_mobile text;
BEGIN
    v_mobile := substring(v FROM '^(?:\+20|0020|20|0)?(1[0125][0-9]{8})$');
    RETURN CASE WHEN v_mobile IS NOT NULL THEN '0' || v_mobile ELSE v END;
END;
$$;

-- 2. Access and row helpers (no grants) ---------------------------------------------------------

-- Rule 6: who may read customers.
CREATE FUNCTION app.can_read_customers()
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT app.has_permission('customer.create') OR app.has_permission('customer.edit')
        OR app.has_permission('customer.view_pii') OR app.has_permission('credit.approve')
        OR app.has_permission('guarantor.manage') OR app.has_permission('sale.create')
        OR app.has_permission('quotation.manage') OR app.has_permission('order.manage')
        OR app.has_permission('installment.create') OR app.has_permission('collection.create')
        OR app.has_permission('survey.assign') OR app.has_permission('survey.submit')
        OR app.has_permission('survey.decide') OR app.has_permission('legal.view')
        OR app.has_permission('report.financial')
$$;

-- The start of every read: an employee with one of the rule-6 keys, in a plan with customers.
CREATE FUNCTION app.customer_read_guard()
RETURNS void LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.can_read_customers() THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: customer.create' USING ERRCODE = '42501';
    END IF;
    PERFORM app.require_module('customers');
END;
$$;

-- Row shape of the contract's Customer. p_pii = the caller holds customer.view_pii: only then is
-- the full national ID returned. The mask and the photo count are for everyone.
CREATE FUNCTION app.customer_json(p_org uuid, p_id uuid, p_pii boolean)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', c.id, 'full_name', c.full_name, 'phones', to_jsonb(c.phones),
        'national_id', CASE WHEN p_pii THEN c.national_id END,
        'national_id_masked', app.mask_national_id(c.national_id),
        'birth_date', c.birth_date, 'gender', c.gender,
        'address', c.address, 'city', c.city, 'job', c.job, 'employer', c.employer,
        'monthly_income', c.monthly_income::numeric(18,2)::text,
        'is_business', c.is_business, 'tax_registration_no', c.tax_registration_no,
        'status', c.status, 'notes', c.notes,
        'id_photos_count', (SELECT count(*) FROM public.files f
                            WHERE f.organization_id = p_org AND f.entity_type = 'customer'
                              AND f.entity_id = c.id AND f.purpose = 'customer_id'),
        'created_at', c.created_at, 'updated_at', c.updated_at)
    FROM public.customers c
    WHERE c.id = p_id AND c.organization_id = p_org
$$;

-- The editable fields (the audit before/after). Never the national ID itself: its mask only.
CREATE FUNCTION app.customer_fields_json(c public.customers)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'full_name', c.full_name, 'phones', to_jsonb(c.phones),
        'national_id_masked', app.mask_national_id(c.national_id),
        'birth_date', c.birth_date, 'gender', c.gender,
        'address', c.address, 'city', c.city, 'job', c.job, 'employer', c.employer,
        'monthly_income', c.monthly_income::numeric(18,2)::text,
        'is_business', c.is_business, 'tax_registration_no', c.tax_registration_no, 'notes', c.notes)
$$;

-- Applies the keys of c to the row r and validates them (the contract's rules, repeated here).
CREATE FUNCTION app.customer_apply(r public.customers, c jsonb)
RETURNS public.customers LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE
    v_key text; v_txt text; v_phones text[];
    v_birth date; v_gender text; v_gov text;
    v_texts constant text[] := ARRAY['national_id', 'birth_date', 'gender', 'address', 'city', 'job',
                                     'employer', 'monthly_income', 'tax_registration_no', 'notes'];
BEGIN
    IF c IS NULL OR jsonb_typeof(c) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    -- organization_id, status, credit_limit and anything unknown are refused.
    SELECT k INTO v_key FROM jsonb_object_keys(c) k
    WHERE k <> ALL (v_texts || ARRAY['full_name', 'phones', 'is_business'])
    LIMIT 1;
    IF v_key IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
    END IF;
    SELECT k INTO v_key FROM jsonb_object_keys(c) k
    WHERE (k = 'full_name' AND jsonb_typeof(c -> k) <> 'string')
       OR (k = 'phones' AND jsonb_typeof(c -> k) <> 'array')
       OR (k = 'is_business' AND jsonb_typeof(c -> k) <> 'boolean')
       OR (k = ANY (v_texts) AND jsonb_typeof(c -> k) NOT IN ('string', 'null'))
    LIMIT 1;
    IF v_key IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
    END IF;

    IF c ? 'full_name' THEN
        v_txt := regexp_replace(btrim(c ->> 'full_name'), '[[:space:]]+', ' ', 'g');
        IF length(v_txt) < 2 OR length(v_txt) > 150 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: full_name' USING ERRCODE = 'P0001';
        END IF;
        r.full_name := v_txt;
    END IF;
    IF c ? 'phones' THEN
        IF jsonb_array_length(c -> 'phones') NOT BETWEEN 1 AND 5
           OR EXISTS (SELECT 1 FROM jsonb_array_elements(c -> 'phones') e WHERE jsonb_typeof(e) <> 'string') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: phones' USING ERRCODE = 'P0001';
        END IF;
        SELECT array_agg(app.normalize_customer_phone(e #>> '{}') ORDER BY o) INTO v_phones
        FROM jsonb_array_elements(c -> 'phones') WITH ORDINALITY x(e, o);
        IF EXISTS (SELECT 1 FROM unnest(v_phones) ph WHERE ph !~ '^\+?[0-9]{7,15}$')
           OR (SELECT count(DISTINCT ph) FROM unnest(v_phones) ph) <> cardinality(v_phones) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: phones' USING ERRCODE = 'P0001';
        END IF;
        r.phones := v_phones;
    END IF;
    IF c ? 'national_id' THEN
        r.national_id := NULLIF(regexp_replace(app.ascii_digits(btrim(c ->> 'national_id')), '[[:space:]-]', '', 'g'), '');
    END IF;
    IF c ? 'birth_date' THEN
        v_txt := c ->> 'birth_date';
        IF v_txt IS NOT NULL AND v_txt !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: birth_date' USING ERRCODE = 'P0001';
        END IF;
        r.birth_date := v_txt::date;
    END IF;
    IF c ? 'gender' THEN
        v_txt := c ->> 'gender';
        IF v_txt IS NOT NULL AND v_txt NOT IN ('male', 'female') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: gender' USING ERRCODE = 'P0001';
        END IF;
        r.gender := v_txt;
    END IF;
    IF c ? 'address' THEN
        v_txt := NULLIF(btrim(c ->> 'address'), '');
        IF length(v_txt) > 300 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: address' USING ERRCODE = 'P0001';
        END IF;
        r.address := v_txt;
    END IF;
    IF c ? 'city' THEN
        v_txt := NULLIF(btrim(c ->> 'city'), '');
        IF length(v_txt) > 100 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: city' USING ERRCODE = 'P0001';
        END IF;
        r.city := v_txt;
    END IF;
    IF c ? 'job' THEN
        v_txt := NULLIF(btrim(c ->> 'job'), '');
        IF length(v_txt) > 100 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: job' USING ERRCODE = 'P0001';
        END IF;
        r.job := v_txt;
    END IF;
    IF c ? 'employer' THEN
        v_txt := NULLIF(btrim(c ->> 'employer'), '');
        IF length(v_txt) > 150 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: employer' USING ERRCODE = 'P0001';
        END IF;
        r.employer := v_txt;
    END IF;
    IF c ? 'monthly_income' THEN
        v_txt := c ->> 'monthly_income';
        IF v_txt IS NOT NULL AND v_txt !~ '^[0-9]{1,16}(\.[0-9]{1,2})?$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: monthly_income' USING ERRCODE = 'P0001';
        END IF;
        r.monthly_income := v_txt::numeric(18,2);
    END IF;
    IF c ? 'is_business' THEN
        r.is_business := (c ->> 'is_business')::boolean;
    END IF;
    IF c ? 'tax_registration_no' THEN
        v_txt := NULLIF(btrim(c ->> 'tax_registration_no'), '');
        IF v_txt IS NOT NULL AND v_txt !~ '^[0-9-]{9,20}$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: tax_registration_no' USING ERRCODE = 'P0001';
        END IF;
        r.tax_registration_no := v_txt;
    END IF;
    IF c ? 'notes' THEN
        v_txt := NULLIF(btrim(c ->> 'notes'), '');
        IF length(v_txt) > 1000 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: notes' USING ERRCODE = 'P0001';
        END IF;
        r.notes := v_txt;
    END IF;

    -- Rule 1: with a national ID the birth date and gender are its own; a body that says
    -- otherwise is refused, not silently overwritten.
    IF r.national_id IS NOT NULL THEN
        SELECT p.birth_date, p.gender, p.governorate_code INTO v_birth, v_gender, v_gov
        FROM app.parse_national_id(r.national_id) p;
        IF v_birth IS NULL OR v_birth > current_date + 1 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: national_id' USING ERRCODE = 'P0001';
        END IF;
        IF c ? 'birth_date' AND r.birth_date IS DISTINCT FROM v_birth THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: birth_date' USING ERRCODE = 'P0001';
        END IF;
        IF c ? 'gender' AND r.gender IS DISTINCT FROM v_gender THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: gender' USING ERRCODE = 'P0001';
        END IF;
        r.birth_date := v_birth;
        r.gender := v_gender;
    ELSIF r.birth_date < DATE '1900-01-01' OR r.birth_date > current_date + 1 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: birth_date' USING ERRCODE = 'P0001';
    END IF;
    IF r.is_business AND r.tax_registration_no IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: tax_registration_no' USING ERRCODE = 'P0001';
    END IF;
    RETURN r;
END;
$$;

-- Rule 2: the unique national ID per shop as the contract's code, naming who already has it.
CREATE FUNCTION app.customer_national_id_taken(p_org uuid, p_national_id text)
RETURNS void LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_id uuid; v_name text;
BEGIN
    SELECT c.id, c.full_name INTO v_id, v_name FROM public.customers c
    WHERE c.organization_id = p_org AND c.national_id = p_national_id;
    RAISE EXCEPTION 'CUSTOMER_NATIONAL_ID_TAKEN' USING ERRCODE = 'P0001',
        DETAIL = jsonb_build_object('customer_id', v_id, 'full_name', v_name)::text;
END;
$$;

REVOKE ALL ON FUNCTION app.ascii_digits(text), app.search_text(text), app.parse_national_id(text),
    app.mask_national_id(text), app.normalize_customer_phone(text), app.can_read_customers(),
    app.customer_read_guard(), app.customer_json(uuid, uuid, boolean),
    app.customer_fields_json(public.customers), app.customer_apply(public.customers, jsonb),
    app.customer_national_id_taken(uuid, text)
    FROM PUBLIC, anon, authenticated;

-- 3. Reads (rule 6) -----------------------------------------------------------------------------

-- Search (rule 7). Ordered by name, then id.
CREATE FUNCTION public.list_customers(p_search text DEFAULT NULL, p_status text DEFAULT 'all',
                                      p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; v_pii boolean; v_search text; v_name text; v_digits text; v_phone text;
    v_id_exact text; v_id_prefix text; v_result jsonb;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    v_pii := app.has_permission('customer.view_pii');
    IF COALESCE(p_status, 'all') NOT IN ('all', 'active', 'watch', 'blocked')
       OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    v_search := NULLIF(btrim(p_search), '');
    IF length(v_search) > 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: search' USING ERRCODE = 'P0001';
    END IF;
    v_name := app.search_text(replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_'));
    -- Phones are stored normalised, so the search text is normalised the same way.
    v_phone := ltrim(app.normalize_customer_phone(v_search), '+');
    IF v_phone !~ '^[0-9]{3,}$' THEN
        v_phone := NULL;
    END IF;
    -- The whole ID finds its customer for everyone; a prefix would let a caller without
    -- customer.view_pii read an ID digit by digit, so it needs the permission.
    v_digits := regexp_replace(app.ascii_digits(v_search), '[[:space:]-]', '', 'g');
    IF v_digits ~ '^[0-9]{14}$' THEN
        v_id_exact := v_digits;
    ELSIF v_pii AND v_digits ~ '^[0-9]{4,13}$' THEN
        v_id_prefix := v_digits;
    END IF;

    WITH found AS (
        SELECT c.id, c.full_name FROM public.customers c
        WHERE c.organization_id = v_org AND c.archived_at IS NULL
          AND (COALESCE(p_status, 'all') = 'all' OR c.status::text = p_status)
          AND (v_search IS NULL
               OR app.search_text(c.full_name) LIKE '%' || v_name || '%'
               OR (v_phone IS NOT NULL
                   AND EXISTS (SELECT 1 FROM unnest(c.phones) ph WHERE ph LIKE '%' || v_phone || '%'))
               OR (v_id_exact IS NOT NULL AND c.national_id = v_id_exact)
               OR (v_id_prefix IS NOT NULL AND c.national_id LIKE v_id_prefix || '%'))
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(app.customer_json(v_org, pg.id, v_pii) ORDER BY pg.full_name, pg.id)
            FROM (SELECT f.* FROM found f ORDER BY f.full_name, f.id LIMIT p_limit OFFSET p_offset) pg), '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

CREATE FUNCTION public.get_customer(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_json jsonb;
BEGIN
    PERFORM app.customer_read_guard();
    v_json := app.customer_json(app.current_org_id(), p_id, app.has_permission('customer.view_pii'));
    IF v_json IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_json;
END;
$$;

-- 4. Writes -------------------------------------------------------------------------------------

-- customer.create. The answer follows the PII rule too: a cashier who has just typed the ID gets
-- it back masked.
CREATE FUNCTION public.create_customer(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; r public.customers; v_row public.customers;
BEGIN
    v_emp := app.require_permission('customer.create');
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    IF NOT (p ? 'full_name') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: full_name' USING ERRCODE = 'P0001';
    END IF;
    IF NOT (p ? 'phones') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: phones' USING ERRCODE = 'P0001';
    END IF;
    r.is_business := false;
    r := app.customer_apply(r, p);
    BEGIN
        INSERT INTO public.customers (organization_id, full_name, phones, national_id, birth_date, gender,
            address, city, job, employer, monthly_income, is_business, tax_registration_no, notes,
            created_by, updated_by)
        VALUES (v_org, r.full_name, r.phones, r.national_id, r.birth_date, r.gender,
            r.address, r.city, r.job, r.employer, r.monthly_income, r.is_business, r.tax_registration_no,
            r.notes, v_emp, v_emp)
        RETURNING * INTO v_row;
    EXCEPTION WHEN unique_violation THEN
        PERFORM app.customer_national_id_taken(v_org, r.national_id);
    END;
    PERFORM app.write_audit('customer.created', 'customer', v_row.id,
        p_after => app.customer_fields_json(v_row));
    RETURN app.customer_json(v_org, v_row.id, app.has_permission('customer.view_pii'));
EXCEPTION
    WHEN check_violation OR not_null_violation OR invalid_text_representation OR numeric_value_out_of_range
         OR datetime_field_overflow OR invalid_datetime_format THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: customer' USING ERRCODE = 'P0001';
END;
$$;

-- customer.edit. Before/after hold the changed keys only; a change of the national ID shows as
-- its masks plus national_id_changed (the number itself never reaches the audit log) and is
-- written with severity warning when it replaces or removes an existing ID.
CREATE FUNCTION public.update_customer(p_id uuid, p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_pii boolean; v_old public.customers; r public.customers;
    v_old_json jsonb; v_new_json jsonb; v_before jsonb; v_after jsonb; v_id_changed boolean;
BEGIN
    v_emp := app.require_permission('customer.edit');
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    v_pii := app.has_permission('customer.view_pii');
    IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_old FROM public.customers
    WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    -- Rule 3: checked before the value is looked at.
    IF p_changes ? 'national_id' AND v_old.national_id IS NOT NULL AND NOT v_pii THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: customer.view_pii' USING ERRCODE = '42501';
    END IF;

    r := app.customer_apply(v_old, p_changes);
    v_old_json := app.customer_fields_json(v_old);
    v_new_json := app.customer_fields_json(r);
    v_id_changed := r.national_id IS DISTINCT FROM v_old.national_id;
    IF v_new_json = v_old_json AND NOT v_id_changed THEN
        RETURN app.customer_json(v_org, p_id, v_pii);     -- no change: no update, no audit row
    END IF;

    BEGIN
        UPDATE public.customers SET
            full_name = r.full_name, phones = r.phones, national_id = r.national_id,
            birth_date = r.birth_date, gender = r.gender, address = r.address, city = r.city,
            job = r.job, employer = r.employer, monthly_income = r.monthly_income,
            is_business = r.is_business, tax_registration_no = r.tax_registration_no, notes = r.notes,
            updated_by = v_emp
        WHERE id = p_id;
    EXCEPTION WHEN unique_violation THEN
        PERFORM app.customer_national_id_taken(v_org, r.national_id);
    END;

    SELECT COALESCE(jsonb_object_agg(k, v_old_json -> k), '{}'::jsonb),
           COALESCE(jsonb_object_agg(k, v_new_json -> k), '{}'::jsonb)
    INTO v_before, v_after
    FROM jsonb_object_keys(v_new_json) k
    WHERE (v_old_json -> k) IS DISTINCT FROM (v_new_json -> k);
    IF v_id_changed THEN
        v_before := v_before || jsonb_build_object('national_id_masked', v_old_json -> 'national_id_masked');
        v_after := v_after || jsonb_build_object('national_id_masked', v_new_json -> 'national_id_masked',
                                                 'national_id_changed', true);
    END IF;
    PERFORM app.write_audit('customer.updated', 'customer', p_id, p_before => v_before, p_after => v_after,
        p_severity => CASE WHEN v_id_changed AND v_old.national_id IS NOT NULL
                           THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN app.customer_json(v_org, p_id, v_pii);
EXCEPTION
    WHEN check_violation OR not_null_violation OR invalid_text_representation OR numeric_value_out_of_range
         OR datetime_field_overflow OR invalid_datetime_format THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: customer' USING ERRCODE = 'P0001';
END;
$$;

-- customer.edit. Rule 5: active or blocked; blocking needs a reason (3-300 characters), kept in
-- the audit row (customer.status_set; a warning when blocking). The same status again changes
-- nothing and writes no audit row.
CREATE FUNCTION public.set_customer_status(p_id uuid, p_status text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_pii boolean; v_old public.customers; v_reason text;
BEGIN
    v_emp := app.require_permission('customer.edit');
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    v_pii := app.has_permission('customer.view_pii');
    IF p_status IS NULL OR p_status NOT IN ('active', 'blocked') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: status' USING ERRCODE = 'P0001';
    END IF;
    v_reason := NULLIF(btrim(p_reason), '');
    IF length(v_reason) > 300 OR (p_status = 'blocked' AND COALESCE(length(v_reason), 0) < 3) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_old FROM public.customers
    WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_old.status::text = p_status THEN
        RETURN app.customer_json(v_org, p_id, v_pii);
    END IF;

    UPDATE public.customers SET status = p_status::public.customer_status, updated_by = v_emp
    WHERE id = p_id;
    PERFORM app.write_audit('customer.status_set', 'customer', p_id,
        p_before => jsonb_build_object('status', v_old.status),
        p_after => jsonb_build_object('status', p_status),
        p_reason => v_reason,
        p_severity => CASE WHEN p_status = 'blocked' THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN app.customer_json(v_org, p_id, v_pii);
END;
$$;

REVOKE ALL ON FUNCTION public.list_customers(text, text, integer, integer), public.get_customer(uuid),
    public.create_customer(jsonb), public.update_customer(uuid, jsonb),
    public.set_customer_status(uuid, text, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_customers(text, text, integer, integer), public.get_customer(uuid),
    public.create_customer(jsonb), public.update_customer(uuid, jsonb),
    public.set_customer_status(uuid, text, text)
    TO authenticated;
