-- =============================================================================
-- R04 · Guarantors (EC-66, D71)
--
-- A shop that sells on installments records the people who guarantee a customer's debt. A
-- guarantor is entered once per shop (same national ID rules and masking as customers, ID photos
-- as F14 files), linked to one or more customers with a relation, and later attached to
-- installment contracts. The installment policy says above which financed amount a contract needs
-- guarantors and how many; the contract-side rules are database functions plus a commit-time
-- trigger that N01/N02 call, so the server refuses a contract with too few guarantors even when
-- the client calls the database directly.
--
-- Numbered after the newest migration on main (D39). Everything below is NEW except:
--   * installment_policies gets one column (guarantors_required_count);
--   * app.installment_policy_json and public.publish_installment_policy are re-created with that
--     one key added;
--   * public.register_file is re-created from its latest version (S12) with the entity type
--     'guarantor' added to its entity map.
-- The baseline's guarantors, customer_guarantors and contract_guarantors tables, their indexes, RLS
-- policies, column grants (national_id is not granted) and triggers stay as they are.
--
-- Rules (D71):
--   1. One guarantor record per person per shop; it may back several customers and contracts.
--   2. Required: name (2-150), phone (one number, stored normalised like R01), national ID.
--      Optional: address (300), job (100), monthly income (money >= 0).
--   3. National ID = R01: 14 digits, Arabic digits stored as ASCII, must parse, birth date not in
--      the future, unique per shop (GUARANTOR_NATIONAL_ID_TAKEN names the existing guarantor).
--      Sending national_id for an existing guarantor needs customer.view_pii as well.
--   4. Masking = R01: the full ID only with customer.view_pii; everyone else gets the mask. The
--      audit log never holds the number. birth_date and gender are derived, only for a caller who
--      may see the ID.
--   5. A guarantor who is also a customer (same national ID) is shown as such; nobody can
--      guarantee themselves (GUARANTOR_IS_CUSTOMER).
--   6. Reads: the R01 read guard (any customer read key + plan module customers). Create and link:
--      guarantor.manage or customer.create. Edit, relation, unlink, archive, restore:
--      guarantor.manage. Every write needs the plan module customers.
--   7. Customer links are made and removed one at a time; editing a customer never touches them.
--      At most 5 per customer; an archived guarantor or a blocked customer gets no new link;
--      unlinking or archiving is refused while the guarantor is on an active contract.
--   8. installment_policies.guarantors_required_count (1-3): when guarantor_required_above is set
--      and the financed amount (cash price - down payment) is greater than it, the contract needs
--      at least that many guarantors; at most 3 per contract. Migrated (M02) contracts are exempt.
-- =============================================================================

-- 1. The policy column --------------------------------------------------------------------------

-- Existing versions get 1 (no new version is published by this migration).
ALTER TABLE public.installment_policies
    ADD COLUMN guarantors_required_count smallint NOT NULL DEFAULT 1
        CHECK (guarantors_required_count BETWEEN 1 AND 3);

-- 2. Pure helpers (no grants) -----------------------------------------------------------------

CREATE FUNCTION app.guarantor_relations()
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT ARRAY['father', 'mother', 'brother', 'sister', 'spouse', 'son', 'daughter', 'relative',
                 'friend', 'colleague', 'employer', 'neighbour', 'other']
$$;

-- The guarantor is on a contract that is still running (status active). With p_customer_id only
-- that customer's contracts count.
CREATE FUNCTION app.guarantor_on_active_contract(p_org uuid, p_guarantor_id uuid, p_customer_id uuid DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.contract_guarantors cg
        JOIN public.contracts k ON k.id = cg.contract_id AND k.organization_id = cg.organization_id
        WHERE cg.organization_id = p_org AND cg.guarantor_id = p_guarantor_id
          AND k.status = 'active'
          AND (p_customer_id IS NULL OR k.customer_id = p_customer_id))
$$;

