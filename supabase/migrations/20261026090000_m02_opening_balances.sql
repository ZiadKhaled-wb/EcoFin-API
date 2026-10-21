-- =============================================================================
-- M02 · Opening balances: open installment contracts and opening cash (EC-101, D85)
--
-- A shop that already sells on installments brings its open debts and its opening cash through
-- M01's pipeline (D83): two new import kinds in the same screen, dry run and all-or-nothing job.
--
--   opening_contracts   one row per remaining installment; the contract columns repeat on every row
--                       of a contract (grouped by contract_ref). A migrated contract stores ONLY
--                       what is left (financed = remaining principal, markup = remaining profit,
--                       down payment 0), is_migrated = true, with its batch and migration_source.
--                       Nothing is posted to the cash, stock or sale ledgers: the money was received
--                       and the goods left long ago. No fee is ever added (Islamic finance rule 4).
--   opening_cash        one row per safe / bank: the account is found or created and its balance is
--                       posted as ONE 'opening' movement through the import job (K01's rule).
--
--   public.get_migration_report      the reconciliation report (per customer, branch, batch, cash)
--   public.sign_off_migration        the owner signs the report against the old records' total;
--                                    ANY difference -> MIGRATION_TOTAL_MISMATCH and nothing stored
--   public.list_migration_signoffs
--   public.reverse_migration_batch   undo a wrong batch before collections and sign-off: every
--                                    contract is closed through N05's write-off record
--
-- This migration RECREATES (CREATE OR REPLACE, bodies copied from 20261024090000_m01_import.sql
-- with the two kinds added): app.import_required_keys, app.import_kind_columns,
-- app.import_row_codes, app.import_error, app.import_report, app.import_run, public.create_import,
-- public.list_import_jobs, public.jobs_import_apply, N02's app.contract_json and R02's
-- app.customer_contract_json (both add migration_source). Contracts are frozen rows; the trigger now also lets migration_source change
-- (only reverse_migration_batch writes it, to mark a contract reversed).
-- Numbered after the newest migration on main (D39): K04 is 20261025090000.
-- =============================================================================

-- 1. Schema -----------------------------------------------------------------------------------------

ALTER TABLE public.contracts ADD COLUMN migration_source jsonb;
ALTER TABLE public.contracts ADD CONSTRAINT contracts_migration_source_check
    CHECK (migration_source IS NULL OR (is_migrated AND jsonb_typeof(migration_source) = 'object'));

-- The old system's contract number is unique per shop among the migrated contracts that were not
-- reversed (a corrected file can be imported again after its batch was reversed).
CREATE UNIQUE INDEX contracts_migration_ref_idx
    ON public.contracts (organization_id, upper(migration_source ->> 'contract_ref'))
    WHERE is_migrated AND migration_source IS NOT NULL
      AND (migration_source ->> 'reversed') IS DISTINCT FROM 'true';
CREATE INDEX contracts_migration_batch_idx ON public.contracts (organization_id, migration_batch_id)
    WHERE migration_batch_id IS NOT NULL;

DROP TRIGGER trg_contracts_frozen ON public.contracts;
CREATE TRIGGER trg_contracts_frozen BEFORE UPDATE ON public.contracts
    FOR EACH ROW EXECUTE FUNCTION app.only_columns_change(
        'status', 'current_version', 'closed_at', 'updated_at', 'updated_by', 'migration_source');

-- One row per signed reconciliation. Append-only; read through the functions only.
CREATE TABLE public.migration_signoffs (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid NOT NULL REFERENCES public.organizations (id),
    batch_ids           uuid[] NOT NULL,
    expected_open_total numeric(18,2) NOT NULL CHECK (expected_open_total >= 0),
    system_open_total   numeric(18,2) NOT NULL CHECK (system_open_total >= 0),
    expected_cash_total numeric(18,2) CHECK (expected_cash_total >= 0),
    system_cash_total   numeric(18,2) NOT NULL CHECK (system_cash_total >= 0),
    note                text NOT NULL CHECK (length(note) BETWEEN 3 AND 500),
    signed_file_id      uuid,
    signed_by           uuid NOT NULL,
    signed_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT migration_signoffs_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (signed_file_id, organization_id) REFERENCES public.files (id, organization_id),
    FOREIGN KEY (signed_by, organization_id) REFERENCES public.employees (id, organization_id),
    CHECK (cardinality(batch_ids) BETWEEN 1 AND 50),
    CHECK (expected_open_total = system_open_total),
    CHECK (expected_cash_total IS NULL OR expected_cash_total = system_cash_total)
);
CREATE INDEX migration_signoffs_batches_idx ON public.migration_signoffs USING gin (batch_ids);
CREATE TRIGGER trg_migration_signoffs_append_only BEFORE UPDATE OR DELETE ON public.migration_signoffs
    FOR EACH ROW EXECUTE FUNCTION app.forbid_update_delete();
ALTER TABLE public.migration_signoffs ENABLE ROW LEVEL SECURITY;
CREATE POLICY migration_signoffs_read ON public.migration_signoffs
    FOR SELECT TO authenticated
    USING (organization_id = (SELECT app.current_org_id())
           AND ((SELECT app.has_permission('import.data')) OR (SELECT app.has_permission('report.financial'))));
REVOKE ALL ON public.migration_signoffs FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.migration_signoffs TO service_role;

-- 2. The kind tables (M01's, with the two kinds) -----------------------------------------------------

CREATE OR REPLACE FUNCTION app.import_required_keys(p_kind text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT CASE p_kind
        WHEN 'products' THEN ARRAY['import.data', 'catalog.manage', 'catalog.price_change']
        WHEN 'customers' THEN ARRAY['import.data', 'customer.create', 'customer.edit']
        WHEN 'suppliers' THEN ARRAY['import.data', 'supplier.manage']
        WHEN 'opening_stock' THEN ARRAY['import.data', 'stock.adjust']
        WHEN 'opening_contracts' THEN ARRAY['import.data', 'installment.create', 'customer.create']
        WHEN 'opening_cash' THEN ARRAY['import.data', 'cash.adjust', 'cash.account_manage']
    END
$$;

CREATE OR REPLACE FUNCTION app.import_kind_columns(p_kind text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT CASE p_kind
        WHEN 'suppliers' THEN ARRAY['name', 'phone', 'tax_registration_no', 'address', 'payment_terms_days', 'notes']
        WHEN 'products' THEN ARRAY['sku', 'name_ar', 'name_en', 'cash_price', 'barcode', 'category', 'unit_of_measure',
            'installment_price', 'tax_class', 'warranty_months', 'is_serialized', 'min_stock', 'eta_item_code', 'eta_item_type']
        WHEN 'customers' THEN ARRAY['full_name', 'phones', 'national_id', 'birth_date', 'gender', 'address', 'city', 'job',
            'employer', 'monthly_income', 'is_business', 'tax_registration_no', 'notes']
        WHEN 'opening_stock' THEN ARRAY['sku', 'barcode', 'quantity', 'serial', 'unit_cost']
        WHEN 'opening_contracts' THEN ARRAY['contract_ref', 'customer_national_id', 'customer_phone', 'branch_code',
            'contract_date', 'original_total', 'paid_before', 'frequency', 'remaining_principal', 'remaining_profit',
            'notes', 'due_date', 'amount',
            'guarantor1_national_id', 'guarantor1_name', 'guarantor1_phone', 'guarantor1_address', 'guarantor1_relation',
            'guarantor2_national_id', 'guarantor2_name', 'guarantor2_phone', 'guarantor2_address', 'guarantor2_relation']
        WHEN 'opening_cash' THEN ARRAY['branch_code', 'account_name', 'kind', 'bank_shop_wide', 'balance']
    END
$$;

CREATE OR REPLACE FUNCTION app.import_row_codes()
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT ARRAY['IMPORT_REQUIRED', 'IMPORT_INVALID_VALUE', 'IMPORT_DUPLICATE_ROW', 'IMPORT_AMBIGUOUS_MATCH',
        'IMPORT_APPLY_FAILED', 'PRODUCT_ARCHIVED', 'PRODUCT_NOT_FOUND', 'PRODUCT_SKU_TAKEN', 'PRODUCT_BARCODE_TAKEN',
        'PRODUCT_SERIAL_LOCKED', 'PRODUCT_CATEGORY_ARCHIVED', 'CATEGORY_DEPTH', 'CATEGORY_NAME_TAKEN',
        'CUSTOMER_NATIONAL_ID_TAKEN', 'CUSTOMER_NATIONAL_ID_LOCKED', 'NATIONAL_ID_INVALID', 'SUPPLIER_PHONE_TAKEN',
        'SUPPLIER_NAME_TAKEN', 'SERIAL_INVALID', 'SERIAL_TAKEN', 'UNIT_NOT_ALLOWED', 'UNIT_REQUIRED',
        'OPENING_STOCK_LOCKED', 'TAX_CLASS_NOT_FOUND', 'MODULE_NOT_IN_PLAN', 'OUT_OF_STOCK',
        -- M02
        'IMPORT_CONTRACT_ROWS_DIFFER', 'IMPORT_CONTRACT_NOT_BALANCED', 'IMPORT_CONTRACT_EXISTS',
        'IMPORT_CUSTOMER_NOT_FOUND', 'IMPORT_GUARANTOR_INCOMPLETE', 'IMPORT_ACCOUNT_KIND',
        'CASH_ACCOUNT_HAS_MOVEMENTS', 'CASH_ACCOUNT_INACTIVE', 'CASH_ACCOUNT_NAME_TAKEN', 'DAY_CLOSED',
        'POLICY_NOT_SET']
$$;

-- M01's row error reader; the column pattern now allows digits (guarantor1_phone).
CREATE OR REPLACE FUNCTION app.import_error(p_row integer, p_kind text, p_state text, p_msg text)
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
    IF v_rest ~ '^[a-z0-9_]+:[[:space:]]' AND split_part(v_rest, ':', 1) = ANY (v_cols) THEN
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

-- The report of a run (M01's) plus, for opening contracts, the per-contract list and the totals.
CREATE OR REPLACE FUNCTION app.import_report(p_res jsonb, p_meta jsonb, p_branch uuid)
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
    || CASE WHEN p_res ? 'summary'
            THEN jsonb_build_object('summary', p_res -> 'summary', 'contracts', COALESCE(p_res -> 'contracts', '[]'::jsonb))
            ELSE '{}'::jsonb END
$$;

CREATE OR REPLACE FUNCTION app.import_run(p_org uuid, p_emp uuid, p_kind text, p_rows jsonb, p_apply boolean, p_branch uuid, p_job uuid)
RETURNS jsonb LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    RETURN CASE p_kind
        WHEN 'suppliers' THEN app.import_suppliers(p_org, p_emp, p_rows, p_apply)
        WHEN 'products' THEN app.import_products(p_org, p_emp, p_rows, p_apply)
        WHEN 'customers' THEN app.import_customers(p_org, p_emp, p_rows, p_apply)
        WHEN 'opening_stock' THEN app.import_opening_stock(p_org, p_emp, p_rows, p_apply, p_branch, p_job)
        WHEN 'opening_contracts' THEN app.import_opening_contracts(p_org, p_emp, p_rows, p_apply, p_job)
        WHEN 'opening_cash' THEN app.import_opening_cash(p_org, p_emp, p_rows, p_apply, p_job)
    END;
END;
$$;

-- 3. Helpers ------------------------------------------------------------------------------------------

-- Appends one row error (the message is "CODE: column: text", M01's format) to a list of errors.
CREATE FUNCTION app.m02_err(p_errors jsonb, p_kind text, p_row integer, p_msg text, p_state text DEFAULT 'P0001')
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT CASE WHEN jsonb_array_length(p_errors) >= 5000 THEN p_errors
                ELSE p_errors || jsonb_build_array(app.import_error(p_row, p_kind, p_state, p_msg)) END
$$;

-- monthly (default) or weekly; Arabic words accepted.
CREATE FUNCTION app.m02_frequency(p_val text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v text := lower(btrim(COALESCE(p_val, '')));
BEGIN
    IF v = '' OR v IN ('monthly', 'month', U&'\0634\0647\0631\064A', U&'\0634\0647\0631\064A\0627') THEN RETURN 'monthly'; END IF;
    IF v IN ('weekly', 'week', U&'\0623\0633\0628\0648\0639\064A', U&'\0627\0633\0628\0648\0639\064A') THEN RETURN 'weekly'; END IF;
    RAISE EXCEPTION 'IMPORT_INVALID_VALUE: frequency: monthly or weekly';
END;
$$;

-- The branch of a row: the code (active branch), else the main branch. The importer must work there.
CREATE FUNCTION app.m02_branch(p_org uuid, p_emp uuid, p_code text)
RETURNS uuid LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_code text := upper(btrim(COALESCE(p_code, ''))); v_id uuid;
BEGIN
    IF v_code = '' THEN
        SELECT b.id INTO v_id FROM public.branches b WHERE b.organization_id = p_org AND b.is_main AND b.is_active;
    ELSE
        SELECT b.id INTO v_id FROM public.branches b WHERE b.organization_id = p_org AND b.code = v_code AND b.is_active;
    END IF;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'IMPORT_INVALID_VALUE: branch_code: no active branch with this code';
    END IF;
    IF NOT app.employee_has_branch(p_emp, v_id) THEN
        RAISE EXCEPTION 'IMPORT_INVALID_VALUE: branch_code: you cannot work in this branch';
    END IF;
    RETURN v_id;
END;
$$;

-- Today (the import day) is closed for the branch (K04).
CREATE FUNCTION app.m02_day_closed(p_org uuid, p_branch uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT EXISTS (SELECT 1 FROM public.day_closes dc
                   WHERE dc.organization_id = p_org AND dc.branch_id = p_branch
                     AND dc.business_date = app.org_today(p_org) AND dc.status = 'closed')
$$;

-- A guarantor cell group of a row as one object, NULL when every cell is empty.
CREATE FUNCTION app.m02_guarantor_cells(v jsonb, n integer)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT CASE WHEN g.nid = '' AND g.name = '' AND g.phone = '' AND g.address = '' AND g.relation = '' THEN NULL
                ELSE jsonb_build_object('nid', g.nid, 'name', g.name, 'phone', g.phone, 'address', g.address,
                                        'relation', g.relation) END
    FROM (SELECT app.import_national_id(v ->> ('guarantor' || n || '_national_id')) AS nid,
                 regexp_replace(btrim(COALESCE(v ->> ('guarantor' || n || '_name'), '')), '[[:space:]]+', ' ', 'g') AS name,
                 COALESCE(app.normalize_customer_phone((app.import_phone_list(v ->> ('guarantor' || n || '_phone')))[1]), '') AS phone,
                 btrim(COALESCE(v ->> ('guarantor' || n || '_address'), '')) AS address,
                 lower(btrim(COALESCE(v ->> ('guarantor' || n || '_relation'), ''))) AS relation) g
$$;

REVOKE ALL ON FUNCTION app.m02_err(jsonb, text, integer, text, text), app.m02_frequency(text),
    app.m02_branch(uuid, uuid, text), app.m02_day_closed(uuid, uuid), app.m02_guarantor_cells(jsonb, integer)
    FROM PUBLIC, anon, authenticated;

-- 4. Opening contracts -------------------------------------------------------------------------------

-- One row per remaining installment; grouped by contract_ref. Phase 1 reads every row's cells
-- (errors by row and column). Phase 2 checks and, when p_apply, writes one contract at a time: the
-- customer, the branch, the balance rule, the principal / profit split, the guarantors. The caller
-- rolls everything back when there is any error (all or nothing).
CREATE FUNCTION app.import_opening_contracts(p_org uuid, p_emp uuid, p_rows jsonb, p_apply boolean, p_job uuid)
RETURNS jsonb LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
    r record; g record; c record; d record; l record; v jsonb;
    v_errors jsonb := '[]'::jsonb; v_err integer := 0; v_preview jsonb := '[]'::jsonb; v_warnings jsonb := '[]'::jsonb;
    v_contracts jsonb := '[]'::jsonb; v_msg text; v_state text; v_gn integer; v_bad boolean;
    v_today date := app.org_today(p_org); v_policy public.installment_policies;
    v_ref text; v_nid text; v_phone text; v_date date; v_orig numeric; v_paid numeric; v_freq text; v_rp numeric; v_rf numeric;
    v_due date; v_amt numeric; v_cells jsonb; v_cell jsonb; v_branch uuid; v_cust public.customers; v_ids uuid[];
    v_lines_n integer; v_lines_sum numeric; v_principal numeric; v_profit numeric; v_overdue numeric; v_overdue_days integer;
    v_first_due date; v_k integer; v_g_nid text; v_g_rel text; v_g public.guarantors; v_new_g text[] := '{}';
    v_new_here integer; v_gids uuid[]; v_cid uuid; v_number text; v_pct numeric;
    s_contracts integer := 0; s_lines integer := 0; s_open numeric := 0; s_overdue numeric := 0; s_overdue_n integer := 0;
    s_new_g integer := 0; v_show jsonb; v_at integer;
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS pg_temp.m02_rows (
        rn integer, ord integer, ref text, ref_key text, nid text, phone text, branch_code text, contract_date date,
        original_total numeric, paid_before numeric, frequency text, rem_principal numeric, rem_profit numeric,
        notes text, due_date date, amount numeric, g1 jsonb, g2 jsonb, bad boolean NOT NULL DEFAULT false
    ) ON COMMIT DROP;
    TRUNCATE pg_temp.m02_rows;

    v_policy := app.current_installment_policy(p_org);

    -- Phase 1: every row's own cells.
    FOR r IN SELECT (e.value ->> 'row')::integer AS rn, e.ord::integer AS ord, e.value -> 'values' AS vals
             FROM jsonb_array_elements(p_rows) WITH ORDINALITY e(value, ord) ORDER BY e.ord
    LOOP
        BEGIN
            v := r.vals;
            v_ref := btrim(COALESCE(v ->> 'contract_ref', ''));
            IF v_ref = '' THEN
                RAISE EXCEPTION 'IMPORT_REQUIRED: contract_ref: the old contract number is required';
            END IF;
            IF length(v_ref) > 60 THEN
                RAISE EXCEPTION 'IMPORT_INVALID_VALUE: contract_ref: at most 60 characters';
            END IF;
            v_nid := NULLIF(app.import_national_id(v ->> 'customer_national_id'), '');
            IF v_nid IS NOT NULL AND (SELECT p.birth_date FROM app.parse_national_id(v_nid) p) IS NULL THEN
                RAISE EXCEPTION 'NATIONAL_ID_INVALID: customer_national_id: not a valid 14-digit national ID';
            END IF;
            v_phone := NULLIF(app.normalize_customer_phone((app.import_phone_list(v ->> 'customer_phone'))[1]), '');
            v_date := app.import_date('contract_date', v ->> 'contract_date');
            v_orig := app.import_money('original_total', v ->> 'original_total');
            v_paid := app.import_money('paid_before', v ->> 'paid_before');
            v_freq := CASE WHEN NULLIF(btrim(v ->> 'frequency'), '') IS NULL THEN NULL
                           ELSE app.m02_frequency(v ->> 'frequency') END;
            v_rp := app.import_money('remaining_principal', v ->> 'remaining_principal');
            v_rf := app.import_money('remaining_profit', v ->> 'remaining_profit');
            v_due := app.import_date('due_date', v ->> 'due_date');
            IF v_due IS NULL THEN
                RAISE EXCEPTION 'IMPORT_REQUIRED: due_date: the due date of the installment is required';
            END IF;
            v_amt := app.import_money('amount', v ->> 'amount');
            IF v_amt IS NULL THEN
                RAISE EXCEPTION 'IMPORT_REQUIRED: amount: what is left on the installment is required';
            END IF;
            IF v_amt <= 0 THEN
                RAISE EXCEPTION 'IMPORT_INVALID_VALUE: amount: must be above zero';
            END IF;
            INSERT INTO pg_temp.m02_rows (rn, ord, ref, ref_key, nid, phone, branch_code, contract_date, original_total,
                                          paid_before, frequency, rem_principal, rem_profit, notes, due_date, amount, g1, g2)
            VALUES (r.rn, r.ord, v_ref, upper(v_ref), v_nid, v_phone, NULLIF(upper(btrim(v ->> 'branch_code')), ''),
                    v_date, v_orig, v_paid, v_freq, v_rp, v_rf, left(NULLIF(btrim(v ->> 'notes'), ''), 500), v_due, v_amt,
                    app.m02_guarantor_cells(v, 1), app.m02_guarantor_cells(v, 2));
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            v_err := v_err + 1;
            v_errors := app.m02_err(v_errors, 'opening_contracts', r.rn, v_msg, v_state);
            INSERT INTO pg_temp.m02_rows (rn, ord, ref_key, bad)
            VALUES (r.rn, r.ord, NULLIF(upper(btrim(COALESCE(r.vals ->> 'contract_ref', ''))), ''), true);
        END;
    END LOOP;

    -- Phase 2: one contract at a time, in the order of its first row.
    FOR g IN SELECT m.ref_key, min(m.ord) AS first_ord FROM pg_temp.m02_rows m
             WHERE m.ref_key IS NOT NULL GROUP BY m.ref_key ORDER BY min(m.ord)
    LOOP
        v_gn := 0;
        v_at := (SELECT min(m.rn) FROM pg_temp.m02_rows m WHERE m.ref_key = g.ref_key);
        BEGIN
            SELECT min(m.rn) AS head_rn,
                   (array_agg(m.rn ORDER BY m.ord) FILTER (WHERE NOT m.bad))[1] AS first_rn,
                   bool_or(m.bad) AS has_bad,
                   (array_agg(m.ref ORDER BY m.ord) FILTER (WHERE NOT m.bad))[1] AS ref,
                   (array_agg(m.nid ORDER BY m.ord) FILTER (WHERE m.nid IS NOT NULL AND NOT m.bad))[1] AS nid,
                   (array_agg(m.phone ORDER BY m.ord) FILTER (WHERE m.phone IS NOT NULL AND NOT m.bad))[1] AS phone,
                   (array_agg(m.branch_code ORDER BY m.ord) FILTER (WHERE m.branch_code IS NOT NULL AND NOT m.bad))[1] AS branch_code,
                   (array_agg(m.contract_date ORDER BY m.ord) FILTER (WHERE m.contract_date IS NOT NULL AND NOT m.bad))[1] AS contract_date,
                   (array_agg(m.original_total ORDER BY m.ord) FILTER (WHERE m.original_total IS NOT NULL AND NOT m.bad))[1] AS original_total,
                   (array_agg(m.paid_before ORDER BY m.ord) FILTER (WHERE m.paid_before IS NOT NULL AND NOT m.bad))[1] AS paid_before,
                   (array_agg(m.frequency ORDER BY m.ord) FILTER (WHERE m.frequency IS NOT NULL AND NOT m.bad))[1] AS frequency,
                   (array_agg(m.rem_principal ORDER BY m.ord) FILTER (WHERE m.rem_principal IS NOT NULL AND NOT m.bad))[1] AS rem_principal,
                   (array_agg(m.rem_profit ORDER BY m.ord) FILTER (WHERE m.rem_profit IS NOT NULL AND NOT m.bad))[1] AS rem_profit,
                   (array_agg(m.notes ORDER BY m.ord) FILTER (WHERE m.notes IS NOT NULL AND NOT m.bad))[1] AS notes,
                   (array_agg(m.g1 ORDER BY m.ord) FILTER (WHERE m.g1 IS NOT NULL AND NOT m.bad))[1] AS g1,
                   (array_agg(m.g2 ORDER BY m.ord) FILTER (WHERE m.g2 IS NOT NULL AND NOT m.bad))[1] AS g2,
                   count(*) FILTER (WHERE NOT m.bad) AS n_lines,
                   COALESCE(sum(m.amount) FILTER (WHERE NOT m.bad), 0) AS lines_sum,
                   min(m.due_date) FILTER (WHERE NOT m.bad) AS first_due,
                   COALESCE(sum(m.amount) FILTER (WHERE NOT m.bad AND m.due_date < v_today), 0) AS overdue_sum,
                   min(m.due_date) FILTER (WHERE NOT m.bad AND m.due_date < v_today) AS oldest_overdue
            INTO c
            FROM pg_temp.m02_rows m WHERE m.ref_key = g.ref_key;
            v_bad := c.has_bad;

            -- Rows that disagree with the contract's first value (the first row that holds one).
            FOR d IN
                SELECT DISTINCT ON (m.rn) m.rn, x.col
                FROM pg_temp.m02_rows m
                CROSS JOIN LATERAL (VALUES
                    ('customer_national_id', m.nid IS NOT NULL AND m.nid IS DISTINCT FROM c.nid),
                    ('customer_phone', m.phone IS NOT NULL AND m.phone IS DISTINCT FROM c.phone),
                    ('branch_code', m.branch_code IS NOT NULL AND m.branch_code IS DISTINCT FROM c.branch_code),
                    ('contract_date', m.contract_date IS NOT NULL AND m.contract_date IS DISTINCT FROM c.contract_date),
                    ('original_total', m.original_total IS NOT NULL AND m.original_total IS DISTINCT FROM c.original_total),
                    ('paid_before', m.paid_before IS NOT NULL AND m.paid_before IS DISTINCT FROM c.paid_before),
                    ('frequency', m.frequency IS NOT NULL AND m.frequency IS DISTINCT FROM c.frequency),
                    ('remaining_principal', m.rem_principal IS NOT NULL AND m.rem_principal IS DISTINCT FROM c.rem_principal),
                    ('remaining_profit', m.rem_profit IS NOT NULL AND m.rem_profit IS DISTINCT FROM c.rem_profit)
                ) x(col, differs)
                WHERE m.ref_key = g.ref_key AND NOT m.bad AND m.rn <> c.first_rn AND x.differs
                ORDER BY m.rn
            LOOP
                v_errors := app.m02_err(v_errors, 'opening_contracts', d.rn,
                    'IMPORT_CONTRACT_ROWS_DIFFER: ' || d.col || ': differs from the first row of contract ' || c.ref);
                v_gn := v_gn + 1;
            END LOOP;

            IF c.first_rn IS NULL THEN
                v_err := v_err + v_gn;
                CONTINUE;                           -- every row of it failed on its own: already reported
            END IF;
            v_at := c.first_rn;

            IF v_policy.id IS NULL THEN
                v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                    'POLICY_NOT_SET: contract_ref: publish an installment policy first');
                v_gn := v_gn + 1;
            END IF;
            IF NOT v_bad THEN
                IF c.nid IS NULL AND c.phone IS NULL THEN
                    v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                        'IMPORT_REQUIRED: customer_national_id: the customer national ID or phone is required');
                    v_gn := v_gn + 1;
                END IF;
                IF c.contract_date IS NULL THEN
                    v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                        'IMPORT_REQUIRED: contract_date: the old signing date is required');
                    v_gn := v_gn + 1;
                END IF;
                IF c.original_total IS NULL OR c.original_total <= 0 THEN
                    v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                        'IMPORT_REQUIRED: original_total: the installment price the customer signed for is required');
                    v_gn := v_gn + 1;
                END IF;
                IF c.paid_before IS NULL THEN
                    v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                        'IMPORT_REQUIRED: paid_before: what was paid before the migration is required (0 if nothing)');
                    v_gn := v_gn + 1;
                END IF;
            END IF;
            IF c.n_lines > 520 THEN
                v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                    'IMPORT_INVALID_VALUE: due_date: a contract has at most 520 installments');
                v_gn := v_gn + 1;
            END IF;

            -- The branch.
            v_branch := NULL;
            BEGIN
                v_branch := app.m02_branch(p_org, p_emp, c.branch_code);
            EXCEPTION WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
                v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn, v_msg);
                v_gn := v_gn + 1;
            END;

            -- The customer: national ID first, else phone.
            v_cust := NULL; v_ids := '{}';
            IF c.nid IS NOT NULL THEN
                SELECT COALESCE(array_agg(x.id), '{}') INTO v_ids FROM public.customers x
                WHERE x.organization_id = p_org AND x.national_id = c.nid;
            END IF;
            IF cardinality(v_ids) = 0 AND c.phone IS NOT NULL THEN
                SELECT COALESCE(array_agg(x.id), '{}') INTO v_ids FROM public.customers x
                WHERE x.organization_id = p_org AND x.phones @> ARRAY[c.phone];
            END IF;
            IF cardinality(v_ids) > 1 THEN
                v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                    'IMPORT_AMBIGUOUS_MATCH: customer_phone: ' || cardinality(v_ids) || ' customers have this phone; give the national ID');
                v_gn := v_gn + 1;
            ELSIF cardinality(v_ids) = 0 THEN
                IF c.nid IS NOT NULL OR c.phone IS NOT NULL THEN
                    v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                        'IMPORT_CUSTOMER_NOT_FOUND: ' || CASE WHEN c.nid IS NOT NULL THEN 'customer_national_id' ELSE 'customer_phone' END
                        || ': import the customer first (customers import)');
                    v_gn := v_gn + 1;
                END IF;
            ELSE
                SELECT * INTO v_cust FROM public.customers x WHERE x.id = v_ids[1];
                IF v_cust.status = 'blocked' OR v_cust.archived_at IS NOT NULL THEN
                    IF jsonb_array_length(v_warnings) < 100 THEN
                        v_warnings := v_warnings || jsonb_build_array(jsonb_build_object('code', 'IMPORT_NOTE', 'column', NULL,
                            'message', 'Contract ' || c.ref || ': the customer is ' ||
                                       CASE WHEN v_cust.archived_at IS NOT NULL THEN 'archived' ELSE 'blocked' END ||
                                       '; the debt is imported anyway'));
                    END IF;
                END IF;
            END IF;

            -- A contract number the shop already migrated.
            IF EXISTS (SELECT 1 FROM public.contracts k
                       WHERE k.organization_id = p_org AND k.is_migrated AND k.migration_source IS NOT NULL
                         AND upper(k.migration_source ->> 'contract_ref') = g.ref_key
                         AND (k.migration_source ->> 'reversed') IS DISTINCT FROM 'true') THEN
                v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                    'IMPORT_CONTRACT_EXISTS: contract_ref: this contract number was already migrated');
                v_gn := v_gn + 1;
            END IF;

            -- The balance rule and the split of what is left.
            v_principal := NULL; v_profit := NULL;
            IF NOT v_bad AND c.original_total IS NOT NULL AND c.paid_before IS NOT NULL THEN
                IF c.original_total - c.paid_before <> c.lines_sum THEN
                    v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                        'IMPORT_CONTRACT_NOT_BALANCED: paid_before: original_total - paid_before = '
                        || (c.original_total - c.paid_before)::numeric(18,2)::text
                        || ' but the installments add up to ' || c.lines_sum::numeric(18,2)::text);
                    v_gn := v_gn + 1;
                ELSIF (c.rem_principal IS NULL) <> (c.rem_profit IS NULL) THEN
                    v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                        'IMPORT_INVALID_VALUE: remaining_profit: give both remaining_principal and remaining_profit, or neither');
                    v_gn := v_gn + 1;
                ELSIF c.rem_principal IS NOT NULL AND c.rem_principal + c.rem_profit <> c.lines_sum THEN
                    v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                        'IMPORT_CONTRACT_NOT_BALANCED: remaining_principal: remaining_principal + remaining_profit = '
                        || (c.rem_principal + c.rem_profit)::numeric(18,2)::text
                        || ' but the installments add up to ' || c.lines_sum::numeric(18,2)::text);
                    v_gn := v_gn + 1;
                ELSE
                    IF c.rem_principal IS NULL THEN
                        v_principal := c.lines_sum; v_profit := 0;     -- everything left is principal (owner question 2)
                    ELSE
                        v_principal := c.rem_principal; v_profit := c.rem_profit;
                    END IF;
                    IF v_principal <= 0 THEN
                        v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                            'IMPORT_INVALID_VALUE: remaining_principal: must be above zero');
                        v_gn := v_gn + 1;
                    ELSIF v_profit > 0 AND EXISTS (
                            SELECT 1 FROM (
                                SELECT m.amount, round(sum(m.amount) OVER w * v_profit / c.lines_sum, 2)
                                       - round(COALESCE(sum(m.amount) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
                                               * v_profit / c.lines_sum, 2) AS p
                                FROM pg_temp.m02_rows m WHERE m.ref_key = g.ref_key AND NOT m.bad
                                WINDOW w AS (ORDER BY m.due_date, m.rn)) s
                            WHERE s.p > s.amount) THEN
                        v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                            'IMPORT_CONTRACT_NOT_BALANCED: remaining_profit: the profit cannot be spread over these installments');
                        v_gn := v_gn + 1;
                    END IF;
                END IF;
            END IF;

            -- Today must be open for the branch (K04).
            IF v_branch IS NOT NULL AND app.m02_day_closed(p_org, v_branch) THEN
                v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                    'DAY_CLOSED: branch_code: today is closed for this branch; reopen it first');
                v_gn := v_gn + 1;
            END IF;

            -- Guarantors (up to two).
            v_new_here := 0; v_gids := '{}';
            FOR v_k IN 1..2 LOOP
                v_cell := CASE v_k WHEN 1 THEN c.g1 ELSE c.g2 END;
                CONTINUE WHEN v_cell IS NULL;
                v_g_nid := v_cell ->> 'nid';
                v_g_rel := COALESCE(NULLIF(v_cell ->> 'relation', ''), 'other');
                IF v_g_nid = '' OR (SELECT p.birth_date FROM app.parse_national_id(v_g_nid) p) IS NULL THEN
                    v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                        'IMPORT_GUARANTOR_INCOMPLETE: guarantor' || v_k || '_national_id: a valid 14-digit national ID is required');
                    v_gn := v_gn + 1;
                    CONTINUE;
                END IF;
                IF v_g_rel <> ALL (app.guarantor_relations()) THEN
                    v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                        'IMPORT_INVALID_VALUE: guarantor' || v_k || '_relation: father, mother, brother, sister, spouse, son, daughter, relative, friend, colleague, employer, neighbour or other');
                    v_gn := v_gn + 1;
                END IF;
                IF v_cust.id IS NOT NULL AND v_g_nid = v_cust.national_id THEN
                    v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                        'IMPORT_INVALID_VALUE: guarantor' || v_k || '_national_id: the guarantor is the customer');
                    v_gn := v_gn + 1;
                    CONTINUE;
                END IF;
                IF v_k = 2 AND v_g_nid = (c.g1 ->> 'nid') THEN
                    v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                        'IMPORT_DUPLICATE_ROW: guarantor2_national_id: the same guarantor twice');
                    v_gn := v_gn + 1;
                    CONTINUE;
                END IF;
                SELECT * INTO v_g FROM public.guarantors x WHERE x.organization_id = p_org AND x.national_id = v_g_nid;
                IF FOUND THEN
                    IF v_g.archived_at IS NOT NULL THEN
                        v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                            'IMPORT_GUARANTOR_INCOMPLETE: guarantor' || v_k || '_national_id: the guarantor is archived; restore it first');
                        v_gn := v_gn + 1;
                    END IF;
                    v_gids := v_gids || v_g.id;
                ELSIF v_g_nid = ANY (v_new_g) THEN
                    NULL;                           -- created by an earlier contract of this file
                ELSE
                    IF length(v_cell ->> 'name') NOT BETWEEN 2 AND 150 THEN
                        v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                            'IMPORT_GUARANTOR_INCOMPLETE: guarantor' || v_k || '_name: a new guarantor needs a name (2 to 150 characters)');
                        v_gn := v_gn + 1;
                    END IF;
                    IF (v_cell ->> 'phone') !~ '^\+?[0-9]{7,15}$' THEN
                        v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                            'IMPORT_GUARANTOR_INCOMPLETE: guarantor' || v_k || '_phone: a new guarantor needs a phone');
                        v_gn := v_gn + 1;
                    END IF;
                    IF length(v_cell ->> 'address') > 300 THEN
                        v_errors := app.m02_err(v_errors, 'opening_contracts', c.first_rn,
                            'IMPORT_INVALID_VALUE: guarantor' || v_k || '_address: at most 300 characters');
                        v_gn := v_gn + 1;
                    END IF;
                    v_new_here := v_new_here + 1;
                END IF;
            END LOOP;

            -- Write it (apply only, and only a contract without errors).
            IF v_gn = 0 AND p_apply THEN
                v_number := app.next_document_number(p_org, v_branch, 'contract');
                v_pct := CASE WHEN v_principal > 0 THEN least(round(v_profit / v_principal * 100, 4), 999.9999) ELSE 0 END;
                INSERT INTO public.contracts (organization_id, number, customer_id, branch_id, policy_id, creditor, cash_price,
                                              down_payment, financed_amount, markup_pct, markup_amount, total_payable,
                                              installments_count, frequency, first_due_date, is_migrated, migration_batch_id,
                                              migration_source, idempotency_key, created_by)
                VALUES (p_org, v_number, v_cust.id, v_branch, v_policy.id,
                        (SELECT o.creditor_model FROM public.organizations o WHERE o.id = p_org),
                        v_principal, 0, v_principal, v_pct, v_profit, v_principal + v_profit, c.n_lines::integer,
                        COALESCE(c.frequency, 'monthly')::public.installment_frequency, c.first_due, true, p_job,
                        jsonb_strip_nulls(jsonb_build_object('contract_ref', c.ref,
                            'contract_date', to_char(c.contract_date, 'YYYY-MM-DD'),
                            'original_total', c.original_total::numeric(18,2)::text,
                            'paid_before', c.paid_before::numeric(18,2)::text, 'notes', c.notes)),
                        left('m02:' || p_job::text || ':' || g.ref_key, 128), p_emp)
                RETURNING id INTO v_cid;
                INSERT INTO public.schedule_lines (organization_id, contract_id, version, seq, due_date, principal, profit, created_by)
                SELECT p_org, v_cid, 1, s.seq, s.due_date, s.amount - s.p, s.p, p_emp
                FROM (SELECT row_number() OVER w AS seq, m.due_date, m.amount,
                             CASE WHEN v_profit = 0 THEN 0::numeric
                                  ELSE round(sum(m.amount) OVER w * v_profit / c.lines_sum, 2)
                                       - round(COALESCE(sum(m.amount) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
                                               * v_profit / c.lines_sum, 2) END AS p
                      FROM pg_temp.m02_rows m WHERE m.ref_key = g.ref_key AND NOT m.bad
                      WINDOW w AS (ORDER BY m.due_date, m.rn)) s;
                FOR v_k IN 1..2 LOOP
                    v_cell := CASE v_k WHEN 1 THEN c.g1 ELSE c.g2 END;
                    CONTINUE WHEN v_cell IS NULL;
                    v_g_nid := v_cell ->> 'nid';
                    SELECT * INTO v_g FROM public.guarantors x WHERE x.organization_id = p_org AND x.national_id = v_g_nid;
                    IF NOT FOUND THEN
                        INSERT INTO public.guarantors (organization_id, full_name, phone, national_id, address, customer_id,
                                                       created_by, updated_by)
                        VALUES (p_org, v_cell ->> 'name', v_cell ->> 'phone', v_g_nid, NULLIF(v_cell ->> 'address', ''),
                                (SELECT x.id FROM public.customers x WHERE x.organization_id = p_org AND x.national_id = v_g_nid),
                                p_emp, p_emp)
                        RETURNING * INTO v_g;
                    END IF;
                    IF NOT EXISTS (SELECT 1 FROM public.customer_guarantors cg
                                   WHERE cg.customer_id = v_cust.id AND cg.guarantor_id = v_g.id) THEN
                        IF (SELECT count(*) FROM public.customer_guarantors cg WHERE cg.customer_id = v_cust.id) >= 5 THEN
                            RAISE EXCEPTION 'IMPORT_GUARANTOR_INCOMPLETE: guarantor%_national_id: the customer already has 5 guarantors', v_k;
                        END IF;
                        INSERT INTO public.customer_guarantors (organization_id, customer_id, guarantor_id, relation, created_by)
                        VALUES (p_org, v_cust.id, v_g.id, COALESCE(NULLIF(v_cell ->> 'relation', ''), 'other'), p_emp);
                    END IF;
                    INSERT INTO public.contract_guarantors (organization_id, contract_id, guarantor_id, created_by)
                    VALUES (p_org, v_cid, v_g.id, p_emp);
                END LOOP;
                INSERT INTO public.audit_log (organization_id, branch_id, employee_id, action, entity_type, entity_id, severity, after)
                VALUES (p_org, v_branch, p_emp, 'contract.migrated', 'contract', v_cid, 'info',
                        jsonb_build_object('number', v_number, 'contract_ref', c.ref, 'customer_id', v_cust.id,
                                           'import_job_id', p_job, 'original_total', c.original_total::numeric(18,2)::text,
                                           'paid_before', c.paid_before::numeric(18,2)::text,
                                           'total_payable', (v_principal + v_profit)::numeric(18,2)::text,
                                           'installments_count', c.n_lines));
            END IF;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            v_errors := app.m02_err(v_errors, 'opening_contracts', v_at, v_msg, v_state);
            v_gn := v_gn + 1;
        END;

        v_err := v_err + v_gn;
        IF v_gn = 0 THEN
            s_contracts := s_contracts + 1;
            s_lines := s_lines + c.n_lines::integer;
            s_open := s_open + c.lines_sum;
            IF c.overdue_sum > 0 THEN
                s_overdue := s_overdue + c.overdue_sum;
                s_overdue_n := s_overdue_n + 1;
            END IF;
            s_new_g := s_new_g + v_new_here;
            v_new_g := v_new_g || ARRAY(SELECT x ->> 'nid' FROM unnest(ARRAY[c.g1, c.g2]) x
                                         WHERE x IS NOT NULL AND NOT EXISTS (
                                             SELECT 1 FROM public.guarantors y
                                             WHERE y.organization_id = p_org AND y.national_id = x ->> 'nid'));
            IF jsonb_array_length(v_contracts) < 200 THEN
                v_contracts := v_contracts || jsonb_build_array(jsonb_build_object(
                    'row', c.first_rn, 'contract_ref', c.ref, 'customer', v_cust.full_name,
                    'lines', c.n_lines, 'open_total', c.lines_sum::numeric(18,2)::text,
                    'overdue_total', c.overdue_sum::numeric(18,2)::text,
                    'overdue_days', CASE WHEN c.oldest_overdue IS NULL THEN 0 ELSE v_today - c.oldest_overdue END,
                    'new_guarantors', v_new_here));
            END IF;
        END IF;
    END LOOP;

    FOR r IN SELECT m.rn, m.ord FROM pg_temp.m02_rows m ORDER BY m.ord LIMIT 20 LOOP
        SELECT (e.value -> 'values') INTO v_show FROM jsonb_array_elements(p_rows) e WHERE (e.value ->> 'row')::integer = r.rn;
        IF NULLIF(app.import_national_id(v_show ->> 'customer_national_id'), '') IS NOT NULL THEN
            v_show := jsonb_set(v_show, '{customer_national_id}',
                                to_jsonb(app.mask_national_id(app.import_national_id(v_show ->> 'customer_national_id'))));
        END IF;
        FOR v_k IN 1..2 LOOP
            IF NULLIF(app.import_national_id(v_show ->> ('guarantor' || v_k || '_national_id')), '') IS NOT NULL THEN
                v_show := jsonb_set(v_show, ARRAY['guarantor' || v_k || '_national_id'],
                    to_jsonb(app.mask_national_id(app.import_national_id(v_show ->> ('guarantor' || v_k || '_national_id')))));
            END IF;
        END LOOP;
        v_preview := v_preview || jsonb_build_array(jsonb_build_object('row', r.rn, 'action', 'create', 'values', v_show));
    END LOOP;

    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object('code', 'IMPORT_NOTE', 'column', NULL,
        'message', 'Fees in the old records are not imported: only what is left of the installment price is'));

    RETURN jsonb_build_object('errors', v_errors, 'errors_total', v_err,
        'actions', jsonb_build_object('create', s_contracts, 'update', 0, 'unchanged', 0),
        'preview', v_preview, 'will_create_categories', '[]'::jsonb, 'warnings', v_warnings,
        'contracts', v_contracts,
        'summary', jsonb_build_object('contracts', s_contracts, 'lines', s_lines, 'open_total', s_open::numeric(18,2)::text,
                                      'overdue_total', s_overdue::numeric(18,2)::text, 'overdue_contracts', s_overdue_n,
                                      'new_guarantors', s_new_g));
