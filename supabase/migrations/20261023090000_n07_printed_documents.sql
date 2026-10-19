-- N07 printed contract and promissory notes (EC-86, D82).
-- The client draws the contract and the promissory notes (كمبيالات) from one read, get_contract_documents,
-- whose figures are the contract's own (no money arithmetic in the browser). Every print is logged in
-- the audit log, per document and schedule version: print 1 is the original, later ones copies.
-- The owner edits the terms text in settings; wording the Islamic finance rules forbid is refused.
-- No new permission key and no new enum value (an older Web build rejects unknown ones).

-- 1. Settings: the terms text and the notes mode -----------------------------------------------------

ALTER TABLE public.org_settings
    ADD COLUMN contract_terms        text CHECK (contract_terms IS NULL OR length(contract_terms) BETWEEN 1 AND 20000),
    ADD COLUMN promissory_notes_mode text NOT NULL DEFAULT 'per_installment'
        CHECK (promissory_notes_mode IN ('per_installment', 'single'));

-- The placeholders a terms text may use and the wording it may not (rules 3, 4, 6). The same lists
-- are exported by the contracts package (CONTRACT_TEMPLATE_PLACEHOLDERS / _FORBIDDEN_WORDS); a unit
-- test compares them with this text. Words are matched case-insensitively after removing Arabic
-- diacritics (U+064B to U+065F, U+0670, tatweel U+0640).
CREATE FUNCTION app.contract_template_problems(p_text text)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    WITH placeholders(name) AS (
        VALUES ('shop_name'), ('shop_legal_name'), ('commercial_register'), ('branch_name'), ('city'),
               ('contract_number'), ('contract_date'), ('customer_name'), ('customer_national_id'),
               ('installment_price'), ('installment_price_words'), ('down_payment'),
               ('installments_count'), ('frequency'), ('first_due_date'), ('last_due_date')
    ), forbidden(ord, word) AS (
        VALUES (1, 'فائدة'), (2, 'فوائد'), (3, 'سعر الفائدة'), (4, 'قرض'), (5, 'غرامة'), (6, 'غرامات'),
               (7, 'غرامة تأخير'), (8, 'خصم السداد المبكر'), (9, 'interest'), (10, 'loan'),
               (11, 'late fee'), (12, 'penalty')
    ), found AS (
        SELECT btrim(m.parts[1]) AS name, m.ord
        FROM regexp_matches(p_text, '\{\{([^{}]*)\}\}', 'g') WITH ORDINALITY AS m(parts, ord)
    )
    SELECT jsonb_build_object(
        'unknown', COALESCE((
            SELECT jsonb_agg(f.name ORDER BY f.first_ord)
            FROM (SELECT x.name, min(x.ord) AS first_ord FROM found x
                  WHERE x.name NOT IN (SELECT name FROM placeholders) GROUP BY x.name) f), '[]'::jsonb),
        'words', COALESCE((
            SELECT jsonb_agg(w.word ORDER BY w.ord) FROM forbidden w
            WHERE position(w.word IN lower(regexp_replace(p_text, '[ً-ٰٟـ]', '', 'g'))) > 0),
            '[]'::jsonb))
$$;
REVOKE ALL ON FUNCTION app.contract_template_problems(text) FROM PUBLIC, anon, authenticated;

-- GET /api/settings answers the two new fields next to the existing ones.
ALTER FUNCTION public.get_shop_settings() RENAME TO get_shop_settings_t01;
REVOKE ALL ON FUNCTION public.get_shop_settings_t01() FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.get_shop_settings()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    RETURN public.get_shop_settings_t01() || (
        SELECT jsonb_build_object('contract_terms', s.contract_terms,
                                  'promissory_notes_mode', s.promissory_notes_mode)
        FROM public.org_settings s WHERE s.organization_id = app.current_org_id());
END;
$$;
REVOKE ALL ON FUNCTION public.get_shop_settings() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_shop_settings() TO authenticated;