-- Row shape of the contract's Guarantor. p_pii = the caller holds customer.view_pii: only then are
-- the full national ID and the birth date and gender read from it returned.
CREATE FUNCTION app.guarantor_json(p_org uuid, p_id uuid, p_pii boolean)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', g.id, 'full_name', g.full_name, 'phone', g.phone,
        'national_id', CASE WHEN p_pii THEN g.national_id END,
        'national_id_masked', app.mask_national_id(g.national_id),
        'birth_date', CASE WHEN p_pii THEN (SELECT p.birth_date FROM app.parse_national_id(g.national_id) p) END,
        'gender', CASE WHEN p_pii THEN (SELECT p.gender FROM app.parse_national_id(g.national_id) p) END,
        'address', g.address, 'job', g.job,
        'monthly_income', g.monthly_income::numeric(18,2)::text,
        'also_customer', (
            SELECT jsonb_build_object('id', c.id, 'full_name', c.full_name)
            FROM public.customers c
            WHERE c.organization_id = p_org
              AND ((g.national_id IS NOT NULL AND c.national_id = g.national_id) OR c.id = g.customer_id)
            ORDER BY (c.national_id = g.national_id) DESC NULLS LAST, c.id LIMIT 1),
        'archived_at', g.archived_at,
        'id_photos_count', (SELECT count(*) FROM public.files f
                            WHERE f.organization_id = p_org AND f.entity_type = 'guarantor'
                              AND f.entity_id = g.id AND f.purpose = 'customer_id'),
        'created_at', g.created_at, 'updated_at', g.updated_at)
    FROM public.guarantors g
    WHERE g.id = p_id AND g.organization_id = p_org
$$;

-- The editable fields (the audit before/after). Never the national ID itself: its mask only.
CREATE FUNCTION app.guarantor_fields_json(g public.guarantors)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'full_name', g.full_name, 'phone', g.phone,
        'national_id_masked', app.mask_national_id(g.national_id),
        'address', g.address, 'job', g.job,
        'monthly_income', g.monthly_income::numeric(18,2)::text)
$$;