END;
$$;

-- 5. Opening cash -------------------------------------------------------------------------------------

-- One row per safe or bank: found (same branch and name) or created, then its balance posted as ONE
-- 'opening' movement through the job (K01's rule). An account that already has movements is refused.
CREATE FUNCTION app.import_opening_cash(p_org uuid, p_emp uuid, p_rows jsonb, p_apply boolean, p_job uuid)
RETURNS jsonb LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
    r record; v jsonb; v_errors jsonb := '[]'::jsonb; v_err integer := 0; v_preview jsonb := '[]'::jsonb;
    v_msg text; v_state text; v_name text; v_kind text; v_kind_txt text; v_balance numeric; v_wide boolean;
    v_branch uuid; v_book_branch uuid; v_a public.cash_accounts; v_found boolean; v_seen jsonb := '{}'::jsonb;
    v_key text; v_action text; v_create integer := 0; v_update integer := 0; v_same integer := 0;
    v_total numeric := 0; v_new_accounts integer := 0; v_id uuid;
BEGIN
    FOR r IN SELECT (e.value ->> 'row')::integer AS rn, e.value -> 'values' AS vals
             FROM jsonb_array_elements(p_rows) WITH ORDINALITY e(value, ord) ORDER BY e.ord
    LOOP
        v_action := NULL;
        BEGIN
            v := r.vals;
            v_name := regexp_replace(btrim(COALESCE(v ->> 'account_name', '')), '[[:space:]]+', ' ', 'g');
            IF v_name = '' THEN
                RAISE EXCEPTION 'IMPORT_REQUIRED: account_name: the account name is required';
            END IF;
            IF length(v_name) > 100 THEN
                RAISE EXCEPTION 'IMPORT_INVALID_VALUE: account_name: at most 100 characters';
            END IF;
            v_kind_txt := lower(btrim(COALESCE(v ->> 'kind', '')));
            IF v_kind_txt = '' THEN
                RAISE EXCEPTION 'IMPORT_REQUIRED: kind: safe or bank';
            END IF;
            v_kind := CASE WHEN v_kind_txt IN ('safe', U&'\062E\0632\0646\0629', U&'\062E\0632\064A\0646\0629', U&'\062E\0632\0646\0647') THEN 'safe'
                           WHEN v_kind_txt IN ('bank', U&'\0628\0646\0643') THEN 'bank' END;
            IF v_kind IS NULL THEN
                RAISE EXCEPTION 'IMPORT_ACCOUNT_KIND: kind: only a safe or a bank can be imported (not a drawer or a wallet)';
            END IF;
            v_balance := app.import_money('balance', v ->> 'balance');
            IF v_balance IS NULL THEN
                RAISE EXCEPTION 'IMPORT_REQUIRED: balance: the balance is required (0 creates the account only)';
            END IF;
            v_wide := COALESCE(app.import_bool('bank_shop_wide', v ->> 'bank_shop_wide'), false);
            IF v_wide AND v_kind <> 'bank' THEN
                RAISE EXCEPTION 'IMPORT_INVALID_VALUE: bank_shop_wide: only a bank can be shop-wide';
            END IF;
            v_branch := CASE WHEN v_wide THEN NULL ELSE app.m02_branch(p_org, p_emp, v ->> 'branch_code') END;
            v_book_branch := COALESCE(v_branch, (SELECT b.id FROM public.branches b WHERE b.organization_id = p_org AND b.is_main));
            IF v_wide AND NOT app.employee_has_branch(p_emp, v_book_branch) THEN
                RAISE EXCEPTION 'IMPORT_INVALID_VALUE: bank_shop_wide: you cannot work in the main branch';
            END IF;

            v_key := COALESCE(v_branch::text, '*') || '|' || v_name;
            IF v_seen ? v_key THEN
                RAISE EXCEPTION 'IMPORT_DUPLICATE_ROW: account_name: same account as row %', v_seen ->> v_key;
            END IF;
            v_seen := v_seen || jsonb_build_object(v_key, r.rn);

            SELECT * INTO v_a FROM public.cash_accounts a
            WHERE a.organization_id = p_org AND a.branch_id IS NOT DISTINCT FROM v_branch AND a.name = v_name;
            v_found := FOUND;
            IF v_found THEN
                IF v_a.kind::text <> v_kind THEN
                    RAISE EXCEPTION 'CASH_ACCOUNT_NAME_TAKEN: account_name: another account of this branch has the name';
                END IF;
                IF NOT v_a.is_active THEN
                    RAISE EXCEPTION 'CASH_ACCOUNT_INACTIVE: account_name: the account is inactive';
                END IF;
                IF EXISTS (SELECT 1 FROM public.cash_movements m WHERE m.organization_id = p_org AND m.cash_account_id = v_a.id) THEN
                    RAISE EXCEPTION 'CASH_ACCOUNT_HAS_MOVEMENTS: account_name: the account already has movements; use a transfer or a day reopen';
                END IF;
            END IF;
            IF v_balance > 0 AND app.m02_day_closed(p_org, v_book_branch) THEN
                RAISE EXCEPTION 'DAY_CLOSED: branch_code: today is closed for this branch; reopen it first';
            END IF;

            v_action := CASE WHEN v_found THEN 'update' ELSE 'create' END;
            IF p_apply THEN
                IF NOT v_found THEN
                    INSERT INTO public.cash_accounts (organization_id, branch_id, name, kind, created_by, updated_by)
                    VALUES (p_org, v_branch, v_name, v_kind::public.cash_account_kind, p_emp, p_emp)
                    RETURNING * INTO v_a;
                    INSERT INTO public.audit_log (organization_id, branch_id, employee_id, action, entity_type, entity_id, severity, after)
                    VALUES (p_org, v_branch, p_emp, 'cash_account.created', 'cash_account', v_a.id, 'info',
                            jsonb_build_object('name', v_name, 'kind', v_kind, 'import_job_id', p_job));
                END IF;
                IF v_balance > 0 THEN
                    INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, amount, type, source_type,
                                                       source_id, note, business_date, created_by, created_at)
                    VALUES (p_org, v_a.id, v_book_branch, v_balance, 'opening', 'import', p_job,
                            'Opening balance (import)', app.org_today(p_org), p_emp, clock_timestamp());
                    INSERT INTO public.audit_log (organization_id, branch_id, employee_id, action, entity_type, entity_id, severity, after)
                    VALUES (p_org, v_branch, p_emp, 'cash_account.opening_balance', 'cash_account', v_a.id, 'info',
                            jsonb_build_object('amount', v_balance::text, 'import_job_id', p_job));
                END IF;
            END IF;

            v_total := v_total + v_balance;
            IF v_action = 'create' THEN v_create := v_create + 1; v_new_accounts := v_new_accounts + 1;
            ELSE v_update := v_update + 1; END IF;
            IF jsonb_array_length(v_preview) < 20 THEN
                v_preview := v_preview || jsonb_build_array(jsonb_build_object('row', r.rn, 'action', v_action, 'values', v));
            END IF;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            v_err := v_err + 1;
            IF v_err <= 5000 THEN
                v_errors := v_errors || jsonb_build_array(app.import_error(r.rn, 'opening_cash', v_state, v_msg));
            END IF;
        END;
    END LOOP;
    RETURN jsonb_build_object('errors', v_errors, 'errors_total', v_err,
        'actions', jsonb_build_object('create', v_create, 'update', v_update, 'unchanged', v_same),
        'preview', v_preview, 'will_create_categories', '[]'::jsonb, 'warnings', '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION app.import_opening_contracts(uuid, uuid, jsonb, boolean, uuid),
    app.import_opening_cash(uuid, uuid, jsonb, boolean, uuid)
    FROM PUBLIC, anon, authenticated;

-- 6. Create, list and run: M01's functions with the two kinds ------------------------------------------

CREATE OR REPLACE FUNCTION public.create_import(p_kind text, p_file_id uuid, p_branch_id uuid, p_rows jsonb, p_meta jsonb,
                                     p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_key text; v_job public.import_jobs; v_res jsonb; v_report jsonb; v_status public.import_status;
    v_failed integer; v_total integer; v_meta jsonb := COALESCE(p_meta, '{}'::jsonb);
BEGIN
    v_emp := app.require_permission('import.data');
    v_org := app.current_org_id();
    IF p_kind IS NULL OR p_kind NOT IN ('products', 'customers', 'suppliers', 'opening_stock', 'opening_contracts', 'opening_cash') THEN
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
    IF p_kind = 'opening_contracts' THEN
        PERFORM app.require_module('customers');
        PERFORM app.require_module('installments');
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

CREATE OR REPLACE FUNCTION public.list_import_jobs(p_filters jsonb DEFAULT '{}'::jsonb)
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
    IF v_kind IS NOT NULL AND v_kind NOT IN ('products', 'customers', 'suppliers', 'opening_stock', 'opening_contracts', 'opening_cash') THEN
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

CREATE OR REPLACE FUNCTION public.jobs_import_apply(p_job_id uuid, p_rows jsonb)
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
        IF v_job.kind = 'opening_contracts'
           AND NOT (app.org_has_module(v_org, 'customers') AND app.org_has_module(v_org, 'installments')) THEN
            RAISE EXCEPTION 'MODULE_NOT_IN_PLAN: installments';
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
                                   'unchanged', v_res #>> '{actions,unchanged}')
                    || CASE WHEN v_res ? 'summary' THEN jsonb_build_object('summary', v_res -> 'summary') ELSE '{}'::jsonb END);
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

-- 7. The contract answer carries migration_source (N02's body, one key added) -------------------------

CREATE OR REPLACE FUNCTION app.contract_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', c.id, 'number', c.number, 'status', c.status, 'branch_id', c.branch_id,
        'sale_id', c.sale_id, 'sale_number', s.number,
        'customer', jsonb_build_object('id', cu.id, 'name', cu.full_name, 'phone', cu.phones[1]),
        'guarantors', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', g.id, 'name', g.full_name, 'relation', cg.relation)
                             ORDER BY g.full_name, g.id)
            FROM public.contract_guarantors k
            JOIN public.guarantors g ON g.id = k.guarantor_id AND g.organization_id = k.organization_id
            LEFT JOIN public.customer_guarantors cg ON cg.guarantor_id = k.guarantor_id
                 AND cg.customer_id = c.customer_id AND cg.organization_id = k.organization_id
            WHERE k.organization_id = c.organization_id AND k.contract_id = c.id), '[]'::jsonb),
        'policy_version', p.version, 'creditor', c.creditor,
        'cash_price', c.cash_price::text, 'down_payment', c.down_payment::text,
        'financed_amount', c.financed_amount::text, 'markup_pct', trim_scale(c.markup_pct)::text,
        'markup_amount', c.markup_amount::text, 'total_payable', c.total_payable::text,
        'installments_count', c.installments_count, 'frequency', c.frequency,
        'first_due_date', c.first_due_date,
        'last_due_date', (SELECT max(l.due_date) FROM public.schedule_lines l
                          WHERE l.organization_id = c.organization_id AND l.contract_id = c.id
                            AND l.version = c.current_version),
        'current_version', c.current_version, 'credit_approval_id', c.credit_approval_id,
        'created_at', c.created_at, 'created_by_name', e.full_name, 'migration_source', c.migration_source,
        'lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'seq', ls.seq, 'due_date', ls.due_date, 'principal', ls.principal::text,
                'profit', ls.profit::text, 'amount', ls.amount::text, 'paid', ls.paid::text,
                'remaining', GREATEST(ls.remaining, 0)::numeric(18,2)::text, 'status', ls.status)
                ORDER BY ls.seq)
            FROM public.v_schedule_line_status ls
            WHERE ls.organization_id = c.organization_id AND ls.contract_id = c.id AND NOT ls.superseded), '[]'::jsonb),
        'balance', jsonb_build_object('paid', cb.paid::text, 'remaining', cb.remaining::text,
                                      'overdue', cb.overdue_amount::text))
    FROM public.contracts c
    JOIN public.customers cu ON cu.id = c.customer_id AND cu.organization_id = c.organization_id
    JOIN public.installment_policies p ON p.id = c.policy_id AND p.organization_id = c.organization_id
    JOIN public.v_contract_balances cb ON cb.contract_id = c.id AND cb.organization_id = c.organization_id
    LEFT JOIN public.sales s ON s.id = c.sale_id AND s.organization_id = c.organization_id
    LEFT JOIN public.employees e ON e.id = c.created_by AND e.organization_id = c.organization_id
    WHERE c.organization_id = p_org AND c.id = p_id
