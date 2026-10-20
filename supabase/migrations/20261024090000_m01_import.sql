-- =============================================================================
-- M01 · Import: products, customers, suppliers, opening stock (EC-100, D83)
--
-- A shop moving to EcoFin loads what it has from Excel or CSV. The API reads the file and passes
-- plain rows (field key -> text) to SQL; ALL rules, matching and writes are here, so the dry run
-- and the import use the same checks:
--
--   app.import_<kind>(org, employee, rows, apply, ...)   one function per kind. apply = false is
--       the dry run (no writes at all); apply = true runs the same checks AND writes, row by row.
--       Every row error is collected (code, column, message); the caller rolls everything back when
--       there is one (all or nothing).
--   public.create_import      the dry run: stores the job and its report; saves nothing else.
--   public.queue_import       validated -> importing, queues the background job 'import.apply'.
--   public.jobs_import_apply  (service role) the import itself, in one transaction; re-runs the
--                             checks first (data may have changed since the dry run).
--   public.list_import_jobs / get_import_job / cancel_import_job / attach_import_result
--   public.jobs_import_prepare / jobs_import_fail / jobs_import_attach_result  (service role)
--
-- Rules (D83): a re-import updates the records it matches and never duplicates them; an empty cell
-- leaves the stored value alone; products match by SKU (barcode when there is none), suppliers by
-- name then phone among the active ones, customers by national ID then name + first phone, opening
-- stock by product (and serial). Opening stock is posted as 'opening' movements (serials through
-- app.create_units) in product order, and sets products.avg_cost for a product that has only
-- opening stock (the one place outside purchase approval that does). One audit row per import.
-- Numbered after the newest migration on main (D39).
-- =============================================================================

-- 1. Helpers (no grants) ------------------------------------------------------------------------