-- The guarantors of one customer (the contract's CustomerGuarantorList), oldest link first.
CREATE FUNCTION app.customer_guarantors_json(p_org uuid, p_customer_id uuid, p_pii boolean)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT COALESCE(jsonb_agg(
        app.guarantor_json(p_org, cg.guarantor_id, p_pii) || jsonb_build_object(
            'relation', cg.relation, 'linked_at', cg.created_at,
            'on_active_contract', app.guarantor_on_active_contract(p_org, cg.guarantor_id, p_customer_id))
        ORDER BY cg.created_at, cg.guarantor_id), '[]'::jsonb)
    FROM public.customer_guarantors cg
    WHERE cg.organization_id = p_org AND cg.customer_id = p_customer_id
$$;

-- Applies the keys of c to the row r and validates them (the contract's rules, repeated here).
-- A key that is not sent keeps its value; the optional text keys accept null or '' to clear.
CREATE FUNCTION app.guarantor_apply(r public.guarantors, c jsonb)
RETURNS public.guarantors LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE
    v_key text; v_txt text; v_birth date;
    v_texts constant text[] := ARRAY['phone', 'national_id', 'address', 'job', 'monthly_income'];
BEGIN
    IF c IS NULL OR jsonb_typeof(c) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    -- organization_id, customer_id, archived_at and anything unknown are refused.
    SELECT k INTO v_key FROM jsonb_object_keys(c) k
    WHERE k <> ALL (v_texts || ARRAY['full_name'])
    LIMIT 1;
    IF v_key IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
    END IF;
    SELECT k INTO v_key FROM jsonb_object_keys(c) k
    WHERE (k = 'full_name' AND jsonb_typeof(c -> k) <> 'string')
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
    IF c ? 'phone' THEN
        v_txt := app.normalize_customer_phone(btrim(c ->> 'phone'));
        IF v_txt IS NULL OR v_txt !~ '^\+?[0-9]{7,15}$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: phone' USING ERRCODE = 'P0001';
        END IF;
        r.phone := v_txt;
    END IF;
    IF c ? 'national_id' THEN
        v_txt := NULLIF(regexp_replace(app.ascii_digits(btrim(c ->> 'national_id')), '[[:space:]-]', '', 'g'), '');
        IF v_txt IS NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: national_id' USING ERRCODE = 'P0001';
        END IF;
        SELECT p.birth_date INTO v_birth FROM app.parse_national_id(v_txt) p;
        IF v_birth IS NULL OR v_birth > current_date + 1 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: national_id' USING ERRCODE = 'P0001';
        END IF;
        r.national_id := v_txt;
    END IF;
    IF c ? 'address' THEN
        v_txt := NULLIF(btrim(c ->> 'address'), '');
        IF length(v_txt) > 300 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: address' USING ERRCODE = 'P0001';
        END IF;
        r.address := v_txt;
    END IF;
    IF c ? 'job' THEN
        v_txt := NULLIF(btrim(c ->> 'job'), '');
        IF length(v_txt) > 100 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: job' USING ERRCODE = 'P0001';
        END IF;
        r.job := v_txt;
    END IF;
    IF c ? 'monthly_income' THEN
        v_txt := NULLIF(btrim(c ->> 'monthly_income'), '');
        IF v_txt IS NOT NULL AND v_txt !~ '^[0-9]{1,16}(\.[0-9]{1,2})?$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: monthly_income' USING ERRCODE = 'P0001';
        END IF;
        r.monthly_income := v_txt::numeric(18,2);
    END IF;
    RETURN r;
END;
$$;

-- Rule 3: the unique national ID per shop as the contract's code, naming who already has it.
CREATE FUNCTION app.guarantor_national_id_taken(p_org uuid, p_national_id text)
RETURNS void LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_id uuid; v_name text;
BEGIN
    SELECT g.id, g.full_name INTO v_id, v_name FROM public.guarantors g
    WHERE g.organization_id = p_org AND g.national_id = p_national_id;
    RAISE EXCEPTION 'GUARANTOR_NATIONAL_ID_TAKEN' USING ERRCODE = 'P0001',
        DETAIL = jsonb_build_object('guarantor_id', v_id, 'full_name', v_name)::text;
END;
$$;

-- Rule 7: links a guarantor to a customer. Called by create_guarantor (with link) and
-- link_customer_guarantor, after the caller's permission was checked. Locks the customer, then
-- the guarantor.
CREATE FUNCTION app.link_guarantor(p_org uuid, p_customer_id uuid, p_guarantor_id uuid, p_relation text)
RETURNS void LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE v_c public.customers; v_g public.guarantors;
BEGIN
    IF p_relation IS NULL OR p_relation <> ALL (app.guarantor_relations()) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: relation' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_c FROM public.customers
    WHERE id = p_customer_id AND organization_id = p_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_g FROM public.guarantors
    WHERE id = p_guarantor_id AND organization_id = p_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'GUARANTOR_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_g.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'GUARANTOR_ARCHIVED' USING ERRCODE = 'P0001';
    END IF;
    IF v_c.status = 'blocked' OR v_c.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'CUSTOMER_BLOCKED' USING ERRCODE = 'P0001';
    END IF;
    IF v_g.customer_id = v_c.id OR (v_g.national_id IS NOT NULL AND v_g.national_id = v_c.national_id) THEN
        RAISE EXCEPTION 'GUARANTOR_IS_CUSTOMER' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.customer_guarantors
               WHERE customer_id = p_customer_id AND guarantor_id = p_guarantor_id) THEN
        RAISE EXCEPTION 'GUARANTOR_ALREADY_LINKED' USING ERRCODE = 'P0001';
    END IF;
    IF (SELECT count(*) FROM public.customer_guarantors WHERE customer_id = p_customer_id) >= 5 THEN
        RAISE EXCEPTION 'GUARANTOR_LIMIT_REACHED' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO public.customer_guarantors (organization_id, customer_id, guarantor_id, relation, created_by)
    VALUES (p_org, p_customer_id, p_guarantor_id, p_relation, app.current_employee_id());
    PERFORM app.write_audit('customer.guarantor_linked', 'customer', p_customer_id,
        p_after => jsonb_build_object('guarantor_id', p_guarantor_id, 'relation', p_relation));
END;
$$;

-- 3. Contract rules (rule 8; for N01/N02, no route of their own) -------------------------------

-- How many guarantors a contract needs: 0 when none is required (policy amount NULL, or the
-- financed amount is not above it), else the count of that policy version.
CREATE FUNCTION app.guarantors_required(p_org uuid, p_policy_id uuid, p_financed_amount numeric)
RETURNS integer LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT COALESCE((
        SELECT CASE WHEN p.guarantor_required_above IS NOT NULL AND p_financed_amount > p.guarantor_required_above
                    THEN p.guarantors_required_count::integer ELSE 0 END
        FROM public.installment_policies p
        WHERE p.id = p_policy_id AND p.organization_id = p_org), 0)
$$;

-- Raises, in this order: duplicates or more than 3 (VALIDATION_FAILED: guarantor_ids); an id not
-- in the shop (GUARANTOR_NOT_FOUND); archived (GUARANTOR_ARCHIVED); not linked to the customer
-- (GUARANTOR_NOT_LINKED); fewer than the policy needs (GUARANTOR_REQUIRED {required, given}).
CREATE FUNCTION app.check_contract_guarantors(p_org uuid, p_customer_id uuid, p_policy_id uuid,
                                              p_financed_amount numeric, p_guarantor_ids uuid[])
RETURNS void LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_ids uuid[] := COALESCE(p_guarantor_ids, ARRAY[]::uuid[]); v_required integer;
BEGIN
    IF cardinality(v_ids) > 3 OR array_position(v_ids, NULL) IS NOT NULL
       OR (SELECT count(DISTINCT i) FROM unnest(v_ids) i) <> cardinality(v_ids) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: guarantor_ids' USING ERRCODE = 'P0001';
    END IF;
    IF (SELECT count(*) FROM public.guarantors g
        WHERE g.organization_id = p_org AND g.id = ANY (v_ids)) <> cardinality(v_ids) THEN
        RAISE EXCEPTION 'GUARANTOR_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.guarantors g
               WHERE g.organization_id = p_org AND g.id = ANY (v_ids) AND g.archived_at IS NOT NULL) THEN
        RAISE EXCEPTION 'GUARANTOR_ARCHIVED' USING ERRCODE = 'P0001';
    END IF;
    IF (SELECT count(*) FROM public.customer_guarantors cg
        WHERE cg.organization_id = p_org AND cg.customer_id = p_customer_id
          AND cg.guarantor_id = ANY (v_ids)) <> cardinality(v_ids) THEN
        RAISE EXCEPTION 'GUARANTOR_NOT_LINKED' USING ERRCODE = 'P0001';
    END IF;
    v_required := app.guarantors_required(p_org, p_policy_id, p_financed_amount);
    IF cardinality(v_ids) < v_required THEN
        RAISE EXCEPTION 'GUARANTOR_REQUIRED' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('required', v_required, 'given', cardinality(v_ids))::text;
    END IF;