$$;

-- The customer account's contract rows carry migration_source too (R02's body, one key added).
CREATE OR REPLACE FUNCTION app.customer_contract_json(p_org uuid, p_contract_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', c.id, 'number', c.number, 'status', c.status,
        'branch', jsonb_build_object('id', b.id, 'name', b.name),
        'sale_id', c.sale_id, 'sale_number', s.number, 'issued_at', c.created_at,
        'is_migrated', c.is_migrated, 'migration_source', c.migration_source,
        'cash_price', c.cash_price::text, 'down_payment', c.down_payment::text,
        'financed_amount', c.financed_amount::text, 'markup_amount', c.markup_amount::text,
        'total_payable', c.total_payable::text,
        'contract_total', app.customer_contract_total(p_org, c.id)::text,
        'paid', cb.paid::text, 'remaining', cb.remaining::text, 'fees_due', cb.fees_due::text,
        'overdue_amount', cb.overdue_amount::text, 'overdue_lines', cb.overdue_lines,
        'max_days_late', cb.max_days_late, 'next_due_date', cb.next_due_date,
        'installments_count', c.installments_count, 'frequency', c.frequency,
        'first_due_date', c.first_due_date)
    FROM public.contracts c
    JOIN public.branches b ON b.id = c.branch_id AND b.organization_id = c.organization_id
    JOIN public.v_contract_balances cb ON cb.contract_id = c.id AND cb.organization_id = c.organization_id
    LEFT JOIN public.sales s ON s.id = c.sale_id AND s.organization_id = c.organization_id
    WHERE c.organization_id = p_org AND c.id = p_contract_id
