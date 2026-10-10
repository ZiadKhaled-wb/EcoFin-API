-- =============================================================================
-- R01 follow-up (EC-63, D63 edited): decisions of 10 Oct after the first merge.
--   * A cashier may upload ID card photos: register_file asks customer.create (was customer.edit)
--     for the purpose customer_id. Reading them still needs customer.view_pii.
--   * Birth date and gender are never typed: customer_apply refuses both keys; with a national ID
--     they are read from it, and they go when the ID is removed.
--   * The governorate of birth (the ID's digits 8-9) is read from the ID and returned to everyone
--     as governorate_code, like the birth date; the number itself stays masked.
--   * "A national ID is a must for installments" is enforced by the installment sale (N02), which
--     reads customers.national_id; cash sales don't need it.
-- Replaces three functions (same signatures, so grants stay); nothing else changes.
-- =============================================================================
CREATE OR REPLACE FUNCTION app.customer_apply(r public.customers, c jsonb)
RETURNS public.customers LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE
    v_key text; v_txt text; v_phones text[];
    v_birth date; v_gender text;
    v_texts constant text[] := ARRAY['national_id', 'address', 'city', 'job',
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

    -- Rule 1 (D63): birth date and gender are never typed. With a national ID they are read from
    -- it; once the ID is removed they go with it.
    IF r.national_id IS NOT NULL THEN
        SELECT p.birth_date, p.gender INTO v_birth, v_gender FROM app.parse_national_id(r.national_id) p;
        IF v_birth IS NULL OR v_birth > current_date + 1 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: national_id' USING ERRCODE = 'P0001';
        END IF;
        r.birth_date := v_birth;
        r.gender := v_gender;
    ELSIF c ? 'national_id' THEN
        r.birth_date := NULL;
        r.gender := NULL;
    END IF;
    IF r.is_business AND r.tax_registration_no IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: tax_registration_no' USING ERRCODE = 'P0001';
    END IF;
    RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION app.customer_json(p_org uuid, p_id uuid, p_pii boolean)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', c.id, 'full_name', c.full_name, 'phones', to_jsonb(c.phones),
        'national_id', CASE WHEN p_pii THEN c.national_id END,
        'national_id_masked', app.mask_national_id(c.national_id),
        'birth_date', c.birth_date, 'gender', c.gender,
        'governorate_code', (SELECT p.governorate_code FROM app.parse_national_id(c.national_id) p),
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
        WHEN 'other'            THEN 'org.settings_manage'
    END);
    v_org   uuid := app.current_org_id();
    v_table text;
    v_found boolean;
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