END;
$$;

-- Inserts the contract_guarantors rows (append-only in the baseline: never removed; N05 changes go
-- through new records). Call it in the transaction that inserts the contract.
CREATE FUNCTION app.attach_contract_guarantors(p_org uuid, p_contract_id uuid, p_guarantor_ids uuid[])
RETURNS void LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE v_ids uuid[] := COALESCE(p_guarantor_ids, ARRAY[]::uuid[]);
BEGIN
    IF cardinality(v_ids) > 3 OR array_position(v_ids, NULL) IS NOT NULL
       OR (SELECT count(DISTINCT i) FROM unnest(v_ids) i) <> cardinality(v_ids) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: guarantor_ids' USING ERRCODE = 'P0001';
    END IF;
    PERFORM 1 FROM public.guarantors g
    WHERE g.organization_id = p_org AND g.id = ANY (v_ids) ORDER BY g.id FOR SHARE;
    IF (SELECT count(*) FROM public.guarantors g
        WHERE g.organization_id = p_org AND g.id = ANY (v_ids)) <> cardinality(v_ids) THEN
        RAISE EXCEPTION 'GUARANTOR_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.guarantors g
               WHERE g.organization_id = p_org AND g.id = ANY (v_ids) AND g.archived_at IS NOT NULL) THEN
        RAISE EXCEPTION 'GUARANTOR_ARCHIVED' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO public.contract_guarantors (organization_id, contract_id, guarantor_id, created_by)
    SELECT p_org, p_contract_id, i, app.current_employee_id() FROM unnest(v_ids) i;
END;
$$;

-- The safety net: at commit a contract that needs guarantors must carry enough of them, whoever
-- wrote it. Migrated (M02) contracts are exempt.
CREATE FUNCTION app.contracts_guarantors_check()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_required integer; v_given integer;
BEGIN
    IF NEW.is_migrated THEN
        RETURN NULL;
    END IF;
    v_required := app.guarantors_required(NEW.organization_id, NEW.policy_id, NEW.financed_amount);
    IF v_required > 0 THEN
        SELECT count(*) INTO v_given FROM public.contract_guarantors cg
        WHERE cg.organization_id = NEW.organization_id AND cg.contract_id = NEW.id;
        IF v_given < v_required THEN
            RAISE EXCEPTION 'GUARANTOR_REQUIRED' USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('required', v_required, 'given', v_given)::text;
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_contracts_guarantors_check
    AFTER INSERT ON public.contracts
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION app.contracts_guarantors_check();

REVOKE ALL ON FUNCTION app.guarantor_relations(), app.guarantor_on_active_contract(uuid, uuid, uuid),
    app.guarantor_json(uuid, uuid, boolean), app.guarantor_fields_json(public.guarantors),
    app.customer_guarantors_json(uuid, uuid, boolean), app.guarantor_apply(public.guarantors, jsonb),
    app.guarantor_national_id_taken(uuid, text), app.link_guarantor(uuid, uuid, uuid, text),
    app.guarantors_required(uuid, uuid, numeric),
    app.check_contract_guarantors(uuid, uuid, uuid, numeric, uuid[]),
    app.attach_contract_guarantors(uuid, uuid, uuid[]), app.contracts_guarantors_check()
    FROM PUBLIC, anon, authenticated;

-- 4. Settings: the policy answers with the new key, publishing accepts it ------------------------