-- The same answer as app.has_permission, for a named employee (the import job runs without a
-- session). Inactive or archived employees hold nothing.
CREATE FUNCTION app.employee_has_permission(p_emp uuid, p_key text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE((
        SELECT CASE
            WHEN e.role = 'OWNER' THEN true
            ELSE COALESCE(
                (SELECT o.granted FROM public.employee_permission_overrides o
                 WHERE o.employee_id = e.id AND o.permission_key = p_key),
                EXISTS (SELECT 1 FROM public.role_permissions rp
                        WHERE rp.role = e.role AND rp.permission_key = p_key))
        END
        FROM public.employees e
        WHERE e.id = p_emp AND e.is_active AND e.archived_at IS NULL), false)
$$;

CREATE FUNCTION app.employee_has_branch(p_emp uuid, p_branch uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.employees e
        JOIN public.branches b ON b.id = p_branch AND b.organization_id = e.organization_id AND b.is_active
        WHERE e.id = p_emp AND e.is_active AND e.archived_at IS NULL
          AND (e.role = 'OWNER'
               OR EXISTS (SELECT 1 FROM public.employee_branches eb
                          WHERE eb.employee_id = e.id AND eb.branch_id = p_branch)))
$$;

-- What the importer must be allowed to do on its own: every kind's write keys (an update of a
-- price or a customer needs the edit key too).
CREATE FUNCTION app.import_required_keys(p_kind text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT CASE p_kind
        WHEN 'products' THEN ARRAY['import.data', 'catalog.manage', 'catalog.price_change']
        WHEN 'customers' THEN ARRAY['import.data', 'customer.create', 'customer.edit']
        WHEN 'suppliers' THEN ARRAY['import.data', 'supplier.manage']
        WHEN 'opening_stock' THEN ARRAY['import.data', 'stock.adjust']
    END
$$;

-- The field keys of each kind (the contract's IMPORT_COLUMNS; a test keeps the two equal).
CREATE FUNCTION app.import_kind_columns(p_kind text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT CASE p_kind
        WHEN 'suppliers' THEN ARRAY['name', 'phone', 'tax_registration_no', 'address', 'payment_terms_days', 'notes']
        WHEN 'products' THEN ARRAY['sku', 'name_ar', 'name_en', 'cash_price', 'barcode', 'category', 'unit_of_measure',
            'installment_price', 'tax_class', 'warranty_months', 'is_serialized', 'min_stock', 'eta_item_code', 'eta_item_type']
        WHEN 'customers' THEN ARRAY['full_name', 'phones', 'national_id', 'birth_date', 'gender', 'address', 'city', 'job',
            'employer', 'monthly_income', 'is_business', 'tax_registration_no', 'notes']
        WHEN 'opening_stock' THEN ARRAY['sku', 'barcode', 'quantity', 'serial', 'unit_cost']
    END
$$;

-- Row error codes that may appear in a report (the contract's IMPORT_ROW_ERROR_CODES).
CREATE FUNCTION app.import_row_codes()
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT ARRAY['IMPORT_REQUIRED', 'IMPORT_INVALID_VALUE', 'IMPORT_DUPLICATE_ROW', 'IMPORT_AMBIGUOUS_MATCH',
        'IMPORT_APPLY_FAILED', 'PRODUCT_ARCHIVED', 'PRODUCT_NOT_FOUND', 'PRODUCT_SKU_TAKEN', 'PRODUCT_BARCODE_TAKEN',
        'PRODUCT_SERIAL_LOCKED', 'PRODUCT_CATEGORY_ARCHIVED', 'CATEGORY_DEPTH', 'CATEGORY_NAME_TAKEN',
        'CUSTOMER_NATIONAL_ID_TAKEN', 'CUSTOMER_NATIONAL_ID_LOCKED', 'NATIONAL_ID_INVALID', 'SUPPLIER_PHONE_TAKEN',
        'SUPPLIER_NAME_TAKEN', 'SERIAL_INVALID', 'SERIAL_TAKEN', 'UNIT_NOT_ALLOWED', 'UNIT_REQUIRED',
        'OPENING_STOCK_LOCKED', 'TAX_CLASS_NOT_FOUND', 'MODULE_NOT_IN_PLAN', 'OUT_OF_STOCK']
$$;

-- 2. Cell readers: text in, a typed value out, or IMPORT_INVALID_VALUE naming the column ---------

-- Digits with up to two decimals ("1500", "1500.50"). Thousands separators get their own message.
CREATE FUNCTION app.import_money(p_col text, p_val text)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v text := app.ascii_digits(btrim(p_val));
BEGIN
    IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
    IF v ~ '^[0-9]{1,16}(\.[0-9]{1,2})?$' THEN RETURN v::numeric; END IF;
    IF v ~ '^[0-9]{1,3}([,.٬ ][0-9]{3})+([.,][0-9]{1,2})?$' THEN
        RAISE EXCEPTION 'IMPORT_INVALID_VALUE: %: remove the thousands separator', p_col;
    END IF;
    RAISE EXCEPTION 'IMPORT_INVALID_VALUE: %: not an amount (digits with at most 2 decimals)', p_col;
END;
$$;

CREATE FUNCTION app.import_int(p_col text, p_val text, p_min integer, p_max integer)
RETURNS integer LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v text := app.ascii_digits(btrim(p_val));
BEGIN
    IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
    IF v ~ '^[0-9]{1,9}$' AND v::integer BETWEEN p_min AND p_max THEN RETURN v::integer; END IF;
    RAISE EXCEPTION 'IMPORT_INVALID_VALUE: %: a whole number from % to %', p_col, p_min, p_max;
END;
$$;

CREATE FUNCTION app.import_bool(p_col text, p_val text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v text := lower(btrim(p_val));
BEGIN
    IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
    IF v IN ('yes', 'y', 'true', '1', U&'\0646\0639\0645') THEN RETURN true; END IF;
    IF v IN ('no', 'n', 'false', '0', U&'\0644\0627') THEN RETURN false; END IF;
    RAISE EXCEPTION 'IMPORT_INVALID_VALUE: %: yes or no', p_col;
END;
$$;

-- YYYY-MM-DD, or day first (31/12/1990, 31-12-1990).
CREATE FUNCTION app.import_date(p_col text, p_val text)
RETURNS date LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v text := app.ascii_digits(btrim(p_val)); m text[];
BEGIN
    IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
    IF v ~ '^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$' THEN
        m := regexp_split_to_array(v, '-');
        RETURN make_date(m[1]::integer, m[2]::integer, m[3]::integer);
    END IF;
    IF v ~ '^[0-9]{1,2}[/.-][0-9]{1,2}[/.-][0-9]{4}$' THEN
        m := regexp_split_to_array(v, '[/.-]');
        RETURN make_date(m[3]::integer, m[2]::integer, m[1]::integer);
    END IF;
    RAISE EXCEPTION 'IMPORT_INVALID_VALUE: %: a date as YYYY-MM-DD', p_col;
EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
    RAISE EXCEPTION 'IMPORT_INVALID_VALUE: %: not a real date', p_col;
END;
$$;

CREATE FUNCTION app.import_gender(p_col text, p_val text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v text := lower(btrim(p_val));
BEGIN
    IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
    IF v IN ('male', 'm', U&'\0630\0643\0631') THEN RETURN 'male'; END IF;
    IF v IN ('female', 'f', U&'\0623\0646\062B\0649', U&'\0627\0646\062B\0649') THEN RETURN 'female'; END IF;
    RAISE EXCEPTION 'IMPORT_INVALID_VALUE: %: male or female', p_col;
END;
$$;

-- A cell of several phones, separated by ; , | / or a new line.
CREATE FUNCTION app.import_phone_list(p text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT COALESCE(array_agg(x ORDER BY o) FILTER (WHERE x <> ''), '{}')
    FROM (SELECT btrim(t) AS x, o FROM unnest(regexp_split_to_array(
        COALESCE(app.ascii_digits(p), ''), U&'[;,\060C|/\000A\000D]+')) WITH ORDINALITY u(t, o)) s
$$;

-- The cleaned national ID of a cell (digits only), '' when there is none.
CREATE FUNCTION app.import_national_id(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$ SELECT regexp_replace(app.ascii_digits(btrim(COALESCE(p, ''))), '[[:space:]-]', '', 'g') $$;

-- Who a customer row is, for repeats inside one file: the national ID, else name + first phone.
CREATE FUNCTION app.import_customer_key(v jsonb)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT CASE WHEN app.import_national_id(v ->> 'national_id') <> ''
                THEN 'id:' || app.import_national_id(v ->> 'national_id')
                ELSE 'np:' || app.search_text(regexp_replace(btrim(COALESCE(v ->> 'full_name', '')), '[[:space:]]+', ' ', 'g'))
                           || '|' || COALESCE(app.normalize_customer_phone((app.import_phone_list(v ->> 'phones'))[1]), '')
           END
$$;

-- A supplier phone as it is stored (spaces and dashes removed).
CREATE FUNCTION app.import_supplier_phone(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$ SELECT NULLIF(regexp_replace(app.ascii_digits(btrim(COALESCE(p, ''))), '[[:space:]-]', '', 'g'), '') $$;

-- A row's error as a report entry. The message is "CODE", "CODE: detail" or "CODE: column: detail"
-- (our own raises) and the existing write functions' "VALIDATION_FAILED: column" / NAME_REQUIRED.
-- Anything that is not a known code is IMPORT_APPLY_FAILED: raw database text never reaches a report.
CREATE FUNCTION app.import_error(p_row integer, p_kind text, p_state text, p_msg text)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE
    v_code text := substring(COALESCE(p_msg, '') FROM '^([A-Z][A-Z0-9_]*)');
    v_rest text; v_col text; v_text text;
    v_cols text[] := app.import_kind_columns(p_kind);
BEGIN
    IF v_code IS NULL THEN
        RETURN jsonb_build_object('row', p_row, 'column', NULL, 'code', 'IMPORT_APPLY_FAILED', 'message', 'database error ' || p_state);
    END IF;
    v_rest := btrim(regexp_replace(substr(p_msg, length(v_code) + 1), '^[[:space:]]*:[[:space:]]*', ''));
    IF v_code = 'VALIDATION_FAILED' THEN
        v_col := v_rest;
        IF v_col = 'national_id' THEN
            RETURN jsonb_build_object('row', p_row, 'column', 'national_id', 'code', 'NATIONAL_ID_INVALID',
                                      'message', 'not a valid 14-digit national ID');
        END IF;
        RETURN jsonb_build_object('row', p_row, 'column', CASE WHEN v_col = ANY (v_cols) THEN v_col END,
            'code', 'IMPORT_INVALID_VALUE', 'message', 'invalid value');
    END IF;
    IF v_code = 'NAME_REQUIRED' THEN
        RETURN jsonb_build_object('row', p_row, 'column', 'name_ar', 'code', 'IMPORT_REQUIRED', 'message', 'a name is required');
    END IF;
    IF v_code <> ALL (app.import_row_codes()) THEN
        RETURN jsonb_build_object('row', p_row, 'column', NULL, 'code', 'IMPORT_APPLY_FAILED', 'message', 'database error ' || p_state);
    END IF;
    v_text := v_rest;
    IF v_rest ~ '^[a-z_]+:[[:space:]]' AND split_part(v_rest, ':', 1) = ANY (v_cols) THEN
        v_col := split_part(v_rest, ':', 1);
        v_text := btrim(substr(v_rest, length(v_col) + 2));
    END IF;
    v_col := COALESCE(v_col, CASE v_code
        WHEN 'PRODUCT_BARCODE_TAKEN' THEN 'barcode'
        WHEN 'PRODUCT_SKU_TAKEN' THEN 'sku'
        WHEN 'PRODUCT_ARCHIVED' THEN 'sku'
        WHEN 'TAX_CLASS_NOT_FOUND' THEN 'tax_class'
        WHEN 'PRODUCT_CATEGORY_ARCHIVED' THEN 'category'
        WHEN 'CATEGORY_DEPTH' THEN 'category'
        WHEN 'CATEGORY_NAME_TAKEN' THEN 'category'
        WHEN 'PRODUCT_SERIAL_LOCKED' THEN 'is_serialized'
        WHEN 'CUSTOMER_NATIONAL_ID_TAKEN' THEN 'national_id'
        WHEN 'CUSTOMER_NATIONAL_ID_LOCKED' THEN 'national_id'
        WHEN 'NATIONAL_ID_INVALID' THEN 'national_id'
        WHEN 'SUPPLIER_PHONE_TAKEN' THEN 'phone'
        WHEN 'SUPPLIER_NAME_TAKEN' THEN 'name'
        WHEN 'SERIAL_INVALID' THEN 'serial'
        WHEN 'SERIAL_TAKEN' THEN 'serial'
        WHEN 'UNIT_NOT_ALLOWED' THEN 'serial'
        WHEN 'UNIT_REQUIRED' THEN 'serial'
        WHEN 'OPENING_STOCK_LOCKED' THEN 'sku'
        WHEN 'OUT_OF_STOCK' THEN 'quantity'
    END);
    IF v_col IS NOT NULL AND NOT (v_col = ANY (v_cols)) THEN v_col := NULL; END IF;
    RETURN jsonb_build_object('row', p_row, 'column', v_col, 'code', v_code,
        'message', left(COALESCE(NULLIF(v_text, ''), v_code), 300));
END;
$$;

-- A category path of one or two levels ("Phones" or "Phones > Samsung"), found or created. In a dry
-- run (p_apply false) nothing is created and a missing category comes back as id NULL. 'created' lists
-- the paths that are (or would be) new; p_known lists those already queued by earlier rows, so the
-- same new category is listed once and a new name that clashes with one queued above is refused.
CREATE FUNCTION app.import_category(p_org uuid, p_emp uuid, p_parts text[], p_apply boolean, p_known text[])
RETURNS jsonb LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
    v_parent public.categories; v_child public.categories; v_parent_id uuid; v_id uuid;
    v_created text[] := '{}'; v_pname text; v_cname text; v_path text; v_other text;
BEGIN
    IF cardinality(p_parts) > 2 THEN
        RAISE EXCEPTION 'CATEGORY_DEPTH: category: only a category and one sub-category are allowed';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(p_parts) x WHERE length(x) > 60) THEN
        RAISE EXCEPTION 'IMPORT_INVALID_VALUE: category: a category name is at most 60 characters';
    END IF;
    IF cardinality(p_parts) = 1 THEN
        v_cname := p_parts[1];
        SELECT * INTO v_child FROM public.categories c WHERE c.organization_id = p_org AND c.name = v_cname;
        IF FOUND THEN
            IF v_child.archived_at IS NOT NULL THEN
                RAISE EXCEPTION 'PRODUCT_CATEGORY_ARCHIVED: category: % is archived', v_cname;
            END IF;
            RETURN jsonb_build_object('id', v_child.id, 'created', to_jsonb(v_created));
        END IF;
        -- Queued by an earlier row as a sub-category: the name is taken.
        SELECT k INTO v_other FROM unnest(p_known) k WHERE right(k, length(v_cname) + 3) = ' > ' || v_cname LIMIT 1;
        IF v_other IS NOT NULL THEN
            RAISE EXCEPTION 'CATEGORY_NAME_TAKEN: category: % is a sub-category of another category', v_cname;
        END IF;
        IF v_cname = ANY (p_known) THEN
            RETURN jsonb_build_object('id', NULL, 'created', to_jsonb(v_created));
        END IF;
        v_created := ARRAY[v_cname];
        IF p_apply THEN
            INSERT INTO public.categories (organization_id, name, parent_id, created_by, updated_by)
            VALUES (p_org, v_cname, NULL, p_emp, p_emp) RETURNING id INTO v_id;
        END IF;
        RETURN jsonb_build_object('id', v_id, 'created', to_jsonb(v_created));
    END IF;

    v_pname := p_parts[1]; v_cname := p_parts[2]; v_path := v_pname || ' > ' || v_cname;
    SELECT * INTO v_parent FROM public.categories c WHERE c.organization_id = p_org AND c.name = v_pname;
    IF FOUND THEN
        IF v_parent.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'PRODUCT_CATEGORY_ARCHIVED: category: % is archived', v_pname;
        END IF;
        IF v_parent.parent_id IS NOT NULL THEN
            RAISE EXCEPTION 'CATEGORY_DEPTH: category: % is itself a sub-category', v_pname;
        END IF;
        v_parent_id := v_parent.id;
    ELSE
        IF EXISTS (SELECT 1 FROM unnest(p_known) k WHERE right(k, length(v_pname) + 3) = ' > ' || v_pname) THEN
            RAISE EXCEPTION 'CATEGORY_DEPTH: category: % is itself a sub-category', v_pname;
        END IF;
        IF NOT (v_pname = ANY (p_known)) THEN
            v_created := v_created || v_pname;
            IF p_apply THEN
                INSERT INTO public.categories (organization_id, name, parent_id, created_by, updated_by)
                VALUES (p_org, v_pname, NULL, p_emp, p_emp) RETURNING id INTO v_parent_id;
            END IF;
        END IF;
    END IF;

    SELECT * INTO v_child FROM public.categories c WHERE c.organization_id = p_org AND c.name = v_cname;
    IF FOUND THEN
        IF v_child.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'PRODUCT_CATEGORY_ARCHIVED: category: % is archived', v_cname;
        END IF;
        IF v_child.parent_id IS DISTINCT FROM v_parent.id OR v_parent.id IS NULL THEN
            RAISE EXCEPTION 'CATEGORY_NAME_TAKEN: category: % already exists under another category', v_cname;
        END IF;
        RETURN jsonb_build_object('id', v_child.id, 'created', to_jsonb(v_created));
    END IF;
    SELECT k INTO v_other FROM unnest(p_known) k
    WHERE k = v_cname OR (right(k, length(v_cname) + 3) = ' > ' || v_cname AND k <> v_path) LIMIT 1;
    IF v_other IS NOT NULL THEN
        RAISE EXCEPTION 'CATEGORY_NAME_TAKEN: category: % already exists under another category', v_cname;
    END IF;
    IF v_path = ANY (p_known) THEN
        RETURN jsonb_build_object('id', NULL, 'created', to_jsonb(v_created));
    END IF;
    v_created := v_created || v_path;
    IF p_apply THEN
        INSERT INTO public.categories (organization_id, name, parent_id, created_by, updated_by)
        VALUES (p_org, v_cname, v_parent_id, p_emp, p_emp) RETURNING id INTO v_id;
    END IF;
    RETURN jsonb_build_object('id', v_id, 'created', to_jsonb(v_created));
END;
$$;

-- 3. Suppliers -----------------------------------------------------------------------------------

CREATE FUNCTION app.import_suppliers(p_org uuid, p_emp uuid, p_rows jsonb, p_apply boolean)
RETURNS jsonb LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
    r record; v jsonb; c jsonb; v_errors jsonb := '[]'::jsonb; v_err integer := 0; v_preview jsonb := '[]'::jsonb;
    v_create integer := 0; v_update integer := 0; v_same integer := 0; v_first_name jsonb; v_first_phone jsonb;
    v_name text; v_phone text; v_existing public.suppliers; v_new public.suppliers; v_found boolean; v_action text;
    v_id uuid; v_constraint text; v_msg text; v_state text; v_key text;
BEGIN
    WITH rows AS (
        SELECT (e ->> 'row')::integer AS rn, e -> 'values' AS vals FROM jsonb_array_elements(p_rows) e),
    keyed AS (
        SELECT rn, lower(NULLIF(btrim(vals ->> 'name'), '')) AS k, app.import_supplier_phone(vals ->> 'phone') AS ph FROM rows)
    SELECT (SELECT jsonb_object_agg(k, f) FROM (SELECT k, min(rn) AS f FROM keyed WHERE k IS NOT NULL GROUP BY k HAVING count(*) > 1) x),
           (SELECT jsonb_object_agg(ph, f) FROM (SELECT ph, min(rn) AS f FROM keyed WHERE ph IS NOT NULL GROUP BY ph HAVING count(*) > 1) y)
    INTO v_first_name, v_first_phone;

    FOR r IN SELECT (e.value ->> 'row')::integer AS rn, e.value -> 'values' AS vals
             FROM jsonb_array_elements(p_rows) WITH ORDINALITY e(value, ord) ORDER BY e.ord
    LOOP
        v_action := NULL;
        BEGIN
            v := r.vals;
            v_name := NULLIF(btrim(v ->> 'name'), '');
            IF v_name IS NULL THEN
                RAISE EXCEPTION 'IMPORT_REQUIRED: name: the supplier name is required';
            END IF;
            v_key := lower(v_name);
            IF v_first_name ? v_key AND (v_first_name ->> v_key)::integer <> r.rn THEN
                RAISE EXCEPTION 'IMPORT_DUPLICATE_ROW: name: same supplier as row %', v_first_name ->> v_key;
            END IF;
            v_phone := app.import_supplier_phone(v ->> 'phone');
            IF v_phone IS NOT NULL AND v_first_phone ? v_phone AND (v_first_phone ->> v_phone)::integer <> r.rn THEN
                RAISE EXCEPTION 'IMPORT_DUPLICATE_ROW: phone: same phone as row %', v_first_phone ->> v_phone;
            END IF;

            c := jsonb_build_object('name', v_name);
            IF v_phone IS NOT NULL THEN c := c || jsonb_build_object('phone', v_phone); END IF;
            IF NULLIF(btrim(v ->> 'tax_registration_no'), '') IS NOT NULL THEN
                c := c || jsonb_build_object('tax_registration_no', btrim(v ->> 'tax_registration_no'));
            END IF;
            IF NULLIF(btrim(v ->> 'address'), '') IS NOT NULL THEN c := c || jsonb_build_object('address', btrim(v ->> 'address')); END IF;
            IF NULLIF(btrim(v ->> 'notes'), '') IS NOT NULL THEN c := c || jsonb_build_object('notes', btrim(v ->> 'notes')); END IF;
            IF NULLIF(btrim(v ->> 'payment_terms_days'), '') IS NOT NULL THEN
                c := c || jsonb_build_object('payment_terms_days', app.import_int('payment_terms_days', v ->> 'payment_terms_days', 0, 365));
            END IF;

            -- Active suppliers only (U01 rule 1): by name, else by phone.
            IF p_apply THEN
                SELECT * INTO v_existing FROM public.suppliers s
                WHERE s.organization_id = p_org AND s.archived_at IS NULL AND lower(btrim(s.name)) = v_key FOR UPDATE;
            ELSE
                SELECT * INTO v_existing FROM public.suppliers s
                WHERE s.organization_id = p_org AND s.archived_at IS NULL AND lower(btrim(s.name)) = v_key;
            END IF;
            v_found := FOUND;
            IF NOT v_found AND v_phone IS NOT NULL THEN
                IF p_apply THEN
                    SELECT * INTO v_existing FROM public.suppliers s
                    WHERE s.organization_id = p_org AND s.archived_at IS NULL AND s.phone = v_phone FOR UPDATE;
                ELSE
                    SELECT * INTO v_existing FROM public.suppliers s
                    WHERE s.organization_id = p_org AND s.archived_at IS NULL AND s.phone = v_phone;
                END IF;
                v_found := FOUND;
            END IF;

            IF NOT v_found THEN
                v_new := NULL;
                v_new.payment_terms_days := 0;
                v_new := app.supplier_apply(v_new, c);
                v_action := 'create';
                IF p_apply THEN
                    BEGIN
                        INSERT INTO public.suppliers (organization_id, name, phone, tax_registration_no, address,
                            payment_terms_days, notes, created_by, updated_by)
                        VALUES (p_org, v_new.name, v_new.phone, v_new.tax_registration_no, v_new.address,
                            v_new.payment_terms_days, v_new.notes, p_emp, p_emp);
                    EXCEPTION WHEN unique_violation THEN
                        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
                        PERFORM app.supplier_unique_error(v_constraint);
                    END;
                END IF;
            ELSE
                v_new := app.supplier_apply(v_existing, c);
                IF v_new.phone IS DISTINCT FROM v_existing.phone AND EXISTS (
                    SELECT 1 FROM public.suppliers s WHERE s.organization_id = p_org AND s.archived_at IS NULL
                      AND s.phone = v_new.phone AND s.id <> v_existing.id) THEN
                    RAISE EXCEPTION 'SUPPLIER_PHONE_TAKEN: phone: another supplier has this phone';
                END IF;
                IF lower(btrim(v_new.name)) <> lower(btrim(v_existing.name)) AND EXISTS (
                    SELECT 1 FROM public.suppliers s WHERE s.organization_id = p_org AND s.archived_at IS NULL
                      AND lower(btrim(s.name)) = lower(btrim(v_new.name)) AND s.id <> v_existing.id) THEN
                    RAISE EXCEPTION 'SUPPLIER_NAME_TAKEN: name: another supplier has this name';
                END IF;
                IF app.supplier_fields_json(v_new) = app.supplier_fields_json(v_existing) THEN
                    v_action := 'unchanged';
                ELSE
                    v_action := 'update';
                    IF p_apply THEN
                        BEGIN
                            UPDATE public.suppliers SET name = v_new.name, phone = v_new.phone,
                                tax_registration_no = v_new.tax_registration_no, address = v_new.address,
                                payment_terms_days = v_new.payment_terms_days, notes = v_new.notes, updated_by = p_emp
                            WHERE id = v_existing.id;
                        EXCEPTION WHEN unique_violation THEN
                            GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
                            PERFORM app.supplier_unique_error(v_constraint);
                        END;
                    END IF;
                END IF;
            END IF;

            IF v_action = 'create' THEN v_create := v_create + 1;
            ELSIF v_action = 'update' THEN v_update := v_update + 1;
            ELSE v_same := v_same + 1; END IF;
            IF jsonb_array_length(v_preview) < 20 THEN
                v_preview := v_preview || jsonb_build_array(jsonb_build_object('row', r.rn, 'action', v_action, 'values', v));
            END IF;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            v_err := v_err + 1;
            IF v_err <= 5000 THEN
                v_errors := v_errors || jsonb_build_array(app.import_error(r.rn, 'suppliers', v_state, v_msg));
            END IF;
        END;
    END LOOP;
    RETURN jsonb_build_object('errors', v_errors, 'errors_total', v_err,
        'actions', jsonb_build_object('create', v_create, 'update', v_update, 'unchanged', v_same),
        'preview', v_preview, 'will_create_categories', '[]'::jsonb, 'warnings', '[]'::jsonb);
END;
$$;

-- 4. Products ------------------------------------------------------------------------------------

CREATE FUNCTION app.import_products(p_org uuid, p_emp uuid, p_rows jsonb, p_apply boolean)
RETURNS jsonb LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
    r record; v jsonb; c jsonb; v_errors jsonb := '[]'::jsonb; v_err integer := 0; v_preview jsonb := '[]'::jsonb;
    v_create integer := 0; v_update integer := 0; v_same integer := 0; v_first_sku jsonb; v_first_bc jsonb;
    v_new_cats text[] := '{}'; v_row_cats text[]; v_default_tax uuid;
    v_sku text; v_bc text; v_key text; v_name_ar text; v_price numeric; v_existing public.products; v_new public.products;
    v_found boolean; v_action text; v_txt text; v_parts text[]; v_cat jsonb; v_cat_pending boolean; v_tax uuid;
    v_id uuid; v_try integer; v_generate boolean; v_constraint text; v_msg text; v_state text; v_bool boolean;
BEGIN
    SELECT s.default_tax_class_id INTO v_default_tax FROM public.org_settings s WHERE s.organization_id = p_org;

    WITH rows AS (
        SELECT (e ->> 'row')::integer AS rn, e -> 'values' AS vals FROM jsonb_array_elements(p_rows) e),
    keyed AS (
        SELECT rn,
               COALESCE(upper(NULLIF(btrim(vals ->> 'sku'), '')), upper(NULLIF(btrim(vals ->> 'barcode'), ''))) AS k,
               NULLIF(btrim(vals ->> 'barcode'), '') AS b FROM rows)
    SELECT (SELECT jsonb_object_agg(k, f) FROM (SELECT k, min(rn) AS f FROM keyed WHERE k IS NOT NULL GROUP BY k HAVING count(*) > 1) x),
           (SELECT jsonb_object_agg(b, f) FROM (SELECT b, min(rn) AS f FROM keyed WHERE b IS NOT NULL GROUP BY b HAVING count(*) > 1) y)
    INTO v_first_sku, v_first_bc;

    FOR r IN SELECT (e.value ->> 'row')::integer AS rn, e.value -> 'values' AS vals
             FROM jsonb_array_elements(p_rows) WITH ORDINALITY e(value, ord) ORDER BY e.ord
    LOOP
        v_action := NULL; v_row_cats := '{}'; v_cat_pending := false;
        BEGIN
            v := r.vals;
            v_sku := upper(NULLIF(btrim(v ->> 'sku'), ''));
            v_bc := NULLIF(btrim(v ->> 'barcode'), '');
            IF v_sku IS NULL AND v_bc IS NULL THEN
                RAISE EXCEPTION 'IMPORT_REQUIRED: sku: a SKU or a barcode is required';
            END IF;
            v_key := COALESCE(v_sku, upper(v_bc));
            IF v_first_sku ? v_key AND (v_first_sku ->> v_key)::integer <> r.rn THEN
                RAISE EXCEPTION 'IMPORT_DUPLICATE_ROW: sku: same product as row %', v_first_sku ->> v_key;
            END IF;
            IF v_bc IS NOT NULL AND v_first_bc ? v_bc AND (v_first_bc ->> v_bc)::integer <> r.rn THEN
                RAISE EXCEPTION 'IMPORT_DUPLICATE_ROW: barcode: same barcode as row %', v_first_bc ->> v_bc;
            END IF;
            v_price := app.import_money('cash_price', v ->> 'cash_price');
            IF v_price IS NULL THEN
                RAISE EXCEPTION 'IMPORT_REQUIRED: cash_price: the cash price is required';
            END IF;

            -- The product this row is: by SKU (given, or the barcode used as SKU), then by barcode.
            IF p_apply THEN
                SELECT * INTO v_existing FROM public.products p WHERE p.organization_id = p_org AND p.sku = v_key FOR UPDATE;
            ELSE
                SELECT * INTO v_existing FROM public.products p WHERE p.organization_id = p_org AND p.sku = v_key;
            END IF;
            v_found := FOUND;
            IF NOT v_found AND v_sku IS NULL THEN
                IF p_apply THEN
                    SELECT * INTO v_existing FROM public.products p WHERE p.organization_id = p_org AND p.barcode = v_bc FOR UPDATE;
                ELSE
                    SELECT * INTO v_existing FROM public.products p WHERE p.organization_id = p_org AND p.barcode = v_bc;
                END IF;
                v_found := FOUND;
            END IF;
            IF v_found AND v_existing.archived_at IS NOT NULL THEN
                RAISE EXCEPTION 'PRODUCT_ARCHIVED: sku: restore the product first';
            END IF;

            v_name_ar := NULLIF(btrim(v ->> 'name_ar'), '');
            IF v_name_ar IS NULL AND NOT v_found THEN v_name_ar := NULLIF(btrim(v ->> 'name_en'), ''); END IF;
            IF v_name_ar IS NULL AND NOT v_found THEN
                RAISE EXCEPTION 'IMPORT_REQUIRED: name_ar: a name is required';
            END IF;

            c := jsonb_build_object('cash_price', v_price::numeric(18,2)::text);
            IF v_name_ar IS NOT NULL THEN c := c || jsonb_build_object('name_ar', v_name_ar); END IF;
            IF v_sku IS NOT NULL OR NOT v_found THEN c := c || jsonb_build_object('sku', v_key); END IF;
            IF NULLIF(btrim(v ->> 'name_en'), '') IS NOT NULL THEN c := c || jsonb_build_object('name_en', btrim(v ->> 'name_en')); END IF;
            IF v_bc IS NOT NULL THEN c := c || jsonb_build_object('barcode', v_bc); END IF;
            IF NULLIF(btrim(v ->> 'unit_of_measure'), '') IS NOT NULL THEN
                c := c || jsonb_build_object('unit_of_measure', btrim(v ->> 'unit_of_measure'));
            END IF;
            IF NULLIF(btrim(v ->> 'installment_price'), '') IS NOT NULL THEN
                c := c || jsonb_build_object('installment_price', app.import_money('installment_price', v ->> 'installment_price')::numeric(18,2)::text);
            END IF;
            IF NULLIF(btrim(v ->> 'warranty_months'), '') IS NOT NULL THEN
                c := c || jsonb_build_object('warranty_months', app.import_int('warranty_months', v ->> 'warranty_months', 0, 120));
            END IF;
            IF NULLIF(btrim(v ->> 'min_stock'), '') IS NOT NULL THEN
                c := c || jsonb_build_object('min_stock', app.import_int('min_stock', v ->> 'min_stock', 0, 1000000));
            END IF;
            v_bool := app.import_bool('is_serialized', v ->> 'is_serialized');
            IF v_bool IS NOT NULL THEN c := c || jsonb_build_object('is_serialized', v_bool); END IF;
            IF NULLIF(btrim(v ->> 'eta_item_code'), '') IS NOT NULL THEN
                c := c || jsonb_build_object('eta_item_code', btrim(v ->> 'eta_item_code'));
            END IF;
            IF NULLIF(btrim(v ->> 'eta_item_type'), '') IS NOT NULL THEN
                c := c || jsonb_build_object('eta_item_type', upper(btrim(v ->> 'eta_item_type')));
            END IF;

            -- Tax class by name; empty = the shop's default (a new product only).
            v_txt := NULLIF(btrim(v ->> 'tax_class'), '');
            IF v_txt IS NOT NULL THEN
                SELECT t.id INTO v_tax FROM public.tax_classes t
                WHERE t.organization_id = p_org AND t.archived_at IS NULL AND lower(btrim(t.name)) = lower(v_txt);
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'TAX_CLASS_NOT_FOUND: tax_class: no tax class named %', v_txt;
                END IF;
                c := c || jsonb_build_object('tax_class_id', v_tax);
            ELSIF NOT v_found THEN
                IF v_default_tax IS NULL OR NOT EXISTS (
                    SELECT 1 FROM public.tax_classes t WHERE t.id = v_default_tax AND t.organization_id = p_org AND t.archived_at IS NULL) THEN
                    RAISE EXCEPTION 'TAX_CLASS_NOT_FOUND: tax_class: the shop has no default tax class';
                END IF;
                c := c || jsonb_build_object('tax_class_id', v_default_tax);
            END IF;

            -- Category path "A" or "A > B": found, or created (listed for the dry run).
            v_txt := NULLIF(btrim(v ->> 'category'), '');
            IF v_txt IS NOT NULL THEN
                v_parts := ARRAY(SELECT btrim(x) FROM unnest(regexp_split_to_array(v_txt, '[[:space:]]*>[[:space:]]*')) x WHERE btrim(x) <> '');
                IF cardinality(v_parts) = 0 THEN
                    RAISE EXCEPTION 'IMPORT_INVALID_VALUE: category: empty category path';
                END IF;
                v_cat := app.import_category(p_org, p_emp, v_parts, p_apply, v_new_cats);
                v_row_cats := ARRAY(SELECT jsonb_array_elements_text(v_cat -> 'created'));
                IF v_cat ->> 'id' IS NOT NULL THEN
                    c := c || jsonb_build_object('category_id', v_cat ->> 'id');
                ELSE
                    v_cat_pending := true;       -- a dry run: the category is new, so the product changes
                END IF;
            END IF;

            IF NOT v_found THEN
                v_new := NULL;
                v_new.organization_id := p_org;
                v_new.unit_of_measure := 'piece';
                v_new.warranty_months := 0;
                v_new.is_serialized := false;
                v_new.min_stock := 0;
                v_new := app.product_apply(p_org, v_new, c);
                IF v_new.barcode IS NOT NULL AND EXISTS (
                    SELECT 1 FROM public.products x WHERE x.organization_id = p_org AND x.barcode = v_new.barcode) THEN
                    RAISE EXCEPTION 'PRODUCT_BARCODE_TAKEN: barcode: another product has this barcode';
                END IF;
                v_action := 'create';
                IF p_apply THEN
                    v_generate := v_new.barcode IS NULL; v_try := 0;
                    LOOP
                        IF v_generate THEN v_new.barcode := app.generate_product_barcode(); END IF;
                        BEGIN
                            INSERT INTO public.products (organization_id, name_ar, name_en, sku, barcode, category_id,
                                unit_of_measure, cash_price, installment_price, avg_cost, tax_class_id, warranty_months,
                                is_serialized, min_stock, image_file_id, eta_item_code, eta_item_type, is_active,
                                created_by, updated_by)
                            VALUES (p_org, v_new.name_ar, v_new.name_en, v_new.sku, v_new.barcode, v_new.category_id,
                                v_new.unit_of_measure, v_new.cash_price, v_new.installment_price, 0, v_new.tax_class_id,
                                v_new.warranty_months, v_new.is_serialized, v_new.min_stock, NULL, v_new.eta_item_code,
                                v_new.eta_item_type, true, p_emp, p_emp)
                            RETURNING id INTO v_id;
                            EXIT;
                        EXCEPTION WHEN unique_violation THEN
                            GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
                            IF v_constraint = 'products_sku_key' THEN
                                RAISE EXCEPTION 'PRODUCT_SKU_TAKEN: sku: another product has this SKU';
                            END IF;
                            v_try := v_try + 1;
                            IF NOT v_generate OR v_try >= 5 THEN
                                RAISE EXCEPTION 'PRODUCT_BARCODE_TAKEN: barcode: another product has this barcode';
                            END IF;
                        END;
                    END LOOP;
                END IF;
            ELSE
                v_new := app.product_apply(p_org, v_existing, c);
                IF v_new.barcode IS DISTINCT FROM v_existing.barcode AND EXISTS (
                    SELECT 1 FROM public.products x WHERE x.organization_id = p_org AND x.barcode = v_new.barcode
                      AND x.id <> v_existing.id) THEN
                    RAISE EXCEPTION 'PRODUCT_BARCODE_TAKEN: barcode: another product has this barcode';
                END IF;
                IF v_new.is_serialized IS DISTINCT FROM v_existing.is_serialized AND (
                    EXISTS (SELECT 1 FROM public.units u WHERE u.organization_id = p_org AND u.product_id = v_existing.id)
                    OR EXISTS (SELECT 1 FROM public.stock_movements m WHERE m.organization_id = p_org AND m.product_id = v_existing.id)) THEN
                    RAISE EXCEPTION 'PRODUCT_SERIAL_LOCKED: is_serialized: the product already has stock movements';
                END IF;
                IF app.product_json(v_new) = app.product_json(v_existing) AND NOT v_cat_pending THEN
                    v_action := 'unchanged';
                ELSE
                    v_action := 'update';
                    IF p_apply THEN
                        BEGIN
                            UPDATE public.products SET
                                name_ar = v_new.name_ar, name_en = v_new.name_en, sku = v_new.sku, barcode = v_new.barcode,
                                category_id = v_new.category_id, unit_of_measure = v_new.unit_of_measure,
                                cash_price = v_new.cash_price, installment_price = v_new.installment_price,
                                tax_class_id = v_new.tax_class_id, warranty_months = v_new.warranty_months,
                                is_serialized = v_new.is_serialized, min_stock = v_new.min_stock,
                                eta_item_code = v_new.eta_item_code, eta_item_type = v_new.eta_item_type, updated_by = p_emp
                            WHERE id = v_existing.id;
                        EXCEPTION WHEN unique_violation THEN
                            GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
                            IF v_constraint = 'products_sku_key' THEN
                                RAISE EXCEPTION 'PRODUCT_SKU_TAKEN: sku: another product has this SKU';
                            END IF;
                            RAISE EXCEPTION 'PRODUCT_BARCODE_TAKEN: barcode: another product has this barcode';
                        END;
                    END IF;
                END IF;
            END IF;

            v_new_cats := v_new_cats || v_row_cats;
            IF v_action = 'create' THEN v_create := v_create + 1;
            ELSIF v_action = 'update' THEN v_update := v_update + 1;
            ELSE v_same := v_same + 1; END IF;
            IF jsonb_array_length(v_preview) < 20 THEN
                v_preview := v_preview || jsonb_build_array(jsonb_build_object('row', r.rn, 'action', v_action, 'values', v));
            END IF;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            v_err := v_err + 1;
            IF v_err <= 5000 THEN
                v_errors := v_errors || jsonb_build_array(app.import_error(r.rn, 'products', v_state, v_msg));
            END IF;
        END;
    END LOOP;
    RETURN jsonb_build_object('errors', v_errors, 'errors_total', v_err,
        'actions', jsonb_build_object('create', v_create, 'update', v_update, 'unchanged', v_same),
        'preview', v_preview, 'will_create_categories', to_jsonb(v_new_cats), 'warnings', '[]'::jsonb);
END;
$$;

-- 5. Customers -----------------------------------------------------------------------------------

CREATE FUNCTION app.import_customers(p_org uuid, p_emp uuid, p_rows jsonb, p_apply boolean)
RETURNS jsonb LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
    r record; v jsonb; c jsonb; v_errors jsonb := '[]'::jsonb; v_err integer := 0; v_preview jsonb := '[]'::jsonb;
    v_create integer := 0; v_update integer := 0; v_same integer := 0; v_first jsonb; v_key text;
    v_nid text; v_phones text[]; v_p1 text; v_name text; v_name_key text; v_existing public.customers;
    v_new public.customers; v_found boolean; v_action text; v_ids uuid[]; v_txt text; v_bool boolean; v_id_changed boolean;
    v_msg text; v_state text; v_show jsonb; v_row public.customers;
BEGIN
    WITH rows AS (
        SELECT (e ->> 'row')::integer AS rn, e -> 'values' AS vals FROM jsonb_array_elements(p_rows) e),
    keyed AS (SELECT rn, app.import_customer_key(vals) AS k FROM rows)
    SELECT jsonb_object_agg(k, f) INTO v_first
    FROM (SELECT k, min(rn) AS f FROM keyed GROUP BY k HAVING count(*) > 1) x;

    FOR r IN SELECT (e.value ->> 'row')::integer AS rn, e.value -> 'values' AS vals
             FROM jsonb_array_elements(p_rows) WITH ORDINALITY e(value, ord) ORDER BY e.ord
    LOOP
        v_action := NULL;
        BEGIN
            v := r.vals;
            v_name := regexp_replace(btrim(COALESCE(v ->> 'full_name', '')), '[[:space:]]+', ' ', 'g');
            IF v_name = '' THEN
                RAISE EXCEPTION 'IMPORT_REQUIRED: full_name: the customer name is required';
            END IF;
            v_phones := app.import_phone_list(v ->> 'phones');
            IF cardinality(v_phones) = 0 THEN
                RAISE EXCEPTION 'IMPORT_REQUIRED: phones: at least one phone is required';
            END IF;
            IF cardinality(v_phones) > 5 THEN
                RAISE EXCEPTION 'IMPORT_INVALID_VALUE: phones: at most 5 phones';
            END IF;
            v_key := app.import_customer_key(v);
            IF v_first ? v_key AND (v_first ->> v_key)::integer <> r.rn THEN
                RAISE EXCEPTION 'IMPORT_DUPLICATE_ROW: %: same customer as row %',
                    CASE WHEN left(v_key, 3) = 'id:' THEN 'national_id' ELSE 'full_name' END, v_first ->> v_key;
            END IF;
            v_nid := app.import_national_id(v ->> 'national_id');
            IF v_nid <> '' AND (SELECT p.birth_date FROM app.parse_national_id(v_nid) p) IS NULL THEN
                RAISE EXCEPTION 'NATIONAL_ID_INVALID: national_id: not a valid 14-digit national ID';
            END IF;

            c := jsonb_build_object('full_name', v_name, 'phones', to_jsonb(v_phones));
            IF v_nid <> '' THEN c := c || jsonb_build_object('national_id', v_nid); END IF;
            IF NULLIF(btrim(v ->> 'birth_date'), '') IS NOT NULL THEN
                c := c || jsonb_build_object('birth_date', to_char(app.import_date('birth_date', v ->> 'birth_date'), 'YYYY-MM-DD'));
            END IF;
            IF NULLIF(btrim(v ->> 'gender'), '') IS NOT NULL THEN
                c := c || jsonb_build_object('gender', app.import_gender('gender', v ->> 'gender'));
            END IF;
            FOREACH v_txt IN ARRAY ARRAY['address', 'city', 'job', 'employer', 'notes', 'tax_registration_no'] LOOP
                IF NULLIF(btrim(v ->> v_txt), '') IS NOT NULL THEN
                    c := c || jsonb_build_object(v_txt, btrim(v ->> v_txt));
                END IF;
            END LOOP;
            IF NULLIF(btrim(v ->> 'monthly_income'), '') IS NOT NULL THEN
                c := c || jsonb_build_object('monthly_income', app.import_money('monthly_income', v ->> 'monthly_income')::numeric(18,2)::text);
            END IF;
            v_bool := app.import_bool('is_business', v ->> 'is_business');
            IF v_bool IS NOT NULL THEN c := c || jsonb_build_object('is_business', v_bool); END IF;

            -- Who this row is: the national ID, else the name + first phone (more than one = ambiguous).
            v_found := false;
            IF v_nid <> '' THEN
                IF p_apply THEN
                    SELECT * INTO v_existing FROM public.customers x WHERE x.organization_id = p_org AND x.national_id = v_nid FOR UPDATE;
                ELSE
                    SELECT * INTO v_existing FROM public.customers x WHERE x.organization_id = p_org AND x.national_id = v_nid;
                END IF;
                v_found := FOUND;
            END IF;
            IF NOT v_found THEN
                v_p1 := app.normalize_customer_phone(v_phones[1]);
                v_name_key := app.search_text(v_name);
                SELECT array_agg(x.id) INTO v_ids FROM public.customers x
                WHERE x.organization_id = p_org AND x.phones @> ARRAY[v_p1]
                  AND app.search_text(regexp_replace(btrim(x.full_name), '[[:space:]]+', ' ', 'g')) = v_name_key;
                IF cardinality(v_ids) > 1 THEN
                    RAISE EXCEPTION 'IMPORT_AMBIGUOUS_MATCH: full_name: % existing customers have this name and phone', cardinality(v_ids);
                ELSIF cardinality(v_ids) = 1 THEN
                    IF p_apply THEN
                        SELECT * INTO v_existing FROM public.customers x WHERE x.id = v_ids[1] FOR UPDATE;
                    ELSE
                        SELECT * INTO v_existing FROM public.customers x WHERE x.id = v_ids[1];
                    END IF;
                    v_found := true;
                    IF v_nid <> '' AND v_existing.national_id IS NOT NULL AND v_existing.national_id <> v_nid THEN
                        RAISE EXCEPTION 'CUSTOMER_NATIONAL_ID_LOCKED: national_id: the customer already has another national ID';
                    END IF;
                END IF;
            END IF;

            IF NOT v_found THEN
                v_new := NULL;
                v_new.is_business := false;
                v_new := app.customer_apply(v_new, c);
                v_action := 'create';
                IF p_apply THEN
                    BEGIN
                        INSERT INTO public.customers (organization_id, full_name, phones, national_id, birth_date, gender,
                            address, city, job, employer, monthly_income, is_business, tax_registration_no, notes,
                            created_by, updated_by)
                        VALUES (p_org, v_new.full_name, v_new.phones, v_new.national_id, v_new.birth_date, v_new.gender,
                            v_new.address, v_new.city, v_new.job, v_new.employer, v_new.monthly_income, v_new.is_business,
                            v_new.tax_registration_no, v_new.notes, p_emp, p_emp);
                    EXCEPTION WHEN unique_violation THEN
                        RAISE EXCEPTION 'CUSTOMER_NATIONAL_ID_TAKEN: national_id: another customer has this national ID';
                    END;
                END IF;
            ELSE
                v_new := app.customer_apply(v_existing, c);
                v_id_changed := v_new.national_id IS DISTINCT FROM v_existing.national_id;
                IF app.customer_fields_json(v_new) = app.customer_fields_json(v_existing) AND NOT v_id_changed THEN
                    v_action := 'unchanged';
                ELSE
                    v_action := 'update';
                    IF p_apply THEN
                        BEGIN
                            UPDATE public.customers SET
                                full_name = v_new.full_name, phones = v_new.phones, national_id = v_new.national_id,
                                birth_date = v_new.birth_date, gender = v_new.gender, address = v_new.address, city = v_new.city,
                                job = v_new.job, employer = v_new.employer, monthly_income = v_new.monthly_income,
                                is_business = v_new.is_business, tax_registration_no = v_new.tax_registration_no,
                                notes = v_new.notes, updated_by = p_emp
                            WHERE id = v_existing.id;
                        EXCEPTION WHEN unique_violation THEN
                            RAISE EXCEPTION 'CUSTOMER_NATIONAL_ID_TAKEN: national_id: another customer has this national ID';
                        END;
                    END IF;
                END IF;
            END IF;

            IF v_action = 'create' THEN v_create := v_create + 1;
            ELSIF v_action = 'update' THEN v_update := v_update + 1;
            ELSE v_same := v_same + 1; END IF;
            IF jsonb_array_length(v_preview) < 20 THEN
                v_show := v;
                IF v_nid <> '' THEN v_show := jsonb_set(v_show, '{national_id}', to_jsonb(app.mask_national_id(v_nid))); END IF;
                v_preview := v_preview || jsonb_build_array(jsonb_build_object('row', r.rn, 'action', v_action, 'values', v_show));
            END IF;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            v_err := v_err + 1;
            IF v_err <= 5000 THEN
                v_errors := v_errors || jsonb_build_array(app.import_error(r.rn, 'customers', v_state, v_msg));
            END IF;
        END;
    END LOOP;
    RETURN jsonb_build_object('errors', v_errors, 'errors_total', v_err,
        'actions', jsonb_build_object('create', v_create, 'update', v_update, 'unchanged', v_same),
        'preview', v_preview, 'will_create_categories', '[]'::jsonb, 'warnings', '[]'::jsonb);
END;
$$;

-- 6. Opening stock -------------------------------------------------------------------------------

-- A product that has only opening stock gets the weighted average of what it holds as its cost
-- (stock x the cost of its latest opening movement per branch; a serialized product: its units'
-- own costs). Once the product has any other movement the cost belongs to purchases: untouched.
CREATE FUNCTION app.import_recost_product(p_org uuid, p_product uuid)
RETURNS void LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE v_serialized boolean; v_qty numeric; v_total numeric;
BEGIN
    IF EXISTS (SELECT 1 FROM public.stock_movements m
               WHERE m.organization_id = p_org AND m.product_id = p_product AND m.type <> 'opening') THEN
        RETURN;
    END IF;
    SELECT p.is_serialized INTO v_serialized FROM public.products p WHERE p.id = p_product AND p.organization_id = p_org;
    IF v_serialized THEN
        SELECT count(*), COALESCE(sum(u.cost), 0) INTO v_qty, v_total FROM public.units u
        WHERE u.organization_id = p_org AND u.product_id = p_product AND u.status IN ('in_stock', 'reserved');
    ELSE
        SELECT COALESCE(sum(sl.on_hand), 0), COALESCE(sum(sl.on_hand * (
            SELECT m.unit_cost FROM public.stock_movements m
            WHERE m.organization_id = p_org AND m.product_id = p_product AND m.branch_id = sl.branch_id
              AND m.type = 'opening' AND m.stock_state = 'sellable'
            ORDER BY m.created_at DESC, m.id DESC LIMIT 1)), 0)
        INTO v_qty, v_total FROM public.stock_levels sl
        WHERE sl.organization_id = p_org AND sl.product_id = p_product AND sl.stock_state = 'sellable' AND sl.on_hand > 0;
    END IF;
    IF v_qty > 0 THEN
        UPDATE public.products SET avg_cost = round(v_total / v_qty, 4) WHERE id = p_product AND organization_id = p_org;
    END IF;
END;
$$;

CREATE FUNCTION app.import_opening_stock(p_org uuid, p_emp uuid, p_rows jsonb, p_apply boolean, p_branch uuid, p_job uuid)
RETURNS jsonb LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
    r record; v jsonb; v_errors jsonb := '[]'::jsonb; v_err integer := 0; v_preview jsonb := '[]'::jsonb;
    v_create integer := 0; v_update integer := 0; v_same integer := 0; v_first_serial jsonb;
    v_sku text; v_bc text; v_p public.products; v_cost numeric; v_qty integer; v_serial text; v_action text;
    v_current integer; v_reserved integer; v_had boolean; v_unit public.units; v_msg text; v_state text;
    v_seen uuid[] := '{}'; v_removed integer; v_warnings jsonb := '[]'::jsonb; v_pid uuid; v_group record;
    v_unit_row record; v_reserved_units integer;
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS pg_temp.m01_plan (
        rn integer, product_id uuid, is_serial boolean, serial text, qty integer, diff integer, cost numeric, action text
    ) ON COMMIT DROP;
    TRUNCATE pg_temp.m01_plan;

    WITH rows AS (SELECT (e ->> 'row')::integer AS rn, e -> 'values' AS vals FROM jsonb_array_elements(p_rows) e)
    SELECT jsonb_object_agg(k, f) INTO v_first_serial
    FROM (SELECT upper(btrim(vals ->> 'serial')) AS k, min(rn) AS f FROM rows
          WHERE NULLIF(btrim(vals ->> 'serial'), '') IS NOT NULL
          GROUP BY 1 HAVING count(*) > 1) x;

    FOR r IN SELECT (e.value ->> 'row')::integer AS rn, e.value -> 'values' AS vals
             FROM jsonb_array_elements(p_rows) WITH ORDINALITY e(value, ord) ORDER BY e.ord
    LOOP
        v_action := NULL;
        BEGIN
            v := r.vals;
            v_sku := upper(NULLIF(btrim(v ->> 'sku'), ''));
            v_bc := NULLIF(btrim(v ->> 'barcode'), '');
            IF v_sku IS NULL AND v_bc IS NULL THEN
                RAISE EXCEPTION 'IMPORT_REQUIRED: sku: a SKU or a barcode is required';
            END IF;
            v_cost := app.import_money('unit_cost', v ->> 'unit_cost');
            IF v_cost IS NULL THEN
                RAISE EXCEPTION 'IMPORT_REQUIRED: unit_cost: the unit cost is required';
            END IF;
            IF v_sku IS NOT NULL THEN
                SELECT * INTO v_p FROM public.products p WHERE p.organization_id = p_org AND p.sku = v_sku;
            ELSE
                SELECT * INTO v_p FROM public.products p WHERE p.organization_id = p_org AND p.barcode = v_bc;
            END IF;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'PRODUCT_NOT_FOUND: %: no product with this code', CASE WHEN v_sku IS NOT NULL THEN 'sku' ELSE 'barcode' END;
            END IF;
            IF v_p.archived_at IS NOT NULL THEN
                RAISE EXCEPTION 'PRODUCT_ARCHIVED: sku: restore the product first';
            END IF;
            v_serial := upper(NULLIF(btrim(v ->> 'serial'), ''));
            v_qty := app.import_int('quantity', v ->> 'quantity', 0, 1000000);

            -- Opening stock only before the product has real movements in this branch.
            IF EXISTS (SELECT 1 FROM public.stock_movements m
                       WHERE m.organization_id = p_org AND m.product_id = v_p.id AND m.branch_id = p_branch
                         AND m.type <> 'opening') THEN
                RAISE EXCEPTION 'OPENING_STOCK_LOCKED: sku: the product already has movements in this branch; use a stock adjustment';
            END IF;

            IF v_p.is_serialized THEN
                IF NOT app.org_has_module(p_org, 'serials') THEN
                    RAISE EXCEPTION 'MODULE_NOT_IN_PLAN: serial: the plan has no serial numbers';
                END IF;
                IF v_serial IS NULL THEN
                    RAISE EXCEPTION 'UNIT_REQUIRED: serial: the product is serialized: one row per serial';
                END IF;
                IF v_serial !~ '^[A-Z0-9][A-Z0-9._/-]{0,63}$' THEN
                    RAISE EXCEPTION 'SERIAL_INVALID: serial: letters, digits and . _ / - only';
                END IF;
                IF v_qty IS NOT NULL AND v_qty <> 1 THEN
                    RAISE EXCEPTION 'IMPORT_INVALID_VALUE: quantity: a serial row is one unit';
                END IF;
                IF v_first_serial ? v_serial AND (v_first_serial ->> v_serial)::integer <> r.rn THEN
                    RAISE EXCEPTION 'IMPORT_DUPLICATE_ROW: serial: same serial as row %', v_first_serial ->> v_serial;
                END IF;
                SELECT * INTO v_unit FROM public.units u WHERE u.organization_id = p_org AND u.serial = v_serial;
                IF NOT FOUND THEN
                    v_action := 'create';
                ELSIF v_unit.product_id = v_p.id AND v_unit.branch_id = p_branch AND v_unit.status IN ('in_stock', 'reserved') THEN
                    v_action := 'unchanged';
                ELSE
                    RAISE EXCEPTION 'SERIAL_TAKEN: serial: the serial is already in the shop';
                END IF;
                INSERT INTO pg_temp.m01_plan VALUES (r.rn, v_p.id, true, v_serial, 1, CASE WHEN v_action = 'create' THEN 1 ELSE 0 END,
                                                      v_cost, CASE WHEN v_action = 'create' THEN 'add' ELSE 'keep' END);
            ELSE
                IF v_serial IS NOT NULL THEN
                    RAISE EXCEPTION 'UNIT_NOT_ALLOWED: serial: the product has no serial numbers';
                END IF;
                IF v_qty IS NULL THEN
                    RAISE EXCEPTION 'IMPORT_REQUIRED: quantity: the quantity is required';
                END IF;
                IF v_p.id = ANY (v_seen) THEN
                    RAISE EXCEPTION 'IMPORT_DUPLICATE_ROW: sku: the product appears twice in the file';
                END IF;
                v_seen := v_seen || v_p.id;
                SELECT COALESCE(sl.on_hand, 0), COALESCE(sl.reserved, 0) INTO v_current, v_reserved
                FROM (SELECT 1) one
                LEFT JOIN public.stock_levels sl ON sl.organization_id = p_org AND sl.product_id = v_p.id
                     AND sl.branch_id = p_branch AND sl.stock_state = 'sellable';
                IF v_qty < v_reserved THEN
                    RAISE EXCEPTION 'OUT_OF_STOCK: quantity: % units are reserved for orders', v_reserved;
                END IF;
                SELECT EXISTS (SELECT 1 FROM public.stock_movements m WHERE m.organization_id = p_org
                               AND m.product_id = v_p.id AND m.branch_id = p_branch) INTO v_had;
                IF v_qty = v_current THEN v_action := 'unchanged';
                ELSIF NOT v_had THEN v_action := 'create';
                ELSE v_action := 'update'; END IF;
                INSERT INTO pg_temp.m01_plan VALUES (r.rn, v_p.id, false, NULL, v_qty, v_qty - v_current, v_cost, 'bulk');
            END IF;

            IF v_action = 'create' THEN v_create := v_create + 1;
            ELSIF v_action = 'update' THEN v_update := v_update + 1;
            ELSE v_same := v_same + 1; END IF;
            IF jsonb_array_length(v_preview) < 20 THEN
                v_preview := v_preview || jsonb_build_array(jsonb_build_object('row', r.rn, 'action', v_action, 'values', v));
            END IF;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            v_err := v_err + 1;
            IF v_err <= 5000 THEN
                v_errors := v_errors || jsonb_build_array(app.import_error(r.rn, 'opening_stock', v_state, v_msg));
            END IF;
        END;
    END LOOP;

    -- Serials a serialized product held as opening stock that the file no longer lists.
    SELECT count(*) FILTER (WHERE u.status = 'in_stock'), count(*) FILTER (WHERE u.status = 'reserved')
    INTO v_removed, v_reserved_units
    FROM public.units u
    WHERE u.organization_id = p_org AND u.branch_id = p_branch AND u.status IN ('in_stock', 'reserved')
      AND u.product_id IN (SELECT pl.product_id FROM pg_temp.m01_plan pl WHERE pl.is_serial)
      AND NOT EXISTS (SELECT 1 FROM pg_temp.m01_plan pl WHERE pl.is_serial AND pl.serial = u.serial);
    IF v_reserved_units > 0 THEN
        v_err := v_err + 1;
        v_errors := v_errors || jsonb_build_array(jsonb_build_object('row',
            (SELECT min(pl.rn) FROM pg_temp.m01_plan pl WHERE pl.is_serial), 'column', 'serial', 'code', 'OUT_OF_STOCK',
            'message', v_reserved_units || ' reserved serial(s) are missing from the file and cannot be taken out'));
    END IF;
    IF v_removed > 0 THEN
        v_warnings := v_warnings || jsonb_build_array(jsonb_build_object('code', 'IMPORT_NOTE', 'column', NULL,
            'message', v_removed || ' serial(s) held as opening stock are not in this file and will be taken out'));
    END IF;

    IF p_apply AND v_err = 0 THEN
        FOR v_pid IN SELECT DISTINCT pl.product_id FROM pg_temp.m01_plan pl ORDER BY pl.product_id LOOP
            -- One bulk movement for the difference.
            INSERT INTO public.stock_movements (organization_id, product_id, branch_id, unit_id, quantity, type, stock_state,
                                                unit_cost, source_type, source_id, created_at, created_by)
            SELECT p_org, pl.product_id, p_branch, NULL, pl.diff, 'opening', 'sellable', pl.cost, 'import', p_job,
                   clock_timestamp(), p_emp
            FROM pg_temp.m01_plan pl WHERE pl.product_id = v_pid AND NOT pl.is_serial AND pl.diff <> 0;
            -- New serials, one batch per cost.
            FOR v_group IN SELECT pl.cost, array_agg(pl.serial ORDER BY pl.serial) AS serials FROM pg_temp.m01_plan pl
                           WHERE pl.product_id = v_pid AND pl.action = 'add' GROUP BY pl.cost ORDER BY pl.cost LOOP
                PERFORM app.create_units(p_org, p_emp, v_pid, p_branch, v_group.serials, v_group.cost, 'opening', 'import', p_job, NULL);
            END LOOP;
            -- Serials taken out.
            FOR v_unit_row IN SELECT u.id, u.cost FROM public.units u
                              WHERE u.organization_id = p_org AND u.product_id = v_pid AND u.branch_id = p_branch
                                AND u.status = 'in_stock'
                                AND EXISTS (SELECT 1 FROM pg_temp.m01_plan pl WHERE pl.product_id = v_pid AND pl.is_serial)
                                AND NOT EXISTS (SELECT 1 FROM pg_temp.m01_plan pl WHERE pl.product_id = v_pid AND pl.serial = u.serial)
                              ORDER BY u.id LOOP
                INSERT INTO public.stock_movements (organization_id, product_id, branch_id, unit_id, quantity, type, stock_state,
                                                    unit_cost, source_type, source_id, created_at, created_by)
                VALUES (p_org, v_pid, p_branch, v_unit_row.id, -1, 'opening', 'sellable', v_unit_row.cost, 'import', p_job,
                        clock_timestamp(), p_emp);
            END LOOP;
            PERFORM app.import_recost_product(p_org, v_pid);
        END LOOP;
    END IF;

    RETURN jsonb_build_object('errors', v_errors, 'errors_total', v_err,
        'actions', jsonb_build_object('create', v_create, 'update', v_update, 'unchanged', v_same),
        'preview', v_preview, 'will_create_categories', '[]'::jsonb, 'warnings', v_warnings);
END;
$$;

-- 7. One entry for the four kinds, and the job's JSON ---------------------------------------------

CREATE FUNCTION app.import_run(p_org uuid, p_emp uuid, p_kind text, p_rows jsonb, p_apply boolean, p_branch uuid, p_job uuid)
RETURNS jsonb LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    RETURN CASE p_kind
        WHEN 'suppliers' THEN app.import_suppliers(p_org, p_emp, p_rows, p_apply)
        WHEN 'products' THEN app.import_products(p_org, p_emp, p_rows, p_apply)
        WHEN 'customers' THEN app.import_customers(p_org, p_emp, p_rows, p_apply)
        WHEN 'opening_stock' THEN app.import_opening_stock(p_org, p_emp, p_rows, p_apply, p_branch, p_job)
    END;
END;
$$;

-- The rows of a call: an array of 1-5000 { row, values } with distinct row numbers, the values only
-- text and only the kind's field keys.
CREATE FUNCTION app.import_check_rows(p_kind text, p_rows jsonb)
RETURNS void LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
BEGIN
    IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) = 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: rows';
    END IF;
    IF jsonb_array_length(p_rows) > 5000 THEN
        RAISE EXCEPTION 'IMPORT_TOO_MANY_ROWS: at most 5000 rows';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_rows) e
               WHERE jsonb_typeof(e) <> 'object' OR jsonb_typeof(e -> 'row') IS DISTINCT FROM 'number'
                  OR jsonb_typeof(e -> 'values') IS DISTINCT FROM 'object'
                  OR (e ->> 'row') !~ '^[1-9][0-9]{0,8}$') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: rows';
    END IF;
    IF (SELECT count(DISTINCT e ->> 'row') FROM jsonb_array_elements(p_rows) e) <> jsonb_array_length(p_rows) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: rows';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_rows) e, jsonb_each(e -> 'values') kv
               WHERE jsonb_typeof(kv.value) <> 'string' OR kv.key <> ALL (app.import_kind_columns(p_kind))) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: rows';
    END IF;
END;
$$;

-- A job as the API returns it. The idempotency and run keys stay inside the table.
CREATE FUNCTION app.import_job_json(j public.import_jobs)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', j.id, 'kind', j.kind, 'status', j.status, 'file_id', j.file_id,
        'file_name', (SELECT f.original_name FROM public.files f WHERE f.id = j.file_id AND f.organization_id = j.organization_id),
        'result_file_id', j.result_file_id,
        'branch_id', NULLIF(j.report ->> 'branch_id', '')::uuid,
        'rows_total', j.rows_total, 'rows_ok', j.rows_ok, 'rows_failed', j.rows_failed,
        'created_at', j.created_at, 'finished_at', j.finished_at,
        'created_by', (SELECT jsonb_build_object('id', e.id, 'name', e.full_name) FROM public.employees e
                       WHERE e.id = j.created_by AND e.organization_id = j.organization_id),
        'report', j.report - 'idempotency_key' - 'run_key')
$$;

CREATE FUNCTION app.import_job_summary_json(j public.import_jobs)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT (app.import_job_json(j) - 'report') || jsonb_build_object(
        'actions', COALESCE(j.report -> 'applied', j.report -> 'actions'),
        'errors_total', COALESCE((j.report ->> 'errors_total')::integer, 0))
$$;

-- The report of a run: columns, warnings, errors and counts in the contract's shape.
CREATE FUNCTION app.import_report(p_res jsonb, p_meta jsonb, p_branch uuid)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'columns', jsonb_build_object('mapping', COALESCE(p_meta -> 'mapping', '{}'::jsonb),
                                      'unmapped_headers', COALESCE(p_meta -> 'unmapped_headers', '[]'::jsonb)),
        'sheet', p_meta -> 'sheet',
        'branch_id', p_branch,
        'warnings', COALESCE((SELECT jsonb_agg(jsonb_build_object('code', 'IMPORT_UNKNOWN_COLUMN', 'column', h,
                                      'message', 'This column is not used and was ignored'))
                              FROM jsonb_array_elements_text(COALESCE(p_meta -> 'unmapped_headers', '[]'::jsonb)) h), '[]'::jsonb)
                    || COALESCE(p_res -> 'warnings', '[]'::jsonb),
        'errors', p_res -> 'errors',
        'errors_total', (p_res ->> 'errors_total')::integer,
        'errors_truncated', (p_res ->> 'errors_total')::integer > 5000,
        'actions', p_res -> 'actions',
        'preview', p_res -> 'preview',
        'will_create_categories', COALESCE(p_res -> 'will_create_categories', '[]'::jsonb),
        'applied', NULL, 'failure', NULL)
$$;

REVOKE ALL ON FUNCTION app.employee_has_permission(uuid, text), app.employee_has_branch(uuid, uuid),
    app.import_required_keys(text), app.import_kind_columns(text), app.import_row_codes(),
    app.import_money(text, text), app.import_int(text, text, integer, integer), app.import_bool(text, text),
    app.import_date(text, text), app.import_gender(text, text), app.import_phone_list(text),
    app.import_national_id(text), app.import_customer_key(jsonb), app.import_supplier_phone(text),
    app.import_error(integer, text, text, text), app.import_category(uuid, uuid, text[], boolean, text[]),
    app.import_suppliers(uuid, uuid, jsonb, boolean), app.import_products(uuid, uuid, jsonb, boolean),
    app.import_customers(uuid, uuid, jsonb, boolean), app.import_recost_product(uuid, uuid),
    app.import_opening_stock(uuid, uuid, jsonb, boolean, uuid, uuid),
    app.import_run(uuid, uuid, text, jsonb, boolean, uuid, uuid), app.import_check_rows(text, jsonb),
    app.import_job_json(public.import_jobs), app.import_job_summary_json(public.import_jobs),
    app.import_report(jsonb, jsonb, uuid)
    FROM PUBLIC, anon, authenticated;

-- 8. The dry run ----------------------------------------------------------------------------------

-- import.data. Checks every row and stores the job with its report; nothing else is saved. The same
-- key again returns the same job. A job with no errors is 'validated' and can be run; one with any
-- error is 'failed'.
CREATE FUNCTION public.create_import(p_kind text, p_file_id uuid, p_branch_id uuid, p_rows jsonb, p_meta jsonb,
                                     p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_key text; v_job public.import_jobs; v_res jsonb; v_report jsonb; v_status public.import_status;
    v_failed integer; v_total integer; v_meta jsonb := COALESCE(p_meta, '{}'::jsonb);
BEGIN
    v_emp := app.require_permission('import.data');
    v_org := app.current_org_id();
    IF p_kind IS NULL OR p_kind NOT IN ('products', 'customers', 'suppliers', 'opening_stock') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: kind';
    END IF;
    FOREACH v_key IN ARRAY app.import_required_keys(p_kind) LOOP
        PERFORM app.require_permission(v_key);
    END LOOP;
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_job FROM public.import_jobs j
    WHERE j.organization_id = v_org AND j.report ->> 'idempotency_key' = p_idempotency_key;
    IF FOUND THEN
        RETURN app.import_job_json(v_job);                  -- a repeat changes nothing
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.files f WHERE f.id = p_file_id AND f.organization_id = v_org AND f.purpose = 'import') THEN
        RAISE EXCEPTION 'FILE_NOT_FOUND';
    END IF;
    IF p_kind = 'customers' THEN
        PERFORM app.require_module('customers');
    END IF;
    IF p_kind = 'opening_stock' THEN
        IF p_branch_id IS NULL THEN RAISE EXCEPTION 'VALIDATION_FAILED: branch_id'; END IF;
        IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
            RAISE EXCEPTION 'BRANCH_NOT_FOUND';
        END IF;
        PERFORM app.require_branch_access(p_branch_id);
    ELSIF p_branch_id IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: branch_id';
    END IF;
    IF jsonb_typeof(v_meta) <> 'object'
       OR (v_meta ? 'mapping' AND jsonb_typeof(v_meta -> 'mapping') <> 'object')
       OR (v_meta ? 'unmapped_headers' AND jsonb_typeof(v_meta -> 'unmapped_headers') <> 'array')
       OR (v_meta ? 'sheet' AND jsonb_typeof(v_meta -> 'sheet') NOT IN ('string', 'null')) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: meta';
    END IF;
    PERFORM app.import_check_rows(p_kind, p_rows);

    v_res := app.import_run(v_org, v_emp, p_kind, p_rows, false, p_branch_id, NULL);
    v_report := app.import_report(v_res, v_meta, p_branch_id)
                || jsonb_build_object('idempotency_key', p_idempotency_key);
    v_total := jsonb_array_length(p_rows);
    SELECT count(DISTINCT e ->> 'row') INTO v_failed FROM jsonb_array_elements(v_res -> 'errors') e;
    v_status := CASE WHEN (v_res ->> 'errors_total')::integer = 0 THEN 'validated' ELSE 'failed' END;
    INSERT INTO public.import_jobs (organization_id, kind, status, file_id, dry_run, rows_total, rows_ok, rows_failed,
                                    report, created_by)
    VALUES (v_org, p_kind::public.import_kind, v_status, p_file_id, true, v_total, v_total - v_failed, v_failed,
            v_report, v_emp)
    RETURNING * INTO v_job;

    PERFORM app.write_audit('import.validated', 'import_job', v_job.id, NULL,
        jsonb_build_object('kind', p_kind, 'file_id', p_file_id, 'rows', v_total, 'errors', v_res -> 'errors_total',
                           'actions', v_res -> 'actions'), NULL, p_branch_id);
    RETURN app.import_job_json(v_job);
END;
$$;

-- 9. Reads: import.data or export.data (RLS's rule), also in an expired shop ----------------------

CREATE FUNCTION public.get_import_job(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_job public.import_jobs;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT (app.has_permission('import.data') OR app.has_permission('export.data')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: import.data' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO v_job FROM public.import_jobs j
    WHERE j.id = p_id AND j.organization_id = app.current_org_id() AND j.report ? 'columns';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND';
    END IF;
    RETURN app.import_job_json(v_job);
END;
$$;

-- p_filters: kind, status, limit (1-100, default 25), cursor. Newest first.
CREATE FUNCTION public.list_import_jobs(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; v_f jsonb := COALESCE(p_filters, '{}'::jsonb); v_key text; v_limit integer := 25;
    v_kind text; v_status text; v_cursor text; v_at timestamptz; v_id uuid; v_ids uuid[]; v_next text;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT (app.has_permission('import.data') OR app.has_permission('export.data')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: import.data' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    IF jsonb_typeof(v_f) <> 'object' THEN RAISE EXCEPTION 'VALIDATION_FAILED: filters'; END IF;
    SELECT k INTO v_key FROM jsonb_object_keys(v_f) k WHERE k <> ALL (ARRAY['kind', 'status', 'limit', 'cursor']) LIMIT 1;
    IF v_key IS NOT NULL THEN RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key; END IF;
    IF v_f ? 'limit' THEN
        IF jsonb_typeof(v_f -> 'limit') <> 'number' OR (v_f ->> 'limit')::numeric <> trunc((v_f ->> 'limit')::numeric)
           OR (v_f ->> 'limit')::numeric NOT BETWEEN 1 AND 100 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: limit';
        END IF;
        v_limit := (v_f ->> 'limit')::integer;
    END IF;
    v_kind := v_f ->> 'kind'; v_status := v_f ->> 'status'; v_cursor := v_f ->> 'cursor';
    IF v_kind IS NOT NULL AND v_kind NOT IN ('products', 'customers', 'suppliers', 'opening_stock') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: kind';
    END IF;
    IF v_status IS NOT NULL AND v_status NOT IN ('uploaded', 'validating', 'validated', 'importing', 'completed', 'failed', 'cancelled') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: status';
    END IF;
    IF v_cursor IS NOT NULL THEN
        IF v_cursor !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z\|[0-9a-f-]{36}$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: cursor';
        END IF;
        v_at := split_part(v_cursor, '|', 1)::timestamptz;
        v_id := split_part(v_cursor, '|', 2)::uuid;
    END IF;

    SELECT array_agg(s.id ORDER BY s.created_at DESC, s.id DESC) INTO v_ids FROM (
        SELECT j.id, j.created_at FROM public.import_jobs j
        WHERE j.organization_id = v_org AND j.report ? 'columns'
          AND (v_kind IS NULL OR j.kind::text = v_kind)
          AND (v_status IS NULL OR j.status::text = v_status)
          AND (v_cursor IS NULL OR (j.created_at, j.id) < (v_at, v_id))
        ORDER BY j.created_at DESC, j.id DESC
        LIMIT v_limit + 1) s;
    IF COALESCE(cardinality(v_ids), 0) > v_limit THEN
        SELECT to_char(j.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || '|' || j.id INTO v_next
        FROM public.import_jobs j WHERE j.id = v_ids[v_limit];
    END IF;
    RETURN jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(app.import_job_summary_json(j) ORDER BY u.ord)
                           FROM unnest(v_ids) WITH ORDINALITY u(jid, ord)
                           JOIN public.import_jobs j ON j.id = u.jid WHERE u.ord <= v_limit), '[]'::jsonb),
        'next_cursor', v_next);
END;
$$;

-- 10. Run and cancel ------------------------------------------------------------------------------

-- import.data. validated -> importing; the work itself is the background job 'import.apply'.
CREATE FUNCTION public.queue_import(p_id uuid, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_job public.import_jobs; v_key text;
BEGIN
    v_emp := app.require_permission('import.data');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_job FROM public.import_jobs j WHERE j.id = p_id AND j.organization_id = v_org AND j.report ? 'columns' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND';
    END IF;
    FOREACH v_key IN ARRAY app.import_required_keys(v_job.kind::text) LOOP
        PERFORM app.require_permission(v_key);
    END LOOP;
    IF v_job.status = 'importing' AND v_job.report ->> 'run_key' = p_idempotency_key THEN
        RETURN app.import_job_json(v_job);                  -- a repeat changes nothing
    END IF;
    IF v_job.status <> 'validated' THEN
        RAISE EXCEPTION 'IMPORT_NOT_VALIDATED: the job is %', v_job.status USING
            DETAIL = jsonb_build_object('status', v_job.status)::text;
    END IF;
    UPDATE public.import_jobs SET status = 'importing', dry_run = false,
           report = report || jsonb_build_object('run_key', p_idempotency_key)
    WHERE id = p_id RETURNING * INTO v_job;
    INSERT INTO public.jobs (organization_id, job_type, payload, dedupe_key, max_attempts)
    VALUES (v_org, 'import.apply', jsonb_build_object('import_job_id', p_id), p_id::text, 3);
    PERFORM app.write_audit('import.started', 'import_job', p_id, NULL,
        jsonb_build_object('kind', v_job.kind, 'rows', v_job.rows_total), NULL, NULLIF(v_job.report ->> 'branch_id', '')::uuid);
    RETURN app.import_job_json(v_job);
END;
$$;

-- import.data. A job that has not started importing, or has ended without success, can be cancelled.
CREATE FUNCTION public.cancel_import_job(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_job public.import_jobs;
BEGIN
    v_emp := app.require_permission('import.data');
    SELECT * INTO v_job FROM public.import_jobs j
    WHERE j.id = p_id AND j.organization_id = app.current_org_id() AND j.report ? 'columns' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND';
    END IF;
    IF v_job.status NOT IN ('uploaded', 'validated', 'failed') THEN
        RAISE EXCEPTION 'IMPORT_NOT_VALIDATED: the job is %', v_job.status USING
            DETAIL = jsonb_build_object('status', v_job.status)::text;
    END IF;
    UPDATE public.import_jobs SET status = 'cancelled', finished_at = now() WHERE id = p_id RETURNING * INTO v_job;
    PERFORM app.write_audit('import.cancelled', 'import_job', p_id, NULL,
        jsonb_build_object('kind', v_job.kind, 'rows', v_job.rows_total), NULL, NULLIF(v_job.report ->> 'branch_id', '')::uuid);
    RETURN app.import_job_json(v_job);
END;
$$;

-- 11. The error file: a CSV of the report's errors, linked to the job -----------------------------

CREATE FUNCTION app.import_attach_result(p_org uuid, p_emp uuid, p_job_id uuid, p_file_id uuid, p_path text,
                                         p_original_name text, p_mime text, p_size_bytes bigint, p_sha256 text)
RETURNS jsonb LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE v_job public.import_jobs;
BEGIN
    SELECT * INTO v_job FROM public.import_jobs j WHERE j.id = p_job_id AND j.organization_id = p_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND';
    END IF;
    IF v_job.status NOT IN ('validated', 'failed') THEN
        RAISE EXCEPTION 'IMPORT_NOT_VALIDATED: the job is %', v_job.status USING
            DETAIL = jsonb_build_object('status', v_job.status)::text;
    END IF;
    IF p_file_id IS NULL OR p_path IS NULL OR p_mime IS NULL OR p_size_bytes IS NULL OR p_size_bytes < 0
       OR left(p_path, length(p_org::text) + 1) <> p_org::text || '/' OR p_path ~ '\\' OR p_path ~ '(^|/)\.{1,2}(/|$)' THEN
        RAISE EXCEPTION 'FILE_PATH_INVALID: the path must start with the shop id';
    END IF;
    INSERT INTO public.files (id, organization_id, bucket, path, original_name, mime, size_bytes, sha256, purpose,
                              entity_type, entity_id, created_by)
    VALUES (p_file_id, p_org, 'tenant-files', p_path, p_original_name, p_mime, p_size_bytes, p_sha256, 'export',
            NULL, NULL, p_emp);
    UPDATE public.import_jobs SET result_file_id = p_file_id WHERE id = p_job_id RETURNING * INTO v_job;
    RETURN app.import_job_json(v_job);
END;
$$;

CREATE FUNCTION public.attach_import_result(p_job_id uuid, p_file_id uuid, p_path text, p_original_name text,
                                            p_mime text, p_size_bytes bigint, p_sha256 text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid := app.require_permission('import.data');
BEGIN
    RETURN app.import_attach_result(app.current_org_id(), v_emp, p_job_id, p_file_id, p_path, p_original_name,
                                    p_mime, p_size_bytes, p_sha256);
END;
$$;

REVOKE ALL ON FUNCTION app.import_attach_result(uuid, uuid, uuid, uuid, text, text, text, bigint, text)
    FROM PUBLIC, anon, authenticated;

-- 12. The background job (service role) -------------------------------------------------------------

-- What the worker needs to read the file again: the kind, the branch, the sheet and mapping used by
-- the dry run, the stored file. Only for a job that is importing.
CREATE FUNCTION public.jobs_import_prepare(p_job_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_job public.import_jobs; v_file public.files;
BEGIN
    SELECT * INTO v_job FROM public.import_jobs j WHERE j.id = p_job_id AND j.report ? 'columns';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND';
    END IF;
    SELECT * INTO v_file FROM public.files f WHERE f.id = v_job.file_id AND f.organization_id = v_job.organization_id;
    RETURN jsonb_build_object('organization_id', v_job.organization_id, 'kind', v_job.kind, 'status', v_job.status,
        'branch_id', NULLIF(v_job.report ->> 'branch_id', '')::uuid, 'rows_total', v_job.rows_total,
        'sheet', v_job.report ->> 'sheet', 'mapping', v_job.report #> '{columns,mapping}',
        'file_path', v_file.path, 'file_sha256', v_file.sha256);
END;
$$;

-- The import: one transaction. The checks run again first (data may have changed since the dry run);
-- any error at all, or any failure while writing, undoes every row and ends the job as 'failed' with
-- the new errors in its report. Nothing is saved in part. A job that is not 'importing' (already done,
-- failed or cancelled) is left alone, so a retried queue entry does nothing.
CREATE FUNCTION public.jobs_import_apply(p_job_id uuid, p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' SET statement_timeout = '900s'
AS $$
DECLARE
    v_job public.import_jobs; v_org uuid; v_emp uuid; v_res jsonb; v_ok boolean := false; v_failure text;
    v_state text; v_msg text; v_key text; v_branch uuid; v_failed integer; v_actions jsonb; v_errors jsonb;
BEGIN
    SELECT * INTO v_job FROM public.import_jobs j WHERE j.id = p_job_id AND j.report ? 'columns' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND';
    END IF;
    IF v_job.status <> 'importing' THEN
        RETURN jsonb_build_object('status', v_job.status, 'changed', false);
    END IF;
    v_org := v_job.organization_id; v_emp := v_job.created_by;
    v_branch := NULLIF(v_job.report ->> 'branch_id', '')::uuid;

    BEGIN
        IF v_emp IS NULL OR NOT EXISTS (SELECT 1 FROM public.organizations o WHERE o.id = v_org AND o.status = 'active')
           OR app.org_is_expired(v_org) THEN
            RAISE EXCEPTION 'IMPORT_APPLY_FAILED: the shop cannot write now';
        END IF;
        FOREACH v_key IN ARRAY app.import_required_keys(v_job.kind::text) LOOP
            IF NOT app.employee_has_permission(v_emp, v_key) THEN
                RAISE EXCEPTION 'IMPORT_APPLY_FAILED: the employee no longer holds %', v_key;
            END IF;
        END LOOP;
        IF v_job.kind = 'customers' AND NOT app.org_has_module(v_org, 'customers') THEN
            RAISE EXCEPTION 'MODULE_NOT_IN_PLAN: customers';
        END IF;
        IF v_job.kind = 'opening_stock' AND (v_branch IS NULL OR NOT app.employee_has_branch(v_emp, v_branch)) THEN
            RAISE EXCEPTION 'IMPORT_APPLY_FAILED: the branch is not available to the employee';
        END IF;
        PERFORM app.import_check_rows(v_job.kind::text, p_rows);
        IF jsonb_array_length(p_rows) <> v_job.rows_total THEN
            RAISE EXCEPTION 'IMPORT_APPLY_FAILED: the file no longer has the rows that were checked';
        END IF;
        v_res := app.import_run(v_org, v_emp, v_job.kind::text, p_rows, true, v_branch, v_job.id);
        IF (v_res ->> 'errors_total')::integer > 0 THEN
            RAISE EXCEPTION 'IMPORT_ROLLBACK';
        END IF;
        v_ok := true;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
        IF v_msg <> 'IMPORT_ROLLBACK' THEN
            v_failure := (app.import_error(1, v_job.kind::text, v_state, v_msg)) ->> 'message';
            v_res := NULL;
        END IF;
    END;

    IF v_ok THEN
        UPDATE public.import_jobs SET status = 'completed', rows_ok = rows_total, rows_failed = 0, finished_at = now(),
               report = report || jsonb_build_object(
                   'actions', v_res -> 'actions', 'applied', v_res -> 'actions',
                   'will_create_categories', COALESCE(v_res -> 'will_create_categories', '[]'::jsonb),
                   'errors', '[]'::jsonb, 'errors_total', 0, 'errors_truncated', false, 'failure', NULL)
        WHERE id = p_job_id RETURNING * INTO v_job;
        INSERT INTO public.audit_log (organization_id, branch_id, employee_id, action, entity_type, entity_id, severity, after)
        VALUES (v_org, v_branch, v_emp, 'import.completed', 'import_job', p_job_id, 'info',
                jsonb_build_object('kind', v_job.kind, 'file_id', v_job.file_id, 'rows', v_job.rows_total,
                                   'created', v_res #>> '{actions,create}', 'updated', v_res #>> '{actions,update}',
                                   'unchanged', v_res #>> '{actions,unchanged}'));
    ELSE
        v_errors := COALESCE(v_res -> 'errors', '[]'::jsonb);
        SELECT count(DISTINCT e ->> 'row') INTO v_failed FROM jsonb_array_elements(v_errors) e;
        UPDATE public.import_jobs SET status = 'failed', rows_failed = CASE WHEN v_res IS NULL THEN rows_total ELSE v_failed END,
               rows_ok = CASE WHEN v_res IS NULL THEN 0 ELSE rows_total - v_failed END, finished_at = now(),
               report = report || jsonb_build_object(
                   'errors', v_errors, 'errors_total', COALESCE((v_res ->> 'errors_total')::integer, 0),
                   'errors_truncated', COALESCE((v_res ->> 'errors_total')::integer, 0) > 5000,
                   'applied', NULL, 'failure', COALESCE(v_failure, 'The checks found errors; nothing was imported.'))
        WHERE id = p_job_id RETURNING * INTO v_job;
        INSERT INTO public.audit_log (organization_id, branch_id, employee_id, action, entity_type, entity_id, severity, after)
        VALUES (v_org, v_branch, v_emp, 'import.failed', 'import_job', p_job_id, 'warning',
                jsonb_build_object('kind', v_job.kind, 'file_id', v_job.file_id, 'rows', v_job.rows_total,
                                   'errors', v_job.report -> 'errors_total'));
    END IF;
    RETURN jsonb_build_object('status', v_job.status, 'changed', true, 'errors', CASE WHEN v_ok THEN '[]'::jsonb ELSE v_errors END);
END;
$$;

-- The worker gave up (every attempt failed outside the database, e.g. the file could not be read).
CREATE FUNCTION public.jobs_import_fail(p_job_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_job public.import_jobs;
BEGIN
    SELECT * INTO v_job FROM public.import_jobs j WHERE j.id = p_job_id AND j.report ? 'columns' FOR UPDATE;
    IF NOT FOUND OR v_job.status <> 'importing' THEN
        RETURN jsonb_build_object('status', v_job.status, 'changed', false);
    END IF;
    UPDATE public.import_jobs SET status = 'failed', rows_failed = rows_total, rows_ok = 0, finished_at = now(),
           report = report || jsonb_build_object('applied', NULL, 'failure', left(COALESCE(p_reason, 'The import could not run.'), 300))
    WHERE id = p_job_id RETURNING * INTO v_job;
    INSERT INTO public.audit_log (organization_id, branch_id, employee_id, action, entity_type, entity_id, severity, after)
    VALUES (v_job.organization_id, NULLIF(v_job.report ->> 'branch_id', '')::uuid, v_job.created_by, 'import.failed',
            'import_job', p_job_id, 'warning', jsonb_build_object('kind', v_job.kind, 'file_id', v_job.file_id, 'rows', v_job.rows_total));
    RETURN jsonb_build_object('status', v_job.status, 'changed', true);
END;
$$;

CREATE FUNCTION public.jobs_import_attach_result(p_job_id uuid, p_file_id uuid, p_path text, p_original_name text,
                                                 p_mime text, p_size_bytes bigint, p_sha256 text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_job public.import_jobs;
BEGIN
    SELECT * INTO v_job FROM public.import_jobs j WHERE j.id = p_job_id AND j.report ? 'columns';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND';
    END IF;
    RETURN app.import_attach_result(v_job.organization_id, v_job.created_by, p_job_id, p_file_id, p_path,
                                    p_original_name, p_mime, p_size_bytes, p_sha256);
END;
$$;

-- 13. Grants ----------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.create_import(text, uuid, uuid, jsonb, jsonb, text), public.get_import_job(uuid),
    public.list_import_jobs(jsonb), public.queue_import(uuid, text), public.cancel_import_job(uuid),
    public.attach_import_result(uuid, uuid, text, text, text, bigint, text),
    public.jobs_import_prepare(uuid), public.jobs_import_apply(uuid, jsonb), public.jobs_import_fail(uuid, text),
    public.jobs_import_attach_result(uuid, uuid, text, text, text, bigint, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_import(text, uuid, uuid, jsonb, jsonb, text), public.get_import_job(uuid),
    public.list_import_jobs(jsonb), public.queue_import(uuid, text), public.cancel_import_job(uuid),
    public.attach_import_result(uuid, uuid, text, text, text, bigint, text)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.jobs_import_prepare(uuid), public.jobs_import_apply(uuid, jsonb),
    public.jobs_import_fail(uuid, text), public.jobs_import_attach_result(uuid, uuid, text, text, text, bigint, text)
    TO service_role;