-- PATCH /api/settings takes the two new fields; everything else goes to the earlier function.
ALTER FUNCTION public.update_org_settings(jsonb) RENAME TO update_org_settings_p04;
REVOKE ALL ON FUNCTION public.update_org_settings_p04(jsonb) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.update_org_settings(p_changes jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_rest jsonb; v_problems jsonb; v_old jsonb; v_new jsonb; v_before jsonb; v_after jsonb;
BEGIN
    v_emp := app.require_permission('org.settings_manage');
    v_org := app.current_org_id();
    IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' THEN
        RAISE EXCEPTION 'SETTINGS_INVALID: body' USING ERRCODE = 'P0001';
    END IF;
    v_rest := p_changes - 'contract_terms' - 'promissory_notes_mode';

    IF p_changes ? 'contract_terms' AND jsonb_typeof(p_changes -> 'contract_terms') NOT IN ('string', 'null') THEN
        RAISE EXCEPTION 'SETTINGS_INVALID: contract_terms' USING ERRCODE = 'P0001';
    END IF;
    IF p_changes ? 'contract_terms' AND length(p_changes ->> 'contract_terms') > 20000 THEN
        RAISE EXCEPTION 'SETTINGS_INVALID: contract_terms' USING ERRCODE = 'P0001';
    END IF;
    IF p_changes ? 'promissory_notes_mode'
       AND NOT COALESCE((p_changes ->> 'promissory_notes_mode') = ANY (ARRAY['per_installment', 'single']), false) THEN
        RAISE EXCEPTION 'SETTINGS_INVALID: promissory_notes_mode' USING ERRCODE = 'P0001';
    END IF;
    IF p_changes ? 'contract_terms' AND NULLIF(btrim(p_changes ->> 'contract_terms'), '') IS NOT NULL THEN
        v_problems := app.contract_template_problems(p_changes ->> 'contract_terms');
        IF jsonb_array_length(v_problems -> 'words') > 0 THEN
            RAISE EXCEPTION 'TEMPLATE_NOT_ALLOWED' USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('words', v_problems -> 'words')::text;
        END IF;
        IF jsonb_array_length(v_problems -> 'unknown') > 0 THEN
            RAISE EXCEPTION 'TEMPLATE_INVALID' USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('unknown', v_problems -> 'unknown')::text;
        END IF;
    END IF;

    IF v_rest <> '{}'::jsonb OR NOT (p_changes ? 'contract_terms' OR p_changes ? 'promissory_notes_mode') THEN
        PERFORM public.update_org_settings_p04(v_rest);
    END IF;

    IF p_changes ? 'contract_terms' OR p_changes ? 'promissory_notes_mode' THEN
        SELECT jsonb_build_object('contract_terms', s.contract_terms, 'promissory_notes_mode', s.promissory_notes_mode)
        INTO v_old FROM public.org_settings s WHERE s.organization_id = v_org FOR UPDATE;
        UPDATE public.org_settings SET
            contract_terms = CASE WHEN p_changes ? 'contract_terms'
                                  THEN NULLIF(btrim(p_changes ->> 'contract_terms'), '') ELSE contract_terms END,
            promissory_notes_mode = CASE WHEN p_changes ? 'promissory_notes_mode'
                                         THEN p_changes ->> 'promissory_notes_mode' ELSE promissory_notes_mode END,
            updated_by = v_emp
        WHERE organization_id = v_org;
        SELECT jsonb_build_object('contract_terms', s.contract_terms, 'promissory_notes_mode', s.promissory_notes_mode)
        INTO v_new FROM public.org_settings s WHERE s.organization_id = v_org;
        SELECT jsonb_object_agg(k, v_old -> k), jsonb_object_agg(k, v_new -> k) INTO v_before, v_after
        FROM jsonb_object_keys(v_new) k WHERE (v_old -> k) IS DISTINCT FROM (v_new -> k);
        IF v_after IS NOT NULL THEN
            PERFORM app.write_audit('org.settings_updated', 'organization', v_org, p_before => v_before, p_after => v_after);
        END IF;
    END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.update_org_settings(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_org_settings(jsonb) TO authenticated;

-- 2. The documents read ---------------------------------------------------------------------------------

-- Who may print (owner decision 1): installment.create (the person who makes the sale) or
-- customer.view_pii. The answer carries full national IDs, so it is never cached by the Web.
CREATE FUNCTION app.can_print_contract_documents()
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$ SELECT app.has_permission('installment.create') OR app.has_permission('customer.view_pii') $$;
REVOKE ALL ON FUNCTION app.can_print_contract_documents() FROM PUBLIC, anon, authenticated;

-- How many times a document of a contract was printed for a schedule version.
CREATE FUNCTION app.contract_document_prints(p_org uuid, p_contract_id uuid, p_document text, p_version integer)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT count(*)::integer FROM public.audit_log a
    WHERE a.organization_id = p_org AND a.entity_type = 'contract' AND a.entity_id = p_contract_id
      AND a.action = 'contract.document_printed'
      AND a.after ->> 'document' = p_document AND (a.after ->> 'version')::integer = p_version
$$;
REVOKE ALL ON FUNCTION app.contract_document_prints(uuid, uuid, text, integer) FROM PUBLIC, anon, authenticated;

-- GET /api/contracts/:id/documents: everything the contract and the notes print (docs/tasks/N07.md).
-- The cash price is left out on purpose (rule 1: only the installment price is on the paper), so the
-- goods carry names and quantities, not their cash line totals.
CREATE FUNCTION public.get_contract_documents(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; c public.contracts; o public.organizations; s public.org_settings; b public.branches;
    v_date date; v_today date; v_place text; v_issue date; v_notes jsonb := '[]'::jsonb; v_prev integer;
    v_replaces jsonb;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.can_print_contract_documents() THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: installment.create or customer.view_pii' USING ERRCODE = '42501';
    END IF;
    PERFORM app.require_module('installments');
    v_org := app.current_org_id();
    SELECT * INTO c FROM public.contracts k WHERE k.organization_id = v_org AND k.id = p_id;
    IF NOT FOUND OR NOT app.can_see_contract(c.branch_id) THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO o FROM public.organizations x WHERE x.id = v_org;
    SELECT * INTO s FROM public.org_settings x WHERE x.organization_id = v_org;
    SELECT * INTO b FROM public.branches x WHERE x.id = c.branch_id AND x.organization_id = v_org;
    v_today := app.org_today(v_org);
    v_date := COALESCE((SELECT sa.business_date FROM public.sales sa WHERE sa.id = c.sale_id AND sa.organization_id = v_org),
                       (c.created_at AT TIME ZONE o.timezone)::date);
    v_place := COALESCE(NULLIF(btrim(b.city), ''), NULLIF(btrim(b.address), ''));
    v_issue := CASE WHEN c.current_version = 1 THEN v_date ELSE v_today END;

    IF c.status IN ('active', 'rescheduled') THEN
        IF s.promissory_notes_mode = 'single' THEN
            SELECT COALESCE(jsonb_agg(jsonb_build_object('number', c.number || '-T', 'seq', NULL, 'amount', t.total::text,
                       'due_date', t.last_due, 'place', v_place, 'issue_date', v_issue)), '[]'::jsonb)
            INTO v_notes
            FROM (SELECT sum(GREATEST(ls.remaining, 0))::numeric(18,2) AS total, max(ls.due_date) AS last_due
                  FROM public.v_schedule_line_status ls
                  WHERE ls.organization_id = v_org AND ls.contract_id = c.id AND NOT ls.superseded
                    AND ls.version = c.current_version AND ls.remaining > 0
                  HAVING count(*) > 0) t;
        ELSE
            SELECT COALESCE(jsonb_agg(jsonb_build_object('number', c.number || '-' || ls.seq, 'seq', ls.seq,
                       'amount', ls.remaining::numeric(18,2)::text, 'due_date', ls.due_date, 'place', v_place,
                       'issue_date', v_issue) ORDER BY ls.seq), '[]'::jsonb)
            INTO v_notes
            FROM public.v_schedule_line_status ls
            WHERE ls.organization_id = v_org AND ls.contract_id = c.id AND NOT ls.superseded
              AND ls.version = c.current_version AND ls.remaining > 0;
        END IF;
    END IF;

    IF c.current_version > 1 THEN
        SELECT max(l.version) INTO v_prev FROM public.schedule_lines l
        WHERE l.organization_id = v_org AND l.contract_id = c.id AND l.version < c.current_version;
        v_replaces := jsonb_build_object('version', v_prev, 'date', CASE WHEN v_prev = 1 THEN v_date ELSE (
            SELECT COALESCE(ch.business_date, (ch.created_at AT TIME ZONE o.timezone)::date)
            FROM public.contract_changes ch
            WHERE ch.organization_id = v_org AND ch.contract_id = c.id AND ch.new_version = v_prev
            ORDER BY ch.created_at DESC LIMIT 1) END);
    END IF;

    RETURN jsonb_build_object(
        'contract', (app.contract_json(v_org, c.id) - 'cash_price' - 'customer' - 'guarantors')
                    || jsonb_build_object('contract_date', v_date),
        'customer', (SELECT jsonb_build_object('id', cu.id, 'name', cu.full_name, 'national_id', cu.national_id,
                         'address', cu.address, 'job', cu.job, 'phone', cu.phones[1])
                     FROM public.customers cu WHERE cu.id = c.customer_id AND cu.organization_id = v_org),
        'guarantors', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', g.id, 'name', g.full_name, 'relation', cg.relation,
                       'national_id', g.national_id, 'address', g.address, 'job', g.job, 'phone', g.phone)
                     ORDER BY g.full_name, g.id)
            FROM public.contract_guarantors k
            JOIN public.guarantors g ON g.id = k.guarantor_id AND g.organization_id = k.organization_id
            LEFT JOIN public.customer_guarantors cg ON cg.guarantor_id = k.guarantor_id
                 AND cg.customer_id = c.customer_id AND cg.organization_id = k.organization_id
            WHERE k.organization_id = v_org AND k.contract_id = c.id), '[]'::jsonb),
        'goods', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('name', p.name_ar, 'quantity', l.quantity) ORDER BY l.line_no)
            FROM public.sale_lines l
            JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
            WHERE l.organization_id = v_org AND l.sale_id = c.sale_id), '[]'::jsonb),
        'shop', jsonb_build_object('name', o.name, 'legal_name', o.legal_name,
                    'commercial_register', o.commercial_register, 'tax_registration_no', o.tax_registration_no,
                    'address', o.address, 'phone', o.phone, 'logo_file_id', o.logo_file_id,
                    'branch', jsonb_build_object('name', b.name, 'address', b.address, 'city', b.city, 'phone', b.phone)),
        'terms', jsonb_build_object('text', s.contract_terms, 'is_default', s.contract_terms IS NULL),
        'notes_mode', s.promissory_notes_mode,
        'notes', v_notes,
        'prints', jsonb_build_object(
            'contract', jsonb_build_object(
                'next_print_no', app.contract_document_prints(v_org, c.id, 'contract', c.current_version) + 1,
                'copy', app.contract_document_prints(v_org, c.id, 'contract', c.current_version) > 0),
            'promissory_notes', jsonb_build_object(
                'next_print_no', app.contract_document_prints(v_org, c.id, 'promissory_notes', c.current_version) + 1,
                'copy', app.contract_document_prints(v_org, c.id, 'promissory_notes', c.current_version) > 0)),
        'status_mark', CASE WHEN c.status IN ('completed', 'written_off', 'returned') THEN c.status::text END,
        'replaces', v_replaces,
        'today', v_today);