CREATE OR REPLACE FUNCTION app.installment_policy_json(p public.installment_policies)
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
        'guarantors_required_count', p.guarantors_required_count,
        'survey_required_above', p.survey_required_above::text,
        'effective_from', p.effective_from,
        'created_at', p.created_at,
        'created_by', p.created_by) END
$$;

CREATE OR REPLACE FUNCTION public.publish_installment_policy(p_policy jsonb)
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
        'guarantor_required_above', 'guarantors_required_count', 'survey_required_above'];
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
            'min_installment_by_frequency', '{}'::jsonb, 'amount_tiers', '[]'::jsonb,
            'guarantors_required_count', 1) || p_policy);
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
    IF v_row.guarantors_required_count IS NULL OR v_row.guarantors_required_count NOT BETWEEN 1 AND 3 THEN
        RAISE EXCEPTION 'POLICY_INVALID: guarantors_required_count' USING ERRCODE = 'P0001';
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

-- 5. Reads (rule 6) -----------------------------------------------------------------------------

-- Search as the customers' (name contains, a phone, the whole national ID; a prefix with
-- customer.view_pii). Ordered by name, then id.
CREATE FUNCTION public.list_guarantors(p_search text DEFAULT NULL, p_status text DEFAULT 'active',
                                       p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; v_pii boolean; v_search text; v_name text; v_digits text; v_phone text;
    v_id_exact text; v_id_prefix text; v_result jsonb; v_status text := COALESCE(p_status, 'active');
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    v_pii := app.has_permission('customer.view_pii');
    IF v_status NOT IN ('active', 'archived', 'all')
       OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    v_search := NULLIF(btrim(p_search), '');
    IF length(v_search) > 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: search' USING ERRCODE = 'P0001';
    END IF;
    v_name := app.search_text(replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_'));
    v_phone := ltrim(app.normalize_customer_phone(v_search), '+');
    IF v_phone !~ '^[0-9]{3,}$' THEN
        v_phone := NULL;
    END IF;
    v_digits := regexp_replace(app.ascii_digits(v_search), '[[:space:]-]', '', 'g');
    IF v_digits ~ '^[0-9]{14}$' THEN
        v_id_exact := v_digits;
    ELSIF v_pii AND v_digits ~ '^[0-9]{4,13}$' THEN
        v_id_prefix := v_digits;
    END IF;

    WITH found AS (
        SELECT g.id, g.full_name FROM public.guarantors g
        WHERE g.organization_id = v_org
          AND (v_status = 'all' OR (v_status = 'archived') = (g.archived_at IS NOT NULL))
          AND (v_search IS NULL
               OR app.search_text(g.full_name) LIKE '%' || v_name || '%'
               OR (v_phone IS NOT NULL AND g.phone LIKE '%' || v_phone || '%')
               OR (v_id_exact IS NOT NULL AND g.national_id = v_id_exact)
               OR (v_id_prefix IS NOT NULL AND g.national_id LIKE v_id_prefix || '%'))
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(app.guarantor_json(v_org, pg.id, v_pii) ORDER BY pg.full_name, pg.id)
            FROM (SELECT f.* FROM found f ORDER BY f.full_name, f.id LIMIT p_limit OFFSET p_offset) pg), '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- One guarantor with the customers they back and the contracts they are on.
CREATE FUNCTION public.get_guarantor(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_json jsonb;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    v_json := app.guarantor_json(v_org, p_id, app.has_permission('customer.view_pii'));
    IF v_json IS NULL THEN
        RAISE EXCEPTION 'GUARANTOR_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_json || jsonb_build_object(
        'customers', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('customer_id', c.id, 'full_name', c.full_name,
                                                'relation', cg.relation, 'linked_at', cg.created_at)
                             ORDER BY cg.created_at, c.id)
            FROM public.customer_guarantors cg
            JOIN public.customers c ON c.id = cg.customer_id AND c.organization_id = cg.organization_id
            WHERE cg.organization_id = v_org AND cg.guarantor_id = p_id), '[]'::jsonb),
        'contracts', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('contract_id', k.id, 'number', k.number,
                                                'customer_id', k.customer_id, 'customer_name', c.full_name,
                                                'status', k.status,
                                                'total_payable', k.total_payable::numeric(18,2)::text)
                             ORDER BY k.created_at, k.id)
            FROM public.contract_guarantors cg
            JOIN public.contracts k ON k.id = cg.contract_id AND k.organization_id = cg.organization_id
            JOIN public.customers c ON c.id = k.customer_id AND c.organization_id = k.organization_id
            WHERE cg.organization_id = v_org AND cg.guarantor_id = p_id), '[]'::jsonb));
END;
$$;