$$;

-- 8. The reconciliation report, the sign-off and the reversal -----------------------------------------

CREATE FUNCTION app.migration_read_guard()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF app.current_employee_id() IS NULL OR app.current_org_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT (app.has_permission('import.data') OR app.has_permission('report.financial')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: import.data' USING ERRCODE = '42501';
    END IF;
    RETURN app.current_org_id();
END;
$$;

-- The first contract of a batch that a reversal must not touch (a collection, a contract change, a
-- legal case or an overdue action other than a warning), or NULL.
CREATE FUNCTION app.migration_batch_blocker(p_org uuid, p_job uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object('contract_id', c.id, 'number', c.number, 'reason', x.reason)
    FROM public.contracts c
    CROSS JOIN LATERAL (SELECT CASE
        WHEN EXISTS (SELECT 1 FROM public.payment_allocations pa
                     WHERE pa.organization_id = c.organization_id AND pa.contract_id = c.id) THEN 'collection'
        WHEN EXISTS (SELECT 1 FROM public.contract_changes cc
                     WHERE cc.organization_id = c.organization_id AND cc.contract_id = c.id) THEN 'contract_change'
        WHEN EXISTS (SELECT 1 FROM public.legal_cases lc
                     WHERE lc.organization_id = c.organization_id AND lc.contract_id = c.id) THEN 'legal_case'
        WHEN EXISTS (SELECT 1 FROM public.overdue_actions oa
                     WHERE oa.organization_id = c.organization_id AND oa.contract_id = c.id
                       AND oa.kind <> 'warning') THEN 'overdue_action'
        END AS reason) x
    WHERE c.organization_id = p_org AND c.migration_batch_id = p_job
      AND (c.migration_source ->> 'reversed') IS DISTINCT FROM 'true' AND x.reason IS NOT NULL
    ORDER BY c.number LIMIT 1
$$;

-- A contracts batch is reversed when it has contracts and all of them are marked reversed (a
-- completed import job is a frozen document, so the flag lives on the contracts).
CREATE FUNCTION app.migration_batch_reversed(p_org uuid, p_job uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(bool_and((c.migration_source ->> 'reversed') = 'true'), false)
    FROM public.contracts c WHERE c.organization_id = p_org AND c.migration_batch_id = p_job
$$;

-- One batch (an import job of the two kinds) as the report lists it.
CREATE FUNCTION app.migration_batch_json(p_org uuid, j public.import_jobs)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_contracts integer; v_total numeric; v_cash numeric; v_signoff uuid; v_blocker jsonb; v_reversed boolean;
BEGIN
    v_reversed := app.migration_batch_reversed(p_org, j.id);
    SELECT count(*), COALESCE(sum(c.total_payable), 0) INTO v_contracts, v_total
    FROM public.contracts c
    WHERE c.organization_id = p_org AND c.migration_batch_id = j.id;
    SELECT COALESCE(sum(m.amount), 0) INTO v_cash
    FROM public.cash_movements m
    WHERE m.organization_id = p_org AND m.type = 'opening' AND m.source_type = 'import' AND m.source_id = j.id;
    SELECT s.id INTO v_signoff FROM public.migration_signoffs s
    WHERE s.organization_id = p_org AND j.id = ANY (s.batch_ids) LIMIT 1;
    v_blocker := app.migration_batch_blocker(p_org, j.id);
    RETURN jsonb_build_object(
        'id', j.id, 'kind', j.kind, 'created_at', j.created_at,
        'file_name', (SELECT f.original_name FROM public.files f WHERE f.id = j.file_id AND f.organization_id = p_org),
        'contracts', v_contracts, 'imported_total', v_total::numeric(18,2)::text,
        'cash_total', v_cash::numeric(18,2)::text,
        'reversed', v_reversed, 'signoff_id', v_signoff,
        'can_reverse', j.kind = 'opening_contracts' AND NOT v_reversed AND v_signoff IS NULL AND v_blocker IS NULL
                       AND v_contracts > 0,
        'blocker', v_blocker);
END;
$$;

-- import.data or report.financial; also in an expired shop. p_filters: batch_id, branch_id, customer_id.
CREATE FUNCTION public.get_migration_report(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; v_f jsonb := COALESCE(p_filters, '{}'::jsonb); v_key text; v_batch uuid; v_branch uuid; v_customer uuid;
    v_pii boolean; v_rows jsonb; v_totals jsonb; v_customers jsonb; v_branches jsonb; v_cash jsonb; v_batches jsonb; v_n integer;
BEGIN
    v_org := app.migration_read_guard();
    IF jsonb_typeof(v_f) <> 'object' THEN RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001'; END IF;
    SELECT k INTO v_key FROM jsonb_object_keys(v_f) k WHERE k <> ALL (ARRAY['batch_id', 'branch_id', 'customer_id']) LIMIT 1;
    IF v_key IS NOT NULL THEN RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001'; END IF;
    FOREACH v_key IN ARRAY ARRAY['batch_id', 'branch_id', 'customer_id'] LOOP
        IF v_f ? v_key AND (jsonb_typeof(v_f -> v_key) <> 'string'
                            OR (v_f ->> v_key) !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    v_batch := (v_f ->> 'batch_id')::uuid; v_branch := (v_f ->> 'branch_id')::uuid; v_customer := (v_f ->> 'customer_id')::uuid;
    IF v_batch IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public.import_jobs j WHERE j.id = v_batch AND j.organization_id = v_org
              AND j.kind IN ('opening_contracts', 'opening_cash') AND j.report ? 'columns') THEN
        RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_branch IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = v_branch AND b.organization_id = v_org) THEN
            RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        PERFORM app.require_branch_access(v_branch);
    END IF;
    IF v_customer IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public.customers c WHERE c.id = v_customer AND c.organization_id = v_org) THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    v_pii := app.has_permission('customer.view_pii');

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'customer_id', c.customer_id, 'branch_id', c.branch_id,
               'original_total', (c.migration_source ->> 'original_total')::numeric,
               'paid_before', (c.migration_source ->> 'paid_before')::numeric,
               'imported_total', c.total_payable,
               'open_now', CASE WHEN c.status IN ('active', 'rescheduled') THEN cb.remaining ELSE 0 END,
               'overdue_now', CASE WHEN c.status IN ('active', 'rescheduled') THEN cb.overdue_amount ELSE 0 END,
               'collected_since', cb.paid)), '[]'::jsonb)
    INTO v_rows
    FROM public.contracts c
    JOIN public.v_contract_balances cb ON cb.contract_id = c.id AND cb.organization_id = c.organization_id
    WHERE c.organization_id = v_org AND c.is_migrated AND c.migration_source IS NOT NULL
      AND (c.migration_source ->> 'reversed') IS DISTINCT FROM 'true'
      AND (v_batch IS NULL OR c.migration_batch_id = v_batch)
      AND (v_branch IS NULL OR c.branch_id = v_branch)
      AND (v_customer IS NULL OR c.customer_id = v_customer)
      AND app.has_branch_access(c.branch_id);

    SELECT jsonb_build_object(
        'contracts', count(*), 'original_total', COALESCE(sum(original_total), 0)::numeric(18,2)::text,
        'paid_before', COALESCE(sum(paid_before), 0)::numeric(18,2)::text,
        'imported_total', COALESCE(sum(imported_total), 0)::numeric(18,2)::text,
        'open_now', COALESCE(sum(open_now), 0)::numeric(18,2)::text,
        'overdue_now', COALESCE(sum(overdue_now), 0)::numeric(18,2)::text,
        'collected_since', COALESCE(sum(collected_since), 0)::numeric(18,2)::text)
    INTO v_totals FROM jsonb_to_recordset(v_rows) AS r(customer_id uuid, branch_id uuid, original_total numeric, paid_before numeric, imported_total numeric, open_now numeric, overdue_now numeric, collected_since numeric);

    SELECT count(DISTINCT r.customer_id) INTO v_n FROM jsonb_to_recordset(v_rows) AS r(customer_id uuid, branch_id uuid, original_total numeric, paid_before numeric, imported_total numeric, open_now numeric, overdue_now numeric, collected_since numeric);
    SELECT COALESCE(jsonb_agg(t.j ORDER BY t.name, t.cid), '[]'::jsonb) INTO v_customers FROM (
        SELECT cu.full_name AS name, cu.id AS cid, jsonb_build_object(
            'customer_id', cu.id, 'name', cu.full_name,
            'national_id', CASE WHEN cu.national_id IS NULL THEN NULL WHEN v_pii THEN cu.national_id
                                ELSE app.mask_national_id(cu.national_id) END,
            'contracts', count(*), 'original_total', sum(r.original_total)::numeric(18,2)::text,
            'paid_before', sum(r.paid_before)::numeric(18,2)::text, 'imported_total', sum(r.imported_total)::numeric(18,2)::text,
            'open_now', sum(r.open_now)::numeric(18,2)::text, 'overdue_now', sum(r.overdue_now)::numeric(18,2)::text,
            'collected_since', sum(r.collected_since)::numeric(18,2)::text) AS j
        FROM jsonb_to_recordset(v_rows) AS r(customer_id uuid, branch_id uuid, original_total numeric, paid_before numeric, imported_total numeric, open_now numeric, overdue_now numeric, collected_since numeric) JOIN public.customers cu ON cu.id = r.customer_id AND cu.organization_id = v_org
        GROUP BY cu.id, cu.full_name, cu.national_id
        ORDER BY cu.full_name, cu.id LIMIT 2000) t;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'branch_id', b.id, 'name', b.name, 'contracts', x.n, 'original_total', x.orig::numeric(18,2)::text,
            'paid_before', x.paid::numeric(18,2)::text, 'imported_total', x.imp::numeric(18,2)::text,
            'open_now', x.open::numeric(18,2)::text, 'overdue_now', x.od::numeric(18,2)::text,
            'collected_since', x.coll::numeric(18,2)::text) ORDER BY b.name, b.id), '[]'::jsonb)
    INTO v_branches
    FROM (SELECT r.branch_id, count(*) AS n, sum(r.original_total) AS orig, sum(r.paid_before) AS paid,
                 sum(r.imported_total) AS imp, sum(r.open_now) AS open, sum(r.overdue_now) AS od,
                 sum(r.collected_since) AS coll
          FROM jsonb_to_recordset(v_rows) AS r(customer_id uuid, branch_id uuid, original_total numeric, paid_before numeric, imported_total numeric, open_now numeric, overdue_now numeric, collected_since numeric) GROUP BY r.branch_id) x
    JOIN public.branches b ON b.id = x.branch_id AND b.organization_id = v_org;

    IF v_customer IS NULL THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'account_id', a.id, 'name', a.name, 'kind', a.kind, 'branch_id', a.branch_id, 'branch_name', br.name,
                'opening_posted', y.opening::numeric(18,2)::text, 'balance_now', COALESCE(cb.balance, 0)::numeric(18,2)::text)
                ORDER BY a.name, a.id), '[]'::jsonb)
        INTO v_cash
        FROM (SELECT m.cash_account_id, sum(m.amount) AS opening FROM public.cash_movements m
              WHERE m.organization_id = v_org AND m.type = 'opening' AND m.source_type = 'import'
                AND (v_batch IS NULL OR m.source_id = v_batch)
              GROUP BY m.cash_account_id) y
        JOIN public.cash_accounts a ON a.id = y.cash_account_id AND a.organization_id = v_org
        LEFT JOIN public.cash_balances cb ON cb.cash_account_id = a.id
        LEFT JOIN public.branches br ON br.id = a.branch_id AND br.organization_id = v_org
        WHERE (v_branch IS NULL OR a.branch_id = v_branch)
          AND (a.branch_id IS NULL OR app.has_branch_access(a.branch_id));
    ELSE
        v_cash := '[]'::jsonb;
    END IF;

    SELECT COALESCE(jsonb_agg(app.migration_batch_json(v_org, s.j) ORDER BY s.created_at DESC, s.id), '[]'::jsonb)
    INTO v_batches
    FROM (SELECT j, j.created_at, j.id FROM public.import_jobs j
          WHERE j.organization_id = v_org AND j.kind IN ('opening_contracts', 'opening_cash') AND j.status = 'completed'
            AND j.report ? 'columns' AND (v_batch IS NULL OR j.id = v_batch)
          ORDER BY j.created_at DESC, j.id LIMIT 50) s;

    RETURN jsonb_build_object(
        'as_of', app.org_today(v_org),
        'filters', jsonb_strip_nulls(jsonb_build_object('batch_id', v_batch, 'branch_id', v_branch, 'customer_id', v_customer)),
        'totals', v_totals || jsonb_build_object('customers', v_n),
        'customers', v_customers, 'branches', v_branches, 'batches', v_batches,
        'cash', v_cash,
        'cash_totals', jsonb_build_object(
            'opening_posted', COALESCE((SELECT sum((e ->> 'opening_posted')::numeric) FROM jsonb_array_elements(v_cash) e), 0)::numeric(18,2)::text,
            'balance_now', COALESCE((SELECT sum((e ->> 'balance_now')::numeric) FROM jsonb_array_elements(v_cash) e), 0)::numeric(18,2)::text));