END;
$$;

-- 3. The print log ---------------------------------------------------------------------------------------

-- POST /api/contracts/:id/document-prints: one press of "Print" is one print (no idempotency key, as
-- S04). The contract's row lock gives two tills printing at once two different numbers. A write: an
-- expired shop is refused here and the client prints a copy.
CREATE FUNCTION public.record_contract_document_print(p_id uuid, p_document text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; c public.contracts; n integer;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.can_print_contract_documents() THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: installment.create or customer.view_pii' USING ERRCODE = '42501';
    END IF;
    IF app.has_permission('installment.create') THEN PERFORM app.require_permission('installment.create');
    ELSE PERFORM app.require_permission('customer.view_pii'); END IF;
    PERFORM app.require_module('installments');
    IF p_document IS NULL OR p_document NOT IN ('contract', 'promissory_notes') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: document' USING ERRCODE = 'P0001';
    END IF;
    v_org := app.current_org_id();
    SELECT * INTO c FROM public.contracts k WHERE k.organization_id = v_org AND k.id = p_id FOR UPDATE;
    IF NOT FOUND OR NOT app.can_see_contract(c.branch_id) THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF p_document = 'promissory_notes'
       AND (c.status NOT IN ('active', 'rescheduled') OR app.contract_remaining(v_org, c.id) <= 0) THEN
        RAISE EXCEPTION 'CONTRACT_NOT_OPEN: %', c.number USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('contract_id', c.id, 'status', c.status)::text;
    END IF;
    n := app.contract_document_prints(v_org, c.id, p_document, c.current_version) + 1;
    PERFORM app.write_audit('contract.document_printed', 'contract', c.id,
        p_after => jsonb_build_object('number', c.number, 'document', p_document, 'version', c.current_version,
                                      'print_no', n, 'copy', n > 1),
        p_branch_id => c.branch_id);
    RETURN jsonb_build_object('print_no', n, 'copy', n > 1);
END;
$$;

REVOKE ALL ON FUNCTION public.get_contract_documents(uuid), public.record_contract_document_print(uuid, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_contract_documents(uuid), public.record_contract_document_print(uuid, text)
    TO authenticated;