CREATE FUNCTION public.list_customer_guarantors(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    IF NOT EXISTS (SELECT 1 FROM public.customers WHERE id = p_customer_id AND organization_id = v_org) THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.customer_guarantors_json(v_org, p_customer_id, app.has_permission('customer.view_pii'));
END;
$$;

-- Does this customer meet the shop's current policy for a financed amount (cash price - down payment)?
CREATE FUNCTION public.get_guarantor_requirement(p_customer_id uuid, p_financed_amount text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_policy public.installment_policies; v_required integer; v_linked integer;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    IF p_financed_amount IS NULL OR p_financed_amount !~ '^[0-9]{1,16}(\.[0-9]{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: financed_amount' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.customers WHERE id = p_customer_id AND organization_id = v_org) THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    v_policy := app.current_installment_policy(v_org);
    v_required := CASE WHEN v_policy.id IS NULL THEN 0
                       ELSE app.guarantors_required(v_org, v_policy.id, p_financed_amount::numeric) END;
    SELECT count(*) INTO v_linked
    FROM public.customer_guarantors cg
    JOIN public.guarantors g ON g.id = cg.guarantor_id AND g.organization_id = cg.organization_id
    WHERE cg.organization_id = v_org AND cg.customer_id = p_customer_id AND g.archived_at IS NULL;
    RETURN jsonb_build_object(
        'policy_id', v_policy.id, 'policy_version', v_policy.version,
        'required_above', v_policy.guarantor_required_above::numeric(18,2)::text,
        'required_count', v_required, 'linked_active_count', v_linked,
        'met', v_linked >= v_required);
END;
$$;

-- 6. Writes -------------------------------------------------------------------------------------

-- guarantor.manage or customer.create. With "link" the guarantor is created and linked to that
-- customer in one transaction (a bad link rolls both back). The answer follows the PII rule.
CREATE FUNCTION public.create_guarantor(p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_body jsonb; v_link jsonb; r public.guarantors; v_row public.guarantors;
BEGIN
    IF app.has_permission('guarantor.manage') THEN
        v_emp := app.require_permission('guarantor.manage');
    ELSE
        v_emp := app.require_permission('customer.create');
    END IF;
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    v_link := p_body -> 'link';
    v_body := p_body - 'link';
    IF p_body ? 'link' AND (jsonb_typeof(v_link) <> 'object'
       OR (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_link) k) IS DISTINCT FROM ARRAY['customer_id', 'relation']
       OR jsonb_typeof(v_link -> 'customer_id') <> 'string' OR jsonb_typeof(v_link -> 'relation') <> 'string') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: link' USING ERRCODE = 'P0001';
    END IF;
    IF NOT (v_body ? 'full_name') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: full_name' USING ERRCODE = 'P0001';
    END IF;
    IF NOT (v_body ? 'phone') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: phone' USING ERRCODE = 'P0001';
    END IF;
    IF NOT (v_body ? 'national_id') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: national_id' USING ERRCODE = 'P0001';
    END IF;
    r := app.guarantor_apply(r, v_body);
    BEGIN
        INSERT INTO public.guarantors (organization_id, full_name, phone, national_id, address, job,
            monthly_income, customer_id, created_by, updated_by)
        VALUES (v_org, r.full_name, r.phone, r.national_id, r.address, r.job, r.monthly_income,
            (SELECT c.id FROM public.customers c WHERE c.organization_id = v_org AND c.national_id = r.national_id),
            v_emp, v_emp)
        RETURNING * INTO v_row;
    EXCEPTION WHEN unique_violation THEN
        PERFORM app.guarantor_national_id_taken(v_org, r.national_id);
    END;
    PERFORM app.write_audit('guarantor.created', 'guarantor', v_row.id,
        p_after => app.guarantor_fields_json(v_row));
    IF v_link IS NOT NULL THEN
        PERFORM app.link_guarantor(v_org, (v_link ->> 'customer_id')::uuid, v_row.id, v_link ->> 'relation');
    END IF;
    RETURN app.guarantor_json(v_org, v_row.id, app.has_permission('customer.view_pii'));
EXCEPTION
    WHEN check_violation OR not_null_violation OR invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: guarantor' USING ERRCODE = 'P0001';
END;
$$;

-- guarantor.manage. Before/after hold the changed keys only; a change of the national ID shows as
-- its masks plus national_id_changed (the number itself never reaches the audit log) and is
-- written with severity warning. Sending national_id needs customer.view_pii as well.
CREATE FUNCTION public.update_guarantor(p_id uuid, p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_pii boolean; v_old public.guarantors; r public.guarantors;
    v_old_json jsonb; v_new_json jsonb; v_before jsonb; v_after jsonb; v_id_changed boolean;
BEGIN
    v_emp := app.require_permission('guarantor.manage');
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    v_pii := app.has_permission('customer.view_pii');
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_old FROM public.guarantors
    WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'GUARANTOR_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    -- Rule 3: checked before the value is looked at, so the answer never confirms a guess.
    IF p_body ? 'national_id' AND NOT v_pii THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: customer.view_pii' USING ERRCODE = '42501';
    END IF;

    r := app.guarantor_apply(v_old, p_body);
    v_old_json := app.guarantor_fields_json(v_old);
    v_new_json := app.guarantor_fields_json(r);
    v_id_changed := r.national_id IS DISTINCT FROM v_old.national_id;
    IF v_new_json = v_old_json AND NOT v_id_changed THEN
        RETURN app.guarantor_json(v_org, p_id, v_pii);     -- no change: no update, no audit row
    END IF;

    BEGIN
        UPDATE public.guarantors SET
            full_name = r.full_name, phone = r.phone, national_id = r.national_id,
            address = r.address, job = r.job, monthly_income = r.monthly_income,
            customer_id = CASE WHEN v_id_changed
                               THEN (SELECT c.id FROM public.customers c
                                     WHERE c.organization_id = v_org AND c.national_id = r.national_id)
                               ELSE customer_id END,
            updated_by = v_emp
        WHERE id = p_id;
    EXCEPTION WHEN unique_violation THEN
        PERFORM app.guarantor_national_id_taken(v_org, r.national_id);
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
    PERFORM app.write_audit('guarantor.updated', 'guarantor', p_id, p_before => v_before, p_after => v_after,
        p_severity => CASE WHEN v_id_changed THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN app.guarantor_json(v_org, p_id, v_pii);
EXCEPTION
    WHEN check_violation OR not_null_violation OR invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: guarantor' USING ERRCODE = 'P0001';
END;
$$;

-- guarantor.manage. Archive is refused while the guarantor is on an active contract. The same
-- state again changes nothing and writes no audit row.
CREATE FUNCTION public.set_guarantor_archived(p_id uuid, p_archived boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_pii boolean; v_old public.guarantors;
BEGIN
    v_emp := app.require_permission('guarantor.manage');
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    v_pii := app.has_permission('customer.view_pii');
    IF p_archived IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: archived' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_old FROM public.guarantors
    WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'GUARANTOR_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF (v_old.archived_at IS NOT NULL) = p_archived THEN
        RETURN app.guarantor_json(v_org, p_id, v_pii);
    END IF;
    IF p_archived AND app.guarantor_on_active_contract(v_org, p_id) THEN
        RAISE EXCEPTION 'GUARANTOR_ON_ACTIVE_CONTRACT' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.guarantors SET archived_at = CASE WHEN p_archived THEN now() END, updated_by = v_emp
    WHERE id = p_id;
    PERFORM app.write_audit(CASE WHEN p_archived THEN 'guarantor.archived' ELSE 'guarantor.restored' END,
        'guarantor', p_id,
        p_severity => CASE WHEN p_archived THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN app.guarantor_json(v_org, p_id, v_pii);
END;
$$;

-- guarantor.manage or customer.create. The answer is the customer's whole list.
CREATE FUNCTION public.link_customer_guarantor(p_customer_id uuid, p_guarantor_id uuid, p_relation text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    IF app.has_permission('guarantor.manage') THEN
        PERFORM app.require_permission('guarantor.manage');
    ELSE
        PERFORM app.require_permission('customer.create');
    END IF;
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    PERFORM app.link_guarantor(v_org, p_customer_id, p_guarantor_id, p_relation);
    RETURN app.customer_guarantors_json(v_org, p_customer_id, app.has_permission('customer.view_pii'));
END;
$$;

-- guarantor.manage. The same relation again changes nothing and writes no audit row.
CREATE FUNCTION public.set_customer_guarantor_relation(p_customer_id uuid, p_guarantor_id uuid, p_relation text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_old text;
BEGIN
    PERFORM app.require_permission('guarantor.manage');
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    IF p_relation IS NULL OR p_relation <> ALL (app.guarantor_relations()) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: relation' USING ERRCODE = 'P0001';
    END IF;
    PERFORM 1 FROM public.customers WHERE id = p_customer_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.guarantors WHERE id = p_guarantor_id AND organization_id = v_org) THEN
        RAISE EXCEPTION 'GUARANTOR_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    SELECT relation INTO v_old FROM public.customer_guarantors
    WHERE customer_id = p_customer_id AND guarantor_id = p_guarantor_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'GUARANTOR_NOT_LINKED' USING ERRCODE = 'P0001';
    END IF;
    IF v_old IS DISTINCT FROM p_relation THEN
        UPDATE public.customer_guarantors SET relation = p_relation
        WHERE customer_id = p_customer_id AND guarantor_id = p_guarantor_id;
        PERFORM app.write_audit('customer.guarantor_relation_set', 'customer', p_customer_id,
            p_before => jsonb_build_object('guarantor_id', p_guarantor_id, 'relation', v_old),
            p_after => jsonb_build_object('guarantor_id', p_guarantor_id, 'relation', p_relation));
    END IF;
    RETURN app.customer_guarantors_json(v_org, p_customer_id, app.has_permission('customer.view_pii'));
END;
$$;

-- guarantor.manage. Refused while the guarantor is on an active contract of this customer; the
-- audit row keeps who, when and the relation.
CREATE FUNCTION public.unlink_customer_guarantor(p_customer_id uuid, p_guarantor_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_old text;
BEGIN
    PERFORM app.require_permission('guarantor.manage');
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    PERFORM 1 FROM public.customers WHERE id = p_customer_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.guarantors WHERE id = p_guarantor_id AND organization_id = v_org) THEN
        RAISE EXCEPTION 'GUARANTOR_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    SELECT relation INTO v_old FROM public.customer_guarantors
    WHERE customer_id = p_customer_id AND guarantor_id = p_guarantor_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'GUARANTOR_NOT_LINKED' USING ERRCODE = 'P0001';
    END IF;
    IF app.guarantor_on_active_contract(v_org, p_guarantor_id, p_customer_id) THEN
        RAISE EXCEPTION 'GUARANTOR_ON_ACTIVE_CONTRACT' USING ERRCODE = 'P0001';
    END IF;
    DELETE FROM public.customer_guarantors
    WHERE customer_id = p_customer_id AND guarantor_id = p_guarantor_id;
    PERFORM app.write_audit('customer.guarantor_unlinked', 'customer', p_customer_id,
        p_before => jsonb_build_object('guarantor_id', p_guarantor_id, 'relation', v_old),
        p_severity => 'warning');
    RETURN app.customer_guarantors_json(v_org, p_customer_id, app.has_permission('customer.view_pii'));
END;
$$;

-- 7. ID photos: the entity type 'guarantor' ------------------------------------------------------

-- Re-created from its latest version (S12); the only change is the 'guarantor' line in the entity map.
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
        WHEN 'other'            THEN CASE WHEN p_entity_type='warranty_claim' THEN 'warranty.manage' ELSE 'org.settings_manage' END
    END);
    v_org   uuid := app.current_org_id();
    v_table text;
    v_found boolean;
    v_branch uuid;
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
            WHEN 'warranty_claim' THEN 'warranty_claims'
            WHEN 'guarantor'  THEN 'guarantors'
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

    IF p_entity_type='warranty_claim' THEN
        IF p_entity_id IS NULL OR p_purpose<>'other' THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
        SELECT branch_id INTO v_branch FROM public.warranty_claims WHERE id=p_entity_id AND organization_id=v_org FOR UPDATE;
        PERFORM app.require_branch_access(v_branch);
        IF (SELECT count(*) FROM public.files WHERE organization_id=v_org AND entity_type='warranty_claim' AND entity_id=p_entity_id)>=5 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: at most five claim photos' USING ERRCODE='P0001'; END IF;
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

-- 8. Grants: the ten public functions only -------------------------------------------------------

REVOKE ALL ON FUNCTION public.list_guarantors(text, text, integer, integer), public.get_guarantor(uuid),
    public.list_customer_guarantors(uuid), public.get_guarantor_requirement(uuid, text),
    public.create_guarantor(jsonb), public.update_guarantor(uuid, jsonb),
    public.set_guarantor_archived(uuid, boolean), public.link_customer_guarantor(uuid, uuid, text),
    public.set_customer_guarantor_relation(uuid, uuid, text), public.unlink_customer_guarantor(uuid, uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_guarantors(text, text, integer, integer), public.get_guarantor(uuid),
    public.list_customer_guarantors(uuid), public.get_guarantor_requirement(uuid, text),
    public.create_guarantor(jsonb), public.update_guarantor(uuid, jsonb),
    public.set_guarantor_archived(uuid, boolean), public.link_customer_guarantor(uuid, uuid, text),
    public.set_customer_guarantor_relation(uuid, uuid, text), public.unlink_customer_guarantor(uuid, uuid)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.register_file(uuid, text, text, text, bigint, text,
                                               public.file_purpose, text, uuid) TO authenticated;