END;
$$;

CREATE FUNCTION app.migration_signoff_json(s public.migration_signoffs)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', s.id, 'batch_ids', to_jsonb(s.batch_ids),
        'expected_open_total', s.expected_open_total::text, 'system_open_total', s.system_open_total::text,
        'expected_cash_total', s.expected_cash_total::text, 'system_cash_total', s.system_cash_total::text,
        'note', s.note, 'signed_file_id', s.signed_file_id,
        'signed_by', (SELECT jsonb_build_object('id', e.id, 'name', e.full_name) FROM public.employees e
                      WHERE e.id = s.signed_by AND e.organization_id = s.organization_id),
        'signed_at', s.signed_at)
$$;

-- import.data. The body is {expected_open_total, expected_cash_total?, batch_ids, note, signed_file_id?}.
-- The system's total is what the batches IMPORTED (the frozen total of their contracts, not what is
-- left after collections). Any difference -> MIGRATION_TOTAL_MISMATCH and nothing is stored.
CREATE FUNCTION public.sign_off_migration(p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_key text; v_expected numeric(18,2); v_expected_cash numeric(18,2); v_ids uuid[];
    v_note text; v_file uuid; v_found integer; v_open numeric(18,2); v_cash numeric(18,2); v_signed uuid;
    v_row public.migration_signoffs;
BEGIN
    v_emp := app.require_permission('import.data');
    v_org := app.current_org_id();
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT k INTO v_key FROM jsonb_object_keys(p_body) k
    WHERE k <> ALL (ARRAY['expected_open_total', 'expected_cash_total', 'batch_ids', 'note', 'signed_file_id']) LIMIT 1;
    IF v_key IS NOT NULL THEN RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001'; END IF;
    IF jsonb_typeof(p_body -> 'expected_open_total') IS DISTINCT FROM 'string'
       OR (p_body ->> 'expected_open_total') !~ '^[0-9]{1,16}(\.[0-9]{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: expected_open_total' USING ERRCODE = 'P0001';
    END IF;
    v_expected := (p_body ->> 'expected_open_total')::numeric(18,2);
    IF p_body ? 'expected_cash_total' AND jsonb_typeof(p_body -> 'expected_cash_total') <> 'null' THEN
        IF jsonb_typeof(p_body -> 'expected_cash_total') <> 'string'
           OR (p_body ->> 'expected_cash_total') !~ '^[0-9]{1,16}(\.[0-9]{1,2})?$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: expected_cash_total' USING ERRCODE = 'P0001';
        END IF;
        v_expected_cash := (p_body ->> 'expected_cash_total')::numeric(18,2);
    END IF;
    IF jsonb_typeof(p_body -> 'batch_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(p_body -> 'batch_ids') NOT BETWEEN 1 AND 50
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_body -> 'batch_ids') e
                  WHERE jsonb_typeof(e) <> 'string'
                     OR (e #>> '{}') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: batch_ids' USING ERRCODE = 'P0001';
    END IF;
    SELECT array_agg(DISTINCT (e #>> '{}')::uuid) INTO v_ids FROM jsonb_array_elements(p_body -> 'batch_ids') e;
    IF cardinality(v_ids) <> jsonb_array_length(p_body -> 'batch_ids') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: batch_ids' USING ERRCODE = 'P0001';
    END IF;
    IF jsonb_typeof(p_body -> 'note') IS DISTINCT FROM 'string' OR length(btrim(p_body ->> 'note')) NOT BETWEEN 3 AND 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: note' USING ERRCODE = 'P0001';
    END IF;
    v_note := btrim(p_body ->> 'note');
    IF p_body ? 'signed_file_id' AND jsonb_typeof(p_body -> 'signed_file_id') <> 'null' THEN
        IF jsonb_typeof(p_body -> 'signed_file_id') <> 'string'
           OR (p_body ->> 'signed_file_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: signed_file_id' USING ERRCODE = 'P0001';
        END IF;
        v_file := (p_body ->> 'signed_file_id')::uuid;
        IF NOT EXISTS (SELECT 1 FROM public.files f WHERE f.id = v_file AND f.organization_id = v_org AND f.purpose = 'other') THEN
            RAISE EXCEPTION 'FILE_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    -- The batches, locked in id order (a reversal takes the same lock).
    PERFORM 1 FROM public.import_jobs j WHERE j.id = ANY (v_ids) AND j.organization_id = v_org ORDER BY j.id FOR UPDATE;
    SELECT count(*) INTO v_found FROM public.import_jobs j
    WHERE j.id = ANY (v_ids) AND j.organization_id = v_org AND j.kind IN ('opening_contracts', 'opening_cash')
      AND j.report ? 'columns';
    IF v_found <> cardinality(v_ids) THEN
        RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.import_jobs j WHERE j.id = ANY (v_ids) AND j.organization_id = v_org
                 AND (j.status <> 'completed' OR app.migration_batch_reversed(v_org, j.id))) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: batch_ids' USING ERRCODE = 'P0001';
    END IF;
    SELECT s.id INTO v_signed FROM public.migration_signoffs s
    WHERE s.organization_id = v_org AND s.batch_ids && v_ids LIMIT 1;
    IF v_signed IS NOT NULL THEN
        RAISE EXCEPTION 'MIGRATION_SIGNED_OFF' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('signoff_id', v_signed)::text;
    END IF;

    SELECT COALESCE(sum(c.total_payable), 0) INTO v_open FROM public.contracts c
    WHERE c.organization_id = v_org AND c.migration_batch_id = ANY (v_ids)
      AND (c.migration_source ->> 'reversed') IS DISTINCT FROM 'true';
    SELECT COALESCE(sum(m.amount), 0) INTO v_cash FROM public.cash_movements m
    WHERE m.organization_id = v_org AND m.type = 'opening' AND m.source_type = 'import' AND m.source_id = ANY (v_ids);

    IF v_expected <> v_open THEN
        RAISE EXCEPTION 'MIGRATION_TOTAL_MISMATCH' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('field', 'open_total', 'expected', v_expected::text, 'system', v_open::text,
                                        'difference', (v_expected - v_open)::text)::text;
    END IF;
    IF v_expected_cash IS NOT NULL AND v_expected_cash <> v_cash THEN
        RAISE EXCEPTION 'MIGRATION_TOTAL_MISMATCH' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('field', 'cash_total', 'expected', v_expected_cash::text, 'system', v_cash::text,
                                        'difference', (v_expected_cash - v_cash)::text)::text;
    END IF;

    INSERT INTO public.migration_signoffs (organization_id, batch_ids, expected_open_total, system_open_total,
                                           expected_cash_total, system_cash_total, note, signed_file_id, signed_by)
    VALUES (v_org, v_ids, v_expected, v_open, v_expected_cash, v_cash, v_note, v_file, v_emp)
    RETURNING * INTO v_row;
    PERFORM app.write_audit('migration.signed_off', 'migration_signoff', v_row.id, NULL,
        jsonb_build_object('batch_ids', to_jsonb(v_ids), 'open_total', v_open::text, 'cash_total', v_cash::text,
                           'signed_file_id', v_file), v_note, NULL, 'warning');
    RETURN app.migration_signoff_json(v_row);
END;
$$;

CREATE FUNCTION public.list_migration_signoffs()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    v_org := app.migration_read_guard();
    RETURN jsonb_build_object('items', COALESCE((
        SELECT jsonb_agg(app.migration_signoff_json(s) ORDER BY s.signed_at DESC, s.id)
        FROM (SELECT * FROM public.migration_signoffs x WHERE x.organization_id = v_org
              ORDER BY x.signed_at DESC, x.id LIMIT 100) s), '[]'::jsonb));
END;
$$;

-- import.data. Before any collection, contract change or sign-off: every contract of the batch is
-- closed through N05's write-off record (the contract is never deleted) and marked reversed (on the
-- contract: the completed import job is frozen); the
-- report leaves it out and its contract number can be imported again. The batch's opening cash is
-- not touched (a K01 transfer moves that money).
CREATE FUNCTION public.reverse_migration_batch(p_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_reason text; v_job public.import_jobs; v_signed uuid; v_blocker jsonb; c record;
    v_left record; v_n integer := 0;
BEGIN
    v_emp := app.require_permission('import.data');
    v_org := app.current_org_id();
    v_reason := btrim(p_reason);
    IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 300 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_job FROM public.import_jobs j
    WHERE j.id = p_id AND j.organization_id = v_org AND j.kind = 'opening_contracts' AND j.report ? 'columns' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF app.migration_batch_reversed(v_org, p_id) THEN
        RETURN jsonb_build_object('job', app.import_job_json(v_job),
            'reversed_contracts', (SELECT count(*) FROM public.contracts x
                                   WHERE x.organization_id = v_org AND x.migration_batch_id = p_id));
    END IF;
    IF v_job.status <> 'completed' THEN
        RAISE EXCEPTION 'MIGRATION_NOT_REVERSIBLE' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('reason', 'not_completed')::text;
    END IF;
    SELECT s.id INTO v_signed FROM public.migration_signoffs s
    WHERE s.organization_id = v_org AND p_id = ANY (s.batch_ids) LIMIT 1;
    IF v_signed IS NOT NULL THEN
        RAISE EXCEPTION 'MIGRATION_SIGNED_OFF' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('signoff_id', v_signed)::text;
    END IF;
    v_blocker := app.migration_batch_blocker(v_org, p_id);
    IF v_blocker IS NOT NULL THEN
        RAISE EXCEPTION 'MIGRATION_NOT_REVERSIBLE' USING ERRCODE = 'P0001', DETAIL = v_blocker::text;
    END IF;

    FOR c IN SELECT k.* FROM public.contracts k
             WHERE k.organization_id = v_org AND k.migration_batch_id = p_id
               AND (k.migration_source ->> 'reversed') IS DISTINCT FROM 'true'
             ORDER BY k.id FOR UPDATE
    LOOP
        SELECT * INTO v_left FROM app.contract_left(v_org, c.id);
        INSERT INTO public.contract_changes (organization_id, contract_id, kind, old_version, amount, principal_amount,
                                             profit_amount, reason, approved_by, idempotency_key, branch_id, business_date,
                                             created_at, created_by)
        VALUES (v_org, c.id, 'write_off', c.current_version, v_left.principal_left + v_left.profit_left,
                v_left.principal_left, v_left.profit_left, left('Migration batch reversed: ' || v_reason, 500), v_emp,
                'm02rev:' || c.id::text, c.branch_id, app.org_today(v_org), clock_timestamp(), v_emp);
        UPDATE public.contracts k
        SET status = 'written_off', closed_at = now(), updated_at = now(), updated_by = v_emp,
            migration_source = k.migration_source || jsonb_build_object('reversed', true)
        WHERE k.id = c.id;
        v_n := v_n + 1;
    END LOOP;
    PERFORM app.write_audit('migration.batch_reversed', 'import_job', p_id, NULL,
        jsonb_build_object('contracts', v_n), v_reason, NULL, 'warning');
    RETURN jsonb_build_object('job', app.import_job_json(v_job), 'reversed_contracts', v_n);
END;
$$;

-- 9. Grants -------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.migration_read_guard(), app.migration_batch_blocker(uuid, uuid), app.migration_batch_reversed(uuid, uuid),
    app.migration_batch_json(uuid, public.import_jobs), app.migration_signoff_json(public.migration_signoffs)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_migration_report(jsonb), public.sign_off_migration(jsonb),
    public.list_migration_signoffs(), public.reverse_migration_batch(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_migration_report(jsonb), public.sign_off_migration(jsonb),
    public.list_migration_signoffs(), public.reverse_migration_batch(uuid, text) TO authenticated;
