-- =============================================================================
-- S08 · Offline cash sales (EC-75). Task file S08_EXECUTION.md, decisions D1-D16; test plan
-- docs/testing/plans/S08.md.
--
-- When the internet drops, the POS keeps selling for cash under a LEASE this database issued:
-- bound to one device, its open shift and that shift's cashier, with the shop's limits, a
-- snapshot of prices and stock, the device's ETA chain head and the next sale sequence. The
-- device builds, signs and prints each sale (and its ETA receipt, UUID and QR) and sends it
-- later. Here:
--   receive  (sync_offline_sales / import_offline_sales, the user's token): store each sale
--            exactly as sent, once per (device, seq); check it is ours; create its fiscal row
--            with the printed receipt; move the device's ETA chain head (D8); queue
--            offline.process.
--   process  (app.offline_process, service role, after the worker checked the signature and the
--            UUID): post the sale through the S01 core exactly as printed, or park it as a
--            conflict for a manager; release the fiscal row for submission unless it is held.
--   resolve  (resolve_offline_sale, offline.resolve): the manager's D11 actions.
-- A printed receipt is a fiscal fact: business conflicts never stop its submission; only a
-- verification failure, a receipt that does not match its sale, or a revoked lease does.
--
-- Changes to merged code (D12), each a copy of the latest body with the smallest change:
--   app.sales_eta_fiscal (T02), public.eta_claim_for_submit (T02),
--   public.eta_claim_deadline_alerts (T02), public.fiscal_request_correction (T03),
--   app.post_sale_core (S01/N02: its body moves to app.post_sale_core_full with one trailing
--   parameter; the old signature calls it), app.export_excluded_columns (M03);
--   new triggers on shifts (K02/EC-147 close), devices (O03 unpair/deactivate) and day_closes
--   (K04 close); the two fiscal_submissions CHECKs; fiscal_events.kind.
-- =============================================================================

-- 1. Settings and the permission ----------------------------------------------------------------

ALTER TABLE public.org_settings
    ADD COLUMN offline_enabled         boolean NOT NULL DEFAULT false,
    ADD COLUMN offline_max_sale_total  numeric(18,2) NOT NULL DEFAULT 20000
        CHECK (offline_max_sale_total > 0 AND offline_max_sale_total < 150000),
    ADD COLUMN offline_max_hours       integer NOT NULL DEFAULT 12 CHECK (offline_max_hours BETWEEN 1 AND 20),
    ADD COLUMN offline_max_sales       integer NOT NULL DEFAULT 100 CHECK (offline_max_sales BETWEEN 1 AND 1000),
    ADD COLUMN offline_max_lease_total numeric(18,2) NOT NULL DEFAULT 200000 CHECK (offline_max_lease_total > 0);

INSERT INTO public.permissions (key, module, description) VALUES ('offline.resolve', 'sales', 'Review and resolve offline sales');
INSERT INTO public.role_permissions (role, permission_key) VALUES ('BRANCH_MANAGER', 'offline.resolve');

-- 2. Devices -------------------------------------------------------------------------------------

ALTER TABLE public.devices
    ADD COLUMN offline_code     text CHECK (offline_code ~ '^D[1-9][0-9]{0,5}$'),   -- D1, D2, ... (sale numbers)
    ADD COLUMN offline_seq_last integer NOT NULL DEFAULT 0 CHECK (offline_seq_last >= 0);
CREATE UNIQUE INDEX devices_offline_code_idx ON public.devices (organization_id, offline_code)
    WHERE offline_code IS NOT NULL;
-- devices has column grants (T02).
GRANT SELECT (offline_code, offline_seq_last) ON public.devices TO authenticated;

-- 3. Tables --------------------------------------------------------------------------------------

-- The public keys a device signed its offline sales with (D5). Never a private key.
CREATE TABLE public.device_offline_keys (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    device_id        uuid NOT NULL,
    public_key       text NOT NULL CHECK (public_key ~ '^[A-Za-z0-9+/]+={0,2}$' AND length(public_key) BETWEEN 80 AND 400),
    first_seen_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT device_offline_keys_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT device_offline_keys_key UNIQUE (device_id, public_key),
    FOREIGN KEY (device_id, organization_id) REFERENCES public.devices (id, organization_id)
);

-- What a device may sell offline in one branch (D3): one row per distinct content.
CREATE TABLE public.offline_snapshots (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    branch_id        uuid NOT NULL,
    content_hash     text NOT NULL CHECK (content_hash ~ '^[0-9a-f]{64}$'),
    data             jsonb NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT offline_snapshots_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT offline_snapshots_hash_key UNIQUE (branch_id, content_hash),
    FOREIGN KEY (branch_id, organization_id) REFERENCES public.branches (id, organization_id)
);

-- What the server allows one device to do offline (D2).
CREATE TABLE public.offline_leases (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    device_id        uuid NOT NULL,
    shift_id         uuid NOT NULL,
    branch_id        uuid NOT NULL,
    cashier_id       uuid NOT NULL,                          -- the shift's employee
    issued_at        timestamptz NOT NULL DEFAULT now(),
    expires_at       timestamptz NOT NULL,
    max_sale_total   numeric(18,2) NOT NULL,
    max_hours        integer NOT NULL,
    max_sales        integer NOT NULL,
    max_lease_total  numeric(18,2) NOT NULL,
    snapshot_id      uuid NOT NULL,
    chain_head       text NOT NULL DEFAULT '' CHECK (chain_head ~ '^([0-9a-f]{64})?$'),
    next_seq         integer NOT NULL CHECK (next_seq >= 1),
    key_id           uuid NOT NULL,
    revoked_at       timestamptz,
    CONSTRAINT offline_leases_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (device_id, organization_id)   REFERENCES public.devices (id, organization_id),
    FOREIGN KEY (shift_id, organization_id)    REFERENCES public.shifts (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)   REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (cashier_id, organization_id)  REFERENCES public.employees (id, organization_id),
    FOREIGN KEY (snapshot_id, organization_id) REFERENCES public.offline_snapshots (id, organization_id),
    FOREIGN KEY (key_id, organization_id)      REFERENCES public.device_offline_keys (id, organization_id),
    CHECK (expires_at > issued_at)
);
CREATE INDEX offline_leases_device_idx ON public.offline_leases (device_id, issued_at DESC);

-- One offline sale as the device sent it (D6, D9). `content` is stored exactly as signed.
CREATE TABLE public.offline_sales (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid NOT NULL,
    branch_id          uuid NOT NULL,
    device_id          uuid NOT NULL,
    lease_id           uuid,                                 -- NULL when the content named no lease of ours
    shift_id           uuid,                                 -- the lease's shift
    cashier_id         uuid,
    seq                integer NOT NULL CHECK (seq >= 1),
    number             text NOT NULL,
    idempotency_key    text NOT NULL,
    issued_at          timestamptz NOT NULL,
    content            text NOT NULL,
    content_hash       text NOT NULL CHECK (content_hash ~ '^[0-9a-f]{64}$'),
    signature          text NOT NULL,
    eta_uuid           text,
    previous_uuid      text,
    total              numeric(18,2) NOT NULL CHECK (total >= 0),
    source             text NOT NULL CHECK (source IN ('sync', 'import')),
    received_at        timestamptz NOT NULL DEFAULT now(),
    received_by        uuid,
    status             text NOT NULL DEFAULT 'received'
                       CHECK (status IN ('received', 'posted', 'conflict', 'duplicate', 'rejected')),
    conflict_code      text,
    fiscal_hold        text CHECK (fiscal_hold IN ('RECEIPT_MISMATCH', 'LEASE_REVOKED')),
    flags              text[] NOT NULL DEFAULT '{}',
    overrides          jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(overrides) = 'object'),
    sale_id            uuid,
    resolved_by        uuid,
    resolved_at        timestamptz,
    resolution_reason  text CHECK (length(resolution_reason) <= 500),
    CONSTRAINT offline_sales_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT offline_sales_seq_key UNIQUE (device_id, seq),
    CONSTRAINT offline_sales_idem_key UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (branch_id, organization_id)   REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (device_id, organization_id)   REFERENCES public.devices (id, organization_id),
    FOREIGN KEY (lease_id, organization_id)    REFERENCES public.offline_leases (id, organization_id),
    FOREIGN KEY (shift_id, organization_id)    REFERENCES public.shifts (id, organization_id),
    FOREIGN KEY (cashier_id, organization_id)  REFERENCES public.employees (id, organization_id),
    FOREIGN KEY (sale_id, organization_id)     REFERENCES public.sales (id, organization_id),
    CHECK ((status IN ('conflict', 'rejected')) = (conflict_code IS NOT NULL)),
    CHECK (status NOT IN ('posted', 'duplicate') OR sale_id IS NOT NULL)
);
CREATE INDEX offline_sales_status_idx ON public.offline_sales (organization_id, status, branch_id);
CREATE INDEX offline_sales_device_open_idx ON public.offline_sales (device_id, seq) WHERE status = 'received';
CREATE INDEX offline_sales_shift_idx ON public.offline_sales (shift_id) WHERE status IN ('received', 'conflict');

-- RLS: by shop (the baseline's rule; the functions check branch access), authenticated reads only
-- (writes are the functions'), and never the content or the signature (the review reads an
-- offline sale through the API with offline.resolve).
ALTER TABLE public.device_offline_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.offline_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.offline_leases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.offline_sales ENABLE ROW LEVEL SECURITY;
-- Read directly only within the caller's shop AND branches (app.has_branch_access, the rule every
-- S08 function applies), so a direct table read shows no more than the API does.
CREATE POLICY device_offline_keys_tenant_read ON public.device_offline_keys FOR SELECT TO authenticated
    USING (organization_id = (SELECT app.current_org_id())
           AND app.has_branch_access((SELECT d.branch_id FROM public.devices d WHERE d.id = device_id)));
CREATE POLICY offline_snapshots_tenant_read ON public.offline_snapshots FOR SELECT TO authenticated
    USING (organization_id = (SELECT app.current_org_id()) AND app.has_branch_access(branch_id));
CREATE POLICY offline_leases_tenant_read ON public.offline_leases FOR SELECT TO authenticated
    USING (organization_id = (SELECT app.current_org_id()) AND app.has_branch_access(branch_id));
CREATE POLICY offline_sales_tenant_read ON public.offline_sales FOR SELECT TO authenticated
    USING (organization_id = (SELECT app.current_org_id()) AND (SELECT app.has_permission('offline.resolve'))
           AND app.has_branch_access(branch_id));
-- The policies above call it as the caller (like app.has_permission): it answers only about the
-- caller's own branches.
GRANT EXECUTE ON FUNCTION app.has_branch_access(uuid) TO authenticated;
REVOKE ALL ON public.device_offline_keys, public.offline_snapshots, public.offline_leases, public.offline_sales
    FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.device_offline_keys, public.offline_snapshots, public.offline_leases TO authenticated;
GRANT SELECT (id, organization_id, branch_id, device_id, lease_id, shift_id, cashier_id, seq, number,
              idempotency_key, issued_at, content_hash, eta_uuid, previous_uuid, total, source, received_at,
              received_by, status, conflict_code, fiscal_hold, flags, overrides, sale_id, resolved_by,
              resolved_at, resolution_reason)
    ON public.offline_sales TO authenticated;

-- 4. Fiscal rows ---------------------------------------------------------------------------------

ALTER TABLE public.fiscal_submissions
    ADD COLUMN offline_sale_id     uuid,
    ADD COLUMN offline_released_at timestamptz,
    ADD FOREIGN KEY (offline_sale_id, organization_id) REFERENCES public.offline_sales (id, organization_id);
-- The baseline's two checks named exactly one of sale_id / return_id; an offline receipt has
-- neither until its sale is posted (and keeps its offline_sale_id after).
ALTER TABLE public.fiscal_submissions
    DROP CONSTRAINT fiscal_submissions_check,
    DROP CONSTRAINT fiscal_submissions_check1,
    ADD CONSTRAINT fiscal_submissions_one_document_check CHECK (num_nonnulls(sale_id, return_id) <= 1),
    ADD CONSTRAINT fiscal_submissions_has_document_check CHECK (num_nonnulls(sale_id, return_id, offline_sale_id) >= 1),
    ADD CONSTRAINT fiscal_submissions_doc_type_check
        CHECK ((doc_type IN ('b2c_receipt', 'b2b_invoice')) = (sale_id IS NOT NULL OR offline_sale_id IS NOT NULL)),
    ADD CONSTRAINT fiscal_submissions_offline_not_return_check CHECK (return_id IS NULL OR offline_sale_id IS NULL);
CREATE UNIQUE INDEX fiscal_submissions_offline_sale_idx ON public.fiscal_submissions (offline_sale_id)
    WHERE offline_sale_id IS NOT NULL;
GRANT SELECT (offline_sale_id, offline_released_at) ON public.fiscal_submissions TO authenticated;

-- T03's event log: its rows are status changes (kind NULL). S08 adds kinds for what is not a
-- status change of the receipt.
ALTER TABLE public.fiscal_events
    ADD COLUMN kind text CHECK (kind IN ('offline_received', 'offline_released', 'offline_verify_failed',
                                         'offline_duplicate', 'chain_fork'));

-- 5. Helpers (schema app, no grants) -------------------------------------------------------------

-- T02's cleanText (contracts/src/eta/serialize.ts) in SQL: the receipt's text for a value.
CREATE FUNCTION app.offline_clean(p_value text, p_max integer)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT btrim(left(btrim(regexp_replace(regexp_replace(translate(
               translate(COALESCE(p_value, ''), '"“”', ''''''''), '\', '/'),
               '[[:cntrl:]]', ' ', 'g'), '\s+', ' ', 'g')), p_max))
$$;

-- The content as jsonb, or NULL when it is not JSON.
CREATE FUNCTION app.offline_try_jsonb(p_text text)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
BEGIN
    RETURN p_text::jsonb;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

-- An offline sale's content, checked for shape (protocol v1, D6). Raises UNSUPPORTED_VERSION for a
-- version this server does not know (the device keeps the sale) and INVALID_CONTENT otherwise.
CREATE FUNCTION app.offline_content(p_content text)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE
    c jsonb := app.offline_try_jsonb(p_content); l jsonb; p jsonb; v_money text := '^\d{1,16}(\.\d{1,2})?$';
BEGIN
    IF c IS NULL OR jsonb_typeof(c) <> 'object' OR jsonb_typeof(c -> 'v') IS DISTINCT FROM 'number' THEN
        RAISE EXCEPTION 'INVALID_CONTENT' USING ERRCODE = 'P0001';
    END IF;
    IF (c ->> 'v') <> '1' THEN
        RAISE EXCEPTION 'UNSUPPORTED_VERSION' USING ERRCODE = 'P0001';
    END IF;
    IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(c) k) <> ARRAY['cashier_id', 'device_id',
           'idempotency_key', 'issued_at', 'lease_id', 'lines', 'number', 'payments', 'receipt', 'seq',
           'subtotal', 'tax_total', 'total', 'v']
       OR jsonb_typeof(c -> 'seq') <> 'number' OR (c ->> 'seq') !~ '^[1-9][0-9]{0,8}$'
       OR (c ->> 'number') !~ '^OFF-D[1-9][0-9]{0,5}-[0-9]{6,}$'
       OR (c ->> 'issued_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
       OR (c ->> 'subtotal') !~ v_money OR (c ->> 'tax_total') !~ v_money OR (c ->> 'total') !~ v_money
       OR (c ->> 'total')::numeric <= 0
       OR jsonb_typeof(c -> 'lines') <> 'array' OR jsonb_array_length(c -> 'lines') NOT BETWEEN 1 AND 100
       OR jsonb_typeof(c -> 'payments') <> 'array' OR jsonb_array_length(c -> 'payments') <> 1
       OR jsonb_typeof(c -> 'receipt') NOT IN ('object', 'null') THEN
        RAISE EXCEPTION 'INVALID_CONTENT' USING ERRCODE = 'P0001';
    END IF;
    PERFORM (c ->> 'lease_id')::uuid, (c ->> 'device_id')::uuid, (c ->> 'idempotency_key')::uuid,
            (c ->> 'cashier_id')::uuid, (c ->> 'issued_at')::timestamptz;
    FOR l IN SELECT jsonb_array_elements(c -> 'lines') LOOP
        IF jsonb_typeof(l) <> 'object'
           OR (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(l) k) <> ARRAY['line_total', 'product_id',
                  'quantity', 'tax_amount', 'tax_rate', 'unit_id', 'unit_price']
           OR jsonb_typeof(l -> 'quantity') <> 'number' OR (l ->> 'quantity') !~ '^[1-9][0-9]{0,5}$'
           OR (l ->> 'quantity')::integer > 100000
           OR (l ->> 'unit_price') !~ v_money OR (l ->> 'tax_amount') !~ v_money OR (l ->> 'line_total') !~ v_money
           OR (l ->> 'tax_rate') !~ '^\d{1,3}(\.\d{1,2})?$' OR (l ->> 'tax_rate')::numeric > 100
           OR jsonb_typeof(l -> 'unit_id') NOT IN ('string', 'null')
           OR (jsonb_typeof(l -> 'unit_id') = 'string' AND (l ->> 'quantity') <> '1') THEN
            RAISE EXCEPTION 'INVALID_CONTENT' USING ERRCODE = 'P0001';
        END IF;
        PERFORM (l ->> 'product_id')::uuid, (l ->> 'unit_id')::uuid;
    END LOOP;
    p := c -> 'payments' -> 0;
    IF jsonb_typeof(p) <> 'object'
       OR (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p) k) <> ARRAY['amount', 'change', 'method', 'tendered']
       OR (p ->> 'method') IS DISTINCT FROM 'cash'
       OR (p ->> 'amount') !~ v_money OR (p ->> 'tendered') !~ v_money OR (p ->> 'change') !~ v_money THEN
        RAISE EXCEPTION 'INVALID_CONTENT' USING ERRCODE = 'P0001';
    END IF;
    RETURN c;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range OR datetime_field_overflow
         OR invalid_datetime_format THEN
        RAISE EXCEPTION 'INVALID_CONTENT' USING ERRCODE = 'P0001';
END;
$$;

-- Whether ETA receipts are made for the shop now (T02's rule: settings on and the plan's module).
CREATE FUNCTION app.offline_eta_on(p_org uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE((SELECT s.is_enabled FROM public.eta_settings s WHERE s.organization_id = p_org), false)
           AND app.org_has_module(p_org, 'eta')
$$;

-- A problem someone must look at: a critical audit row (the API also sends it to Sentry). Ids,
-- numbers and codes only, never the content or the signature.
CREATE FUNCTION app.offline_alert(p_org uuid, p_branch uuid, p_entity uuid, p_code text, p_details jsonb DEFAULT '{}')
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    PERFORM app.write_audit('offline.alert', 'offline_sale', p_entity, NULL,
        jsonb_build_object('code', p_code) || COALESCE(p_details, '{}'::jsonb), NULL, p_branch,
        'critical'::public.audit_severity, p_org);
END;
$$;

-- One fiscal_events row of an S08 kind for a receipt.
CREATE FUNCTION app.offline_event(p_fiscal_id uuid, p_kind text, p_message text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    INSERT INTO public.fiscal_events (organization_id, fiscal_id, old_status, new_status, eta_uuid, message,
                                      actor_employee_id, kind)
    SELECT f.organization_id, f.id, f.status, f.status, f.eta_uuid, left(p_message, 500),
           app.current_employee_id(), p_kind
    FROM public.fiscal_submissions f WHERE f.id = p_fiscal_id;
END;
$$;

-- What a device may sell offline in a branch now (D3): every active product with the walk-in price,
-- the tax and ETA data its receipt needs, and the branch's sellable stock (units for a serialized
-- product). Never a cost, supplier or margin. Sorted, so the same content hashes the same.
CREATE FUNCTION app.offline_snapshot_data(p_org uuid, p_branch uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'branch_id', p_branch,
        'prices_include_vat', COALESCE((SELECT s.prices_include_vat FROM public.org_settings s
                                        WHERE s.organization_id = p_org), true),
        'eta_enabled', app.offline_eta_on(p_org),
        'products', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', p.id, 'name_ar', p.name_ar, 'name_en', p.name_en, 'sku', p.sku,
                'barcodes', CASE WHEN p.barcode IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(p.barcode) END,
                'price', CASE WHEN p.cash_price > 0 THEN p.cash_price::numeric(18,2)::text END,
                'tax_class_id', p.tax_class_id, 'tax_rate', t.rate::numeric(5,2)::text,
                'eta_tax_type', t.eta_tax_type, 'eta_subtype', t.eta_subtype,
                'eta_item_code', p.eta_item_code, 'eta_item_type', p.eta_item_type, 'unit_type', 'EA',
                'is_serialized', p.is_serialized,
                'on_hand', CASE WHEN NOT p.is_serialized THEN GREATEST(COALESCE((
                    SELECT sum(sl.on_hand - sl.reserved) FROM public.stock_levels sl
                    WHERE sl.organization_id = p_org AND sl.product_id = p.id AND sl.branch_id = p_branch
                      AND sl.stock_state = 'sellable'), 0), 0)::integer END,
                'units', CASE WHEN p.is_serialized THEN COALESCE((
                    SELECT jsonb_agg(jsonb_build_object('unit_id', u.id, 'serial', u.serial) ORDER BY u.serial, u.id)
                    FROM public.units u
                    WHERE u.organization_id = p_org AND u.product_id = p.id AND u.branch_id = p_branch
                      AND u.status = 'in_stock'), '[]'::jsonb) ELSE '[]'::jsonb END,
                'offline_sellable', x.reason IS NULL, 'reason', x.reason) ORDER BY p.id)
            FROM public.products p
            JOIN public.tax_classes t ON t.id = p.tax_class_id AND t.organization_id = p.organization_id
            CROSS JOIN LATERAL (SELECT CASE
                WHEN app.offline_eta_on(p_org) AND (NULLIF(btrim(p.eta_item_code), '') IS NULL
                     OR p.eta_item_type IS NULL) THEN 'NO_ETA_CODE'
                WHEN p.cash_price <= 0 THEN 'NO_PRICE' END AS reason) x
            WHERE p.organization_id = p_org AND p.is_active AND p.archived_at IS NULL), '[]'::jsonb))
$$;

-- The seller block of the shop's receipts for a branch (T02's ReceiptSource.seller).
CREATE FUNCTION app.offline_seller_json(p_org uuid, p_branch uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'rin', o.tax_registration_no, 'name', COALESCE(NULLIF(btrim(o.legal_name), ''), o.name),
        'activity_code', es.activity_code, 'branch_code', b.eta_branch_code,
        'governorate', b.governorate, 'city', b.city, 'street', b.address, 'building_number', b.building_number)
    FROM public.organizations o
    JOIN public.branches b ON b.organization_id = o.id AND b.id = p_branch
    LEFT JOIN public.eta_settings es ON es.organization_id = o.id
    WHERE o.id = p_org
$$;

CREATE FUNCTION app.offline_settings_json(p_org uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object('offline_enabled', s.offline_enabled,
                              'offline_max_sale_total', s.offline_max_sale_total::text,
                              'offline_max_hours', s.offline_max_hours, 'offline_max_sales', s.offline_max_sales,
                              'offline_max_lease_total', s.offline_max_lease_total::text)
    FROM public.org_settings s WHERE s.organization_id = p_org
$$;

-- An offline sale for the review (no content, no signature).
CREATE FUNCTION app.offline_sale_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', o.id, 'number', o.number, 'seq', o.seq, 'device_id', o.device_id, 'device_name', d.name,
        'branch_id', o.branch_id, 'branch_name', b.name, 'shift_id', o.shift_id, 'cashier_id', o.cashier_id,
        'cashier_name', e.full_name, 'issued_at', o.issued_at, 'received_at', o.received_at,
        'total', o.total::text, 'source', o.source, 'status', o.status, 'conflict_code', o.conflict_code,
        'fiscal_hold', o.fiscal_hold, 'flags', to_jsonb(o.flags), 'sale_id', o.sale_id,
        'resolved_at', o.resolved_at, 'resolution_reason', o.resolution_reason)
    FROM public.offline_sales o
    LEFT JOIN public.devices d ON d.id = o.device_id AND d.organization_id = o.organization_id
    LEFT JOIN public.branches b ON b.id = o.branch_id AND b.organization_id = o.organization_id
    LEFT JOIN public.employees e ON e.id = o.cashier_id AND e.organization_id = o.organization_id
    WHERE o.organization_id = p_org AND o.id = p_id
$$;

-- 6. The lease (D2, D3, D5) ----------------------------------------------------------------------

-- The caller's lease on this device: needs sale.create, a paired device with its open shift, that
-- shift being the caller's, offline on for the shop (and the pos module), and when ETA is on an
-- ETA-active device and complete seller data. Registers the device's public key, gives the device
-- its offline code, reuses or stores the snapshot. The snapshot data is answered only when the
-- device's hash differs.
CREATE FUNCTION public.issue_offline_lease(p_public_key text, p_snapshot_hash text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_device_id uuid; v_d public.devices; v_s public.shifts; v_set public.org_settings;
    v_key public.device_offline_keys; v_eta boolean; v_seller jsonb; v_data jsonb; v_hash text; v_snap uuid;
    v_lease public.offline_leases; v_code text; v_new_key boolean := false;
BEGIN
    v_emp := app.require_permission('sale.create');
    v_org := app.current_org_id();
    v_device_id := app.current_device_id();
    IF v_device_id IS NULL THEN
        RAISE EXCEPTION 'DEVICE_REVOKED' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO v_s FROM public.shifts s
    WHERE s.organization_id = v_org AND s.device_id = v_device_id AND s.status = 'open'
    ORDER BY s.opened_at DESC LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHIFT_NOT_FOUND: no open shift on this device' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_shift_device(v_s.id);
    IF v_s.employee_id <> v_emp THEN
        RAISE EXCEPTION 'OFFLINE_NOT_SHIFT_OWNER' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_set FROM public.org_settings s WHERE s.organization_id = v_org;
    IF NOT COALESCE(v_set.offline_enabled, false) OR NOT app.org_has_module(v_org, 'pos') THEN
        RAISE EXCEPTION 'OFFLINE_DISABLED' USING ERRCODE = 'P0001';
    END IF;
    IF p_public_key IS NULL OR p_public_key !~ '^[A-Za-z0-9+/]+={0,2}$' OR length(p_public_key) NOT BETWEEN 80 AND 400
       OR (p_snapshot_hash IS NOT NULL AND p_snapshot_hash !~ '^[0-9a-f]{64}$') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: offline lease' USING ERRCODE = 'P0001';
    END IF;

    -- Device and shop rows locked: the offline code is unique in the shop.
    PERFORM 1 FROM public.organizations o WHERE o.id = v_org FOR UPDATE;
    SELECT * INTO v_d FROM public.devices d WHERE d.id = v_device_id FOR UPDATE;
    v_eta := app.offline_eta_on(v_org);
    v_seller := app.offline_seller_json(v_org, v_s.branch_id);
    IF v_eta AND (v_d.eta_status <> 'active' OR NULLIF(btrim(v_d.eta_serial), '') IS NULL
        OR COALESCE(regexp_replace(v_seller ->> 'rin', '\D', '', 'g'), '') !~ '^\d{9}$'
        OR NULLIF(btrim(v_seller ->> 'activity_code'), '') IS NULL
        OR NULLIF(btrim(v_seller ->> 'branch_code'), '') IS NULL
        OR NULLIF(btrim(v_seller ->> 'building_number'), '') IS NULL
        OR NULLIF(btrim(v_seller ->> 'name'), '') IS NULL OR NULLIF(btrim(v_seller ->> 'governorate'), '') IS NULL
        OR NULLIF(btrim(v_seller ->> 'city'), '') IS NULL OR NULLIF(btrim(v_seller ->> 'street'), '') IS NULL) THEN
        RAISE EXCEPTION 'OFFLINE_ETA_NOT_READY' USING ERRCODE = 'P0001';
    END IF;

    IF v_d.offline_code IS NULL THEN
        SELECT 'D' || (COALESCE(max(substring(d.offline_code FROM 2)::integer), 0) + 1)::text INTO v_code
        FROM public.devices d WHERE d.organization_id = v_org AND d.offline_code IS NOT NULL;
        UPDATE public.devices d SET offline_code = v_code WHERE d.id = v_device_id RETURNING * INTO v_d;
    END IF;

    SELECT * INTO v_key FROM public.device_offline_keys k WHERE k.device_id = v_device_id AND k.public_key = p_public_key;
    IF NOT FOUND THEN
        INSERT INTO public.device_offline_keys (organization_id, device_id, public_key)
        VALUES (v_org, v_device_id, p_public_key) RETURNING * INTO v_key;
        v_new_key := true;
    END IF;

    v_data := app.offline_snapshot_data(v_org, v_s.branch_id);
    v_hash := encode(sha256(convert_to(v_data::text, 'UTF8')), 'hex');
    INSERT INTO public.offline_snapshots (organization_id, branch_id, content_hash, data)
    VALUES (v_org, v_s.branch_id, v_hash, v_data)
    ON CONFLICT (branch_id, content_hash) DO NOTHING;
    SELECT s.id INTO v_snap FROM public.offline_snapshots s WHERE s.branch_id = v_s.branch_id AND s.content_hash = v_hash;

    INSERT INTO public.offline_leases (organization_id, device_id, shift_id, branch_id, cashier_id, issued_at,
                                       expires_at, max_sale_total, max_hours, max_sales, max_lease_total,
                                       snapshot_id, chain_head, next_seq, key_id)
    VALUES (v_org, v_device_id, v_s.id, v_s.branch_id, v_s.employee_id, now(),
            now() + make_interval(hours => v_set.offline_max_hours), v_set.offline_max_sale_total,
            v_set.offline_max_hours, v_set.offline_max_sales, v_set.offline_max_lease_total, v_snap,
            COALESCE(v_d.eta_last_uuid, ''), v_d.offline_seq_last + 1, v_key.id)
    RETURNING * INTO v_lease;

    IF v_new_key THEN
        PERFORM app.write_audit('device.offline_key_added', 'device', v_device_id, NULL,
            jsonb_build_object('key_id', v_key.id), NULL, v_s.branch_id);
    END IF;
    PERFORM app.write_audit('offline_lease.issued', 'offline_lease', v_lease.id, NULL,
        jsonb_build_object('device_id', v_device_id, 'shift_id', v_s.id, 'expires_at', v_lease.expires_at,
                           'next_seq', v_lease.next_seq, 'snapshot_id', v_snap, 'key_id', v_key.id),
        NULL, v_s.branch_id);

    RETURN jsonb_build_object(
        'lease', jsonb_build_object(
            'id', v_lease.id, 'device_id', v_device_id, 'shift_id', v_s.id, 'branch_id', v_s.branch_id,
            'cashier_id', v_s.employee_id, 'issued_at', v_lease.issued_at, 'expires_at', v_lease.expires_at,
            'limits', jsonb_build_object('max_sale_total', v_lease.max_sale_total::text,
                                         'max_hours', v_lease.max_hours, 'max_sales', v_lease.max_sales,
                                         'max_lease_total', v_lease.max_lease_total::text),
            'snapshot_id', v_snap, 'snapshot_hash', v_hash, 'chain_head', v_lease.chain_head,
            'next_seq', v_lease.next_seq, 'key_id', v_key.id),
        'offline_code', v_d.offline_code,
        'server_time', clock_timestamp(),
        'snapshot', CASE WHEN p_snapshot_hash IS DISTINCT FROM v_hash THEN v_data END,
        'eta', jsonb_build_object(
            'enabled', v_eta,
            'environment', CASE WHEN v_eta THEN (SELECT s.environment FROM public.eta_settings s
                                                 WHERE s.organization_id = v_org) END,
            'seller', CASE WHEN v_eta THEN v_seller END,
            'device_serial', CASE WHEN v_eta THEN v_d.eta_serial END));
END;
$$;

-- 7. Receive (D8, D9, D13) -----------------------------------------------------------------------

-- One item of a sync or an import, for a device whose row the caller has locked FOR UPDATE.
-- Answers {index, seq, result, code}. Nothing is stored for a duplicate, a reused sequence, a
-- content that is not ours to read, or a version this server doesn't know (the device keeps it).
CREATE FUNCTION app.offline_receive(p_org uuid, p_device_id uuid, p_item jsonb, p_index integer, p_source text,
                                    p_emp uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_content text; v_signature text; c jsonb; v_r jsonb; v_hash text; v_existing text; v_seq integer;
    v_d public.devices; v_lease public.offline_leases; v_b public.branches; v_org_rin text;
    v_id uuid; v_issued timestamptz; v_hold text; v_ok boolean; v_fiscal uuid; v_flags text[] := '{}';
    v_mismatch boolean := false; v_head text; v_prev text; v_uuid text; i integer; l jsonb; v_item jsonb;
    v_sku text;
BEGIN
    v_content := p_item ->> 'content';
    v_signature := p_item ->> 'signature';
    IF jsonb_typeof(p_item) <> 'object' OR jsonb_typeof(p_item -> 'content') IS DISTINCT FROM 'string'
       OR jsonb_typeof(p_item -> 'signature') IS DISTINCT FROM 'string'
       OR length(v_content) NOT BETWEEN 2 AND 200000
       OR v_signature !~ '^[A-Za-z0-9+/]+={0,2}$' OR length(v_signature) NOT BETWEEN 40 AND 200 THEN
        RETURN jsonb_build_object('index', p_index, 'seq', NULL, 'result', 'rejected', 'code', 'INVALID_CONTENT');
    END IF;
    BEGIN
        c := app.offline_content(v_content);
    EXCEPTION WHEN others THEN
        IF SQLERRM LIKE 'UNSUPPORTED_VERSION%' THEN
            RETURN jsonb_build_object('index', p_index, 'seq', NULL, 'result', 'retry_later',
                                      'code', 'UNSUPPORTED_VERSION');
        END IF;
        RETURN jsonb_build_object('index', p_index, 'seq', NULL, 'result', 'rejected', 'code', 'INVALID_CONTENT');
    END;
    v_seq := (c ->> 'seq')::integer;
    IF (c ->> 'device_id')::uuid <> p_device_id THEN
        RETURN jsonb_build_object('index', p_index, 'seq', v_seq, 'result', 'rejected', 'code', 'NOT_OURS');
    END IF;

    -- Duplicates: the same (device, seq) is stored once.
    v_hash := encode(sha256(convert_to(v_content, 'UTF8')), 'hex');
    SELECT o.content_hash INTO v_existing FROM public.offline_sales o WHERE o.device_id = p_device_id AND o.seq = v_seq;
    IF FOUND THEN
        IF v_existing = v_hash THEN
            RETURN jsonb_build_object('index', p_index, 'seq', v_seq, 'result', 'duplicate', 'code', NULL);
        END IF;
        PERFORM app.offline_alert(p_org, (SELECT d.branch_id FROM public.devices d WHERE d.id = p_device_id), NULL,
            'SEQ_REUSED', jsonb_build_object('device_id', p_device_id, 'seq', v_seq, 'number', c ->> 'number'));
        RETURN jsonb_build_object('index', p_index, 'seq', v_seq, 'result', 'rejected', 'code', 'SEQ_REUSED');
    END IF;

    SELECT * INTO v_d FROM public.devices d WHERE d.id = p_device_id;
    SELECT * INTO v_b FROM public.branches b WHERE b.id = v_d.branch_id;
    SELECT * INTO v_lease FROM public.offline_leases l
    WHERE l.id = (c ->> 'lease_id')::uuid AND l.organization_id = p_org AND l.device_id = p_device_id;
    v_issued := (c ->> 'issued_at')::timestamptz;
    v_r := c -> 'receipt';

    -- Ownership: our lease and cashier, our tax number, POS serial and branch code on the receipt.
    v_ok := v_lease.id IS NOT NULL AND (c ->> 'cashier_id')::uuid = v_lease.cashier_id;
    IF v_ok AND jsonb_typeof(v_r) = 'object' THEN
        SELECT regexp_replace(COALESCE(o.tax_registration_no, ''), '\D', '', 'g') INTO v_org_rin
        FROM public.organizations o WHERE o.id = p_org;
        v_ok := (v_r #>> '{seller,rin}') IS NOT DISTINCT FROM v_org_rin
            AND (v_r #>> '{seller,deviceSerialNumber}') IS NOT DISTINCT FROM app.offline_clean(v_d.eta_serial, 100)
            AND (v_r #>> '{seller,branchCode}') IS NOT DISTINCT FROM app.offline_clean(v_b.eta_branch_code, 50);
    END IF;

    BEGIN
        INSERT INTO public.offline_sales (organization_id, branch_id, device_id, lease_id, shift_id, cashier_id, seq,
                                          number, idempotency_key, issued_at, content, content_hash, signature,
                                          eta_uuid, previous_uuid, total, source, received_by, status, conflict_code)
        VALUES (p_org, COALESCE(CASE WHEN v_ok THEN v_lease.branch_id END, v_d.branch_id), p_device_id,
                CASE WHEN v_ok THEN v_lease.id END, CASE WHEN v_ok THEN v_lease.shift_id END,
                CASE WHEN v_ok THEN v_lease.cashier_id END, v_seq, c ->> 'number', c ->> 'idempotency_key', v_issued,
                v_content, v_hash, v_signature, v_r #>> '{header,uuid}', v_r #>> '{header,previousUUID}',
                (c ->> 'total')::numeric, p_source, p_emp,
                CASE WHEN v_ok THEN 'received' ELSE 'rejected' END, CASE WHEN v_ok THEN NULL ELSE 'NOT_OURS' END)
        RETURNING id INTO v_id;
    EXCEPTION WHEN unique_violation THEN
        -- Another offline sale already carries this idempotency key: not a sale of its own.
        RAISE EXCEPTION 'OFFLINE_KEY_REUSED' USING ERRCODE = 'P0001';
    END;

    -- The device's sequence: a gap is flagged (sales missing in between), the last one only grows.
    IF v_seq > v_d.offline_seq_last + 1 THEN
        v_flags := v_flags || 'seq_gap'::text;
        PERFORM app.offline_alert(p_org, v_d.branch_id, v_id, 'SEQ_GAP',
            jsonb_build_object('device_id', p_device_id, 'missing_from', v_d.offline_seq_last + 1,
                               'missing_to', v_seq - 1));
    END IF;
    UPDATE public.devices d SET offline_seq_last = GREATEST(d.offline_seq_last, v_seq) WHERE d.id = p_device_id;

    IF NOT v_ok THEN
        UPDATE public.offline_sales o SET flags = v_flags WHERE o.id = v_id;
        PERFORM app.offline_alert(p_org, v_d.branch_id, v_id, 'NOT_OURS',
            jsonb_build_object('device_id', p_device_id, 'seq', v_seq, 'number', c ->> 'number'));
        RETURN jsonb_build_object('index', p_index, 'seq', v_seq, 'result', 'rejected', 'code', 'NOT_OURS');
    END IF;

    -- The receipt must be the printed form of this sale (D9 step 6).
    IF jsonb_typeof(v_r) = 'object' THEN
        BEGIN
            v_mismatch := (v_r ->> 'totalAmount')::numeric IS DISTINCT FROM (c ->> 'total')::numeric
                OR jsonb_typeof(v_r -> 'itemData') IS DISTINCT FROM 'array'
                OR jsonb_array_length(v_r -> 'itemData') <> jsonb_array_length(c -> 'lines')
                OR (v_r #>> '{header,receiptNumber}') IS DISTINCT FROM (c ->> 'number')
                OR (v_r #>> '{header,dateTimeIssued}') IS DISTINCT FROM (c ->> 'issued_at')
                OR COALESCE(v_r #>> '{header,uuid}', '-') !~ '^[0-9a-f]{64}$'
                OR COALESCE(v_r #>> '{header,previousUUID}', '-') !~ '^([0-9a-f]{64})?$';
            IF NOT v_mismatch THEN
                FOR i IN 0..jsonb_array_length(c -> 'lines') - 1 LOOP
                    l := c -> 'lines' -> i;
                    v_item := v_r -> 'itemData' -> i;
                    SELECT p.sku INTO v_sku FROM public.products p
                    WHERE p.id = (l ->> 'product_id')::uuid AND p.organization_id = p_org;
                    IF (v_item ->> 'quantity')::numeric IS DISTINCT FROM (l ->> 'quantity')::numeric
                       OR (v_item ->> 'internalCode') IS DISTINCT FROM app.offline_clean(v_sku, 50) THEN
                        v_mismatch := true;
                    END IF;
                END LOOP;
            END IF;
        EXCEPTION WHEN others THEN
            v_mismatch := true;
        END;
        IF v_mismatch THEN
            v_hold := 'RECEIPT_MISMATCH';
            PERFORM app.offline_alert(p_org, v_d.branch_id, v_id, 'offline.bug',
                jsonb_build_object('reason', 'RECEIPT_MISMATCH', 'number', c ->> 'number'));
        END IF;
    END IF;
    -- A lease revoked before the sale was made (a lost or stolen device): the manager decides.
    IF v_hold IS NULL AND v_lease.revoked_at IS NOT NULL AND v_lease.revoked_at < v_issued THEN
        v_hold := 'LEASE_REVOKED';
    END IF;
    UPDATE public.offline_sales o SET fiscal_hold = v_hold, flags = v_flags WHERE o.id = v_id;

    -- The fiscal row carries the printed receipt exactly (its JSON text from the content), and the
    -- device's chain head follows the receipts in sequence order (D8).
    IF jsonb_typeof(v_r) = 'object' AND app.offline_eta_on(p_org) THEN
        v_uuid := v_r #>> '{header,uuid}';
        v_prev := COALESCE(v_r #>> '{header,previousUUID}', '');
        BEGIN
            INSERT INTO public.fiscal_submissions (organization_id, branch_id, device_id, doc_type, sale_id,
                                                   offline_sale_id, environment, internal_id, eta_uuid,
                                                   previous_uuid, payload, status, created_by)
            VALUES (p_org, v_d.branch_id, p_device_id, 'b2c_receipt', NULL, v_id,
                    (SELECT s.environment FROM public.eta_settings s WHERE s.organization_id = p_org),
                    c ->> 'number', v_uuid, v_prev,
                    jsonb_build_object('receipt_json', (v_content::json -> 'receipt')::text), 'pending', p_emp)
            RETURNING id INTO v_fiscal;
        EXCEPTION WHEN unique_violation THEN
            -- Another receipt already has this UUID: not this device's receipt.
            RAISE EXCEPTION 'OFFLINE_UUID_TAKEN' USING ERRCODE = 'P0001';
        END;
        PERFORM app.offline_event(v_fiscal, 'offline_received', c ->> 'number');
        v_head := COALESCE(v_d.eta_last_uuid, '');
        IF v_head <> v_prev THEN
            PERFORM app.offline_event(v_fiscal, 'chain_fork', 'head=' || v_head || ' previous=' || v_prev);
        END IF;
        UPDATE public.devices d SET eta_last_uuid = v_uuid WHERE d.id = p_device_id;
    END IF;

    PERFORM app.eta_enqueue(p_org, 'offline.process', 'offline.process:' || p_device_id::text,
        jsonb_build_object('device_id', p_device_id));
    RETURN jsonb_build_object('index', p_index, 'seq', v_seq, 'result', 'received', 'code', v_hold);
END;
$$;

-- The items of one request, in sequence order (the device row locked once), answered in request
-- order. An item whose receipt UUID or idempotency key another sale holds is rejected alone (its
-- savepoint): UUID_TAKEN, KEY_REUSED.
CREATE FUNCTION app.offline_receive_all(p_org uuid, p_device_id uuid, p_items jsonb, p_source text, p_emp uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r record; v_out jsonb := '[]'::jsonb; v_res jsonb;
BEGIN
    PERFORM 1 FROM public.devices d WHERE d.id = p_device_id FOR UPDATE;
    FOR r IN
        SELECT e.item, (e.idx - 1)::integer AS idx,
               CASE WHEN (app.offline_try_jsonb(e.item ->> 'content') ->> 'seq') ~ '^[1-9][0-9]{0,8}$'
                    THEN (app.offline_try_jsonb(e.item ->> 'content') ->> 'seq')::integer END AS seq
        FROM jsonb_array_elements(p_items) WITH ORDINALITY e(item, idx)
        ORDER BY 3 NULLS LAST, 2
    LOOP
        BEGIN
            v_res := app.offline_receive(p_org, p_device_id, r.item, r.idx, p_source, p_emp);
        EXCEPTION WHEN others THEN
            IF SQLERRM NOT LIKE 'OFFLINE_UUID_TAKEN%' AND SQLERRM NOT LIKE 'OFFLINE_KEY_REUSED%' THEN
                RAISE;
            END IF;
            v_res := jsonb_build_object('index', r.idx, 'seq', r.seq, 'result', 'rejected',
                                        'code', CASE WHEN SQLERRM LIKE 'OFFLINE_UUID_TAKEN%' THEN 'UUID_TAKEN'
                                                     ELSE 'KEY_REUSED' END);
            PERFORM app.offline_alert(p_org, (SELECT d.branch_id FROM public.devices d WHERE d.id = p_device_id),
                NULL, v_res ->> 'code', jsonb_build_object('device_id', p_device_id, 'seq', r.seq));
        END;
        v_out := v_out || v_res;
    END LOOP;
    RETURN (SELECT jsonb_agg(x ORDER BY (x ->> 'index')::integer) FROM jsonb_array_elements(v_out) x);
END;
$$;

-- POST /api/offline/sync: the device sends its own sales (1 to 50). Needs sale.create and the
-- paired device of every item; the shift need not be open (a printed receipt is always received).
CREATE FUNCTION public.sync_offline_sales(p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_device uuid; v_item jsonb; v_c jsonb; v_out jsonb; v_branch uuid;
BEGIN
    v_emp := app.require_permission('sale.create');
    v_org := app.current_org_id();
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 50 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: 1 to 50 items' USING ERRCODE = 'P0001';
    END IF;
    v_device := app.current_device_id();
    IF v_device IS NULL THEN
        RAISE EXCEPTION 'DEVICE_REVOKED' USING ERRCODE = '42501';
    END IF;
    FOR v_item IN SELECT jsonb_array_elements(p_items) LOOP
        v_c := app.offline_try_jsonb(v_item ->> 'content');
        IF (v_c ->> 'device_id') IS NOT NULL AND (v_c ->> 'device_id') <> v_device::text THEN
            RAISE EXCEPTION 'DEVICE_MISMATCH' USING ERRCODE = '42501';
        END IF;
    END LOOP;
    SELECT d.branch_id INTO v_branch FROM public.devices d WHERE d.id = v_device;
    v_out := app.offline_receive_all(v_org, v_device, p_items, 'sync', v_emp);
    PERFORM app.write_audit('offline_sales.synced', 'device', v_device, NULL,
        jsonb_build_object('items', jsonb_array_length(p_items),
                           'received', (SELECT count(*) FROM jsonb_array_elements(v_out) x WHERE x ->> 'result' = 'received'),
                           'duplicate', (SELECT count(*) FROM jsonb_array_elements(v_out) x WHERE x ->> 'result' = 'duplicate'),
                           'rejected', (SELECT count(*) FROM jsonb_array_elements(v_out) x WHERE x ->> 'result' = 'rejected'),
                           'retry_later', (SELECT count(*) FROM jsonb_array_elements(v_out) x WHERE x ->> 'result' = 'retry_later')),
        NULL, v_branch);
    RETURN jsonb_build_object('results', v_out);
END;
$$;

-- POST /api/offline/import: a manager imports a device's exported file (1 to 500). The same steps
-- as a sync; the worker's signature check is what refuses an edited file.
CREATE FUNCTION public.import_offline_sales(p_device_id uuid, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_d public.devices; v_out jsonb;
BEGIN
    v_emp := app.require_permission('offline.resolve');
    v_org := app.current_org_id();
    SELECT * INTO v_d FROM public.devices d WHERE d.id = p_device_id AND d.organization_id = v_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DEVICE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_d.branch_id);
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: 1 to 500 items' USING ERRCODE = 'P0001';
    END IF;
    v_out := app.offline_receive_all(v_org, p_device_id, p_items, 'import', v_emp);
    PERFORM app.write_audit('offline_sales.imported', 'device', p_device_id, NULL,
        jsonb_build_object('items', jsonb_array_length(p_items),
                           'received', (SELECT count(*) FROM jsonb_array_elements(v_out) x WHERE x ->> 'result' = 'received'),
                           'rejected', (SELECT count(*) FROM jsonb_array_elements(v_out) x WHERE x ->> 'result' = 'rejected')),
        NULL, v_d.branch_id, 'warning'::public.audit_severity);
    RETURN jsonb_build_object('results', v_out);
END;
$$;

-- 8. Process (D10, service role) -----------------------------------------------------------------

-- The device's received sales, oldest sequence first, with what the worker verifies: the content
-- and signature, the lease's public key, the receipt's JSON text and its stored UUID.
CREATE FUNCTION app.offline_load_received(p_device_id uuid, p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', o.id, 'organization_id', o.organization_id, 'device_id', o.device_id, 'seq', o.seq,
               'number', o.number, 'content', o.content, 'signature', o.signature, 'eta_uuid', o.eta_uuid,
               'public_key', k.public_key, 'environment', f.environment,
               'receipt_json', CASE WHEN json_typeof(o.content::json -> 'receipt') = 'object'
                                    THEN (o.content::json -> 'receipt')::text END) ORDER BY o.seq), '[]'::jsonb)
    FROM (SELECT * FROM public.offline_sales x WHERE x.device_id = p_device_id AND x.status = 'received'
          ORDER BY x.seq LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)) o
    JOIN public.offline_leases l ON l.id = o.lease_id
    JOIN public.device_offline_keys k ON k.id = l.key_id
    LEFT JOIN public.fiscal_submissions f ON f.offline_sale_id = o.id
$$;

-- The S01 cart with the sale as it was printed: each line's price, rate, tax and total, and the
-- totals (app.offline_process has checked them equal to T01 on the snapshot's prices).
CREATE FUNCTION app.offline_cart(p_cart jsonb, p_offline jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v_lines jsonb := '[]'::jsonb; i integer; o jsonb;
BEGIN
    FOR i IN 0..jsonb_array_length(p_cart -> 'lines') - 1 LOOP
        o := p_offline -> 'lines' -> i;
        v_lines := v_lines || ((p_cart -> 'lines' -> i) || jsonb_build_object(
            'unit_price', o ->> 'unit_price', 'tax_rate', o ->> 'tax_rate', 'tax_amount', o ->> 'tax_amount',
            'line_total', o ->> 'line_total', 'discount_amount', '0.00', 'effective_pct', '0',
            'overridden', false));
    END LOOP;
    RETURN p_cart || jsonb_build_object('lines', v_lines, 'prices_include_vat', p_offline -> 'prices_include_vat',
        'subtotal', p_offline ->> 'subtotal', 'tax_total', p_offline ->> 'tax_total', 'total', p_offline ->> 'total',
        'discount_total', '0.00');
END;
$$;

-- The shop day of an offline sale: the day it was issued (never after today); a day K04 has
-- closed for the branch is never reopened: the sale then goes to today's open day.
CREATE FUNCTION app.offline_issued_day(p_org uuid, p_issued timestamptz)
RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT LEAST((p_issued AT TIME ZONE o.timezone)::date, app.org_today(p_org))
    FROM public.organizations o WHERE o.id = p_org
$$;

CREATE FUNCTION app.offline_business_date(p_org uuid, p_branch uuid, p_issued timestamptz)
RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT CASE WHEN EXISTS (SELECT 1 FROM public.day_closes dc
                             WHERE dc.organization_id = p_org AND dc.branch_id = p_branch
                               AND dc.business_date = app.offline_issued_day(p_org, p_issued)
                               AND dc.status = 'closed')
                THEN app.org_today(p_org) ELSE app.offline_issued_day(p_org, p_issued) END
$$;

-- One received sale, after the worker checked its signature (the lease's key) and its receipt UUID.
-- Concurrent runs: the row is taken with SKIP LOCKED and only while it is still 'received'.
-- p_qr: the receipt's QR text (the shared builder; NULL without a receipt).
CREATE FUNCTION app.offline_process(p_id uuid, p_signature_ok boolean, p_uuid_ok boolean, p_qr text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    o public.offline_sales; c jsonb; v_lease public.offline_leases; v_snap jsonb; v_shift public.shifts;
    v_f public.fiscal_submissions; v_sale uuid; v_code text; v_accepted jsonb; v_prev timestamptz;
    v_count integer; v_sum numeric; v_tax jsonb; v_p jsonb; l jsonb; i integer; v_unit uuid; v_u public.units;
    v_prod public.products; v_avail integer; v_short integer; v_adj uuid; v_date date; v_lines jsonb := '[]';
    v_offline jsonb; v_flags text[]; v_alerts text[] := '{}'; v_released boolean := false; v_reason text;
BEGIN
    SELECT * INTO o FROM public.offline_sales x WHERE x.id = p_id FOR UPDATE SKIP LOCKED;
    IF NOT FOUND OR o.status <> 'received' THEN
        RETURN jsonb_build_object('id', p_id, 'skipped', true);
    END IF;
    c := o.content::jsonb;
    SELECT * INTO v_lease FROM public.offline_leases x WHERE x.id = o.lease_id;
    SELECT * INTO v_f FROM public.fiscal_submissions f WHERE f.offline_sale_id = o.id FOR UPDATE;
    v_flags := o.flags;

    -- 1. The signature or the receipt UUID is not what the device made: never posted, never sent.
    IF NOT COALESCE(p_signature_ok, false) OR NOT COALESCE(p_uuid_ok, false) THEN
        UPDATE public.offline_sales x SET status = 'rejected', conflict_code = 'VERIFY_FAILED' WHERE x.id = o.id;
        IF v_f.id IS NOT NULL THEN
            UPDATE public.fiscal_submissions f
               SET status = 'cancelled', last_error = 'OFFLINE_VERIFY_FAILED', next_retry_at = NULL, updated_at = now()
             WHERE f.id = v_f.id;
            PERFORM app.offline_event(v_f.id, 'offline_verify_failed', o.number);
        END IF;
        PERFORM app.offline_alert(o.organization_id, o.branch_id, o.id, 'VERIFY_FAILED',
            jsonb_build_object('number', o.number, 'signature_ok', p_signature_ok, 'uuid_ok', p_uuid_ok));
        RETURN jsonb_build_object('id', o.id, 'status', 'rejected', 'code', 'VERIFY_FAILED', 'released', false,
                                  'alerts', jsonb_build_array('VERIFY_FAILED'));
    END IF;

    IF v_f.id IS NOT NULL AND p_qr IS NOT NULL AND v_f.qr_payload IS NULL THEN
        UPDATE public.fiscal_submissions f SET qr_payload = p_qr, updated_at = now() WHERE f.id = v_f.id;
    END IF;

    -- 2. The online attempt reached the server after all: that sale stands, this one is its duplicate.
    SELECT s.id INTO v_sale FROM public.sales s
    WHERE s.organization_id = o.organization_id AND s.idempotency_key = o.idempotency_key;
    IF FOUND THEN
        UPDATE public.offline_sales x
           SET status = 'duplicate', sale_id = v_sale, flags = array_append(x.flags, 'reprint_needed')
         WHERE x.id = o.id;
        IF v_f.id IS NOT NULL THEN
            UPDATE public.fiscal_submissions f
               SET status = 'cancelled', last_error = 'OFFLINE_DUPLICATE_OF_ONLINE', next_retry_at = NULL,
                   updated_at = now()
             WHERE f.id = v_f.id;
            PERFORM app.offline_event(v_f.id, 'offline_duplicate', o.number);
        END IF;
        RETURN jsonb_build_object('id', o.id, 'status', 'duplicate', 'code', NULL, 'released', false,
                                  'sale_id', v_sale, 'alerts', '[]'::jsonb);
    END IF;

    -- 3. Business posting. A failed check leaves only the conflict (the block is undone).
    v_accepted := COALESCE(o.overrides -> 'accepted', '[]'::jsonb);
    IF o.fiscal_hold = 'LEASE_REVOKED' AND NOT v_accepted ? 'LEASE_REVOKED' THEN
        v_code := 'LEASE_REVOKED';
    ELSE
        BEGIN
            SELECT s.data INTO v_snap FROM public.offline_snapshots s WHERE s.id = v_lease.snapshot_id;

            -- Shift: the manager's choice, else the lease's.
            SELECT * INTO v_shift FROM public.shifts s
            WHERE s.organization_id = o.organization_id
              AND s.id = COALESCE((o.overrides ->> 'shift_id')::uuid, v_lease.shift_id)
            FOR UPDATE;
            IF NOT FOUND OR v_shift.status <> 'open' THEN
                RAISE EXCEPTION 'OFFLINE_CONFLICT:SHIFT_CLOSED' USING ERRCODE = 'P0001';
            END IF;

            -- Time: inside the lease (2 minutes either way), never before the previous offline sale.
            IF NOT v_accepted ? 'TIME_INVALID' THEN
                SELECT x.issued_at INTO v_prev FROM public.offline_sales x
                WHERE x.device_id = o.device_id AND x.seq < o.seq ORDER BY x.seq DESC LIMIT 1;
                IF o.issued_at < v_lease.issued_at - interval '2 minutes'
                   OR o.issued_at > LEAST(v_lease.expires_at, o.received_at) + interval '2 minutes'
                   OR (v_prev IS NOT NULL AND o.issued_at < v_prev) THEN
                    RAISE EXCEPTION 'OFFLINE_CONFLICT:TIME_INVALID' USING ERRCODE = 'P0001';
                END IF;
            END IF;

            -- Limits: the sale, and the count and total so far under this lease.
            IF NOT v_accepted ? 'LIMIT_EXCEEDED' THEN
                SELECT count(*), COALESCE(sum(x.total), 0) INTO v_count, v_sum FROM public.offline_sales x
                WHERE x.lease_id = o.lease_id AND x.seq <= o.seq AND x.status <> 'rejected';
                IF o.total > v_lease.max_sale_total OR v_count > v_lease.max_sales OR v_sum > v_lease.max_lease_total THEN
                    RAISE EXCEPTION 'OFFLINE_CONFLICT:LIMIT_EXCEEDED' USING ERRCODE = 'P0001';
                END IF;
            END IF;

            -- Shape and prices: walk-in, cash only, no discount (the content allows none), every
            -- product in the snapshot, sellable offline, at its snapshot price and rate.
            IF NOT v_accepted ? 'PRICE_MISMATCH' THEN
                FOR l IN SELECT jsonb_array_elements(c -> 'lines') LOOP
                    v_p := NULL;
                    SELECT p INTO v_p FROM jsonb_array_elements(v_snap -> 'products') p WHERE p ->> 'id' = l ->> 'product_id';
                    IF v_p IS NULL OR NOT (v_p ->> 'offline_sellable')::boolean
                       OR (v_p ->> 'price')::numeric IS DISTINCT FROM (l ->> 'unit_price')::numeric
                       OR (v_p ->> 'tax_rate')::numeric IS DISTINCT FROM (l ->> 'tax_rate')::numeric THEN
                        RAISE EXCEPTION 'OFFLINE_CONFLICT:PRICE_MISMATCH' USING ERRCODE = 'P0001';
                    END IF;
                END LOOP;
            END IF;

            -- Totals: T01 again on the printed lines. Never overridden.
            SELECT app.compute_document_tax(jsonb_build_object(
                       'prices_include_vat', (v_snap ->> 'prices_include_vat')::boolean, 'document_discount', '0',
                       'lines', jsonb_agg(jsonb_build_object('unit_price', x ->> 'unit_price',
                                          'quantity', (x ->> 'quantity')::integer, 'line_discount', '0',
                                          'tax_rate', x ->> 'tax_rate') ORDER BY n)))
            INTO v_tax FROM jsonb_array_elements(c -> 'lines') WITH ORDINALITY y(x, n);
            IF (v_tax ->> 'subtotal')::numeric <> (c ->> 'subtotal')::numeric
               OR (v_tax ->> 'tax_total')::numeric <> (c ->> 'tax_total')::numeric
               OR (v_tax ->> 'total')::numeric <> (c ->> 'total')::numeric
               OR (c #>> '{payments,0,amount}')::numeric <> (c ->> 'total')::numeric
               OR (c #>> '{payments,0,tendered}')::numeric < (c ->> 'total')::numeric
               OR (c #>> '{payments,0,change}')::numeric
                  <> (c #>> '{payments,0,tendered}')::numeric - (c ->> 'total')::numeric
               OR EXISTS (SELECT 1 FROM generate_series(0, jsonb_array_length(c -> 'lines') - 1) k
                          WHERE (v_tax -> 'lines' -> k ->> 'tax')::numeric <> (c -> 'lines' -> k ->> 'tax_amount')::numeric
                             OR (v_tax -> 'lines' -> k ->> 'gross')::numeric <> (c -> 'lines' -> k ->> 'line_total')::numeric) THEN
                RAISE EXCEPTION 'OFFLINE_CONFLICT:TOTALS_MISMATCH' USING ERRCODE = 'P0001';
            END IF;

            v_date := app.offline_business_date(o.organization_id, v_shift.branch_id, o.issued_at);
            IF v_date <> app.offline_issued_day(o.organization_id, o.issued_at) THEN
                v_flags := array_append(v_flags, 'late_business_date');
            END IF;

            -- Serials: the printed unit (or the manager's choice) of this product, in this branch, in stock.
            FOR i IN 0..jsonb_array_length(c -> 'lines') - 1 LOOP
                l := c -> 'lines' -> i;
                SELECT * INTO v_prod FROM public.products p
                WHERE p.id = (l ->> 'product_id')::uuid AND p.organization_id = o.organization_id;
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'OFFLINE_CONFLICT:PRICE_MISMATCH' USING ERRCODE = 'P0001';
                END IF;
                v_unit := COALESCE((o.overrides -> 'units' ->> (i + 1)::text)::uuid, (l ->> 'unit_id')::uuid);
                IF v_prod.is_serialized THEN
                    SELECT * INTO v_u FROM public.units u
                    WHERE u.id = v_unit AND u.organization_id = o.organization_id FOR UPDATE;
                    IF NOT FOUND OR v_u.product_id <> v_prod.id OR v_u.branch_id <> v_shift.branch_id
                       OR v_u.status <> 'in_stock' THEN
                        RAISE EXCEPTION 'OFFLINE_CONFLICT:SERIAL_UNAVAILABLE' USING ERRCODE = 'P0001';
                    END IF;
                ELSIF v_unit IS NOT NULL THEN
                    RAISE EXCEPTION 'OFFLINE_CONFLICT:SERIAL_UNAVAILABLE' USING ERRCODE = 'P0001';
                END IF;
                v_lines := v_lines || jsonb_build_object('product_id', v_prod.id, 'quantity', (l ->> 'quantity')::integer,
                                                         'unit_id', v_unit, 'unit_price', l ->> 'unit_price');
            END LOOP;

            -- Stock: a non-serialized shortage never fails the sale; the missing quantity is found by an
            -- adjustment first, so the ledger stays whole and on_hand never goes below 0.
            FOR l IN
                SELECT jsonb_build_object('product_id', x ->> 'product_id', 'quantity', sum((x ->> 'quantity')::integer))
                FROM jsonb_array_elements(v_lines) x
                WHERE x ->> 'unit_id' IS NULL
                GROUP BY x ->> 'product_id' ORDER BY x ->> 'product_id'
            LOOP
                PERFORM 1 FROM public.stock_levels sl
                WHERE sl.organization_id = o.organization_id AND sl.branch_id = v_shift.branch_id
                  AND sl.product_id = (l ->> 'product_id')::uuid AND sl.stock_state = 'sellable' FOR UPDATE;
                SELECT COALESCE(sum(sl.on_hand - sl.reserved), 0)::integer INTO v_avail FROM public.stock_levels sl
                WHERE sl.organization_id = o.organization_id AND sl.branch_id = v_shift.branch_id
                  AND sl.product_id = (l ->> 'product_id')::uuid AND sl.stock_state = 'sellable';
                v_short := (l ->> 'quantity')::integer - GREATEST(v_avail, 0);
                IF v_short > 0 THEN
                    IF v_adj IS NULL THEN
                        INSERT INTO public.stock_adjustments (organization_id, number, branch_id, reason, note,
                                                              idempotency_key, created_by)
                        VALUES (o.organization_id,
                                app.next_document_number(o.organization_id, v_shift.branch_id, 'stock_adjustment'),
                                v_shift.branch_id, 'correction', 'S08 offline shortage: ' || o.number,
                                'system:offline-shortage:' || o.id::text, v_lease.cashier_id)
                        RETURNING id INTO v_adj;
                    END IF;
                    PERFORM app.post_adjustment_lines(o.organization_id, v_lease.cashier_id, v_adj, v_shift.branch_id,
                        jsonb_build_array(jsonb_build_object('product_id', l ->> 'product_id', 'quantity', v_short)));
                END IF;
            END LOOP;
            IF v_adj IS NOT NULL THEN
                v_flags := array_append(v_flags, 'stock_adjusted');
            END IF;

            -- The sale, through the S01 core, exactly as printed.
            v_offline := jsonb_build_object(
                'number', o.number, 'issued_at', o.issued_at, 'business_date', v_date,
                'prices_include_vat', (v_snap ->> 'prices_include_vat')::boolean,
                'subtotal', c ->> 'subtotal', 'tax_total', c ->> 'tax_total', 'total', c ->> 'total',
                'lines', (SELECT jsonb_agg(jsonb_build_object('unit_price', x ->> 'unit_price', 'tax_rate', x ->> 'tax_rate',
                                                              'tax_amount', x ->> 'tax_amount', 'line_total', x ->> 'line_total')
                                           ORDER BY n)
                          FROM jsonb_array_elements(c -> 'lines') WITH ORDINALITY y(x, n)));
            v_sale := app.post_sale_core_full(o.organization_id, v_lease.cashier_id, v_shift, v_lines, NULL,
                (c ->> 'total')::numeric, o.idempotency_key,
                jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', c ->> 'total',
                                                     'tendered', c #>> '{payments,0,tendered}')),
                NULL, NULL, NULL, NULL, v_offline);

            UPDATE public.offline_sales x
               SET status = 'posted', sale_id = v_sale, conflict_code = NULL, flags = v_flags
             WHERE x.id = o.id;
            IF v_f.id IS NOT NULL THEN
                -- An accepted receipt only gets its sale (D12.10); any other one is touched as before.
                UPDATE public.fiscal_submissions f
                   SET sale_id = v_sale, updated_at = CASE WHEN f.status = 'accepted' THEN f.updated_at ELSE now() END
                 WHERE f.id = v_f.id;
            END IF;
        EXCEPTION WHEN others THEN
            v_reason := SQLERRM;
            v_code := CASE
                WHEN v_reason LIKE 'OFFLINE_CONFLICT:%' THEN split_part(v_reason, ':', 2)
                WHEN v_reason ~ '^(UNIT_NOT_AVAILABLE|UNIT_NOT_FOUND|UNIT_PRODUCT_MISMATCH|UNIT_REQUIRED|UNIT_NOT_ALLOWED)'
                    THEN 'SERIAL_UNAVAILABLE'
                WHEN v_reason ~ '^(DAY_CLOSED|FUTURE_BUSINESS_DATE)' THEN 'TIME_INVALID'
                WHEN v_reason ~ '^(PRODUCT_ARCHIVED|PRODUCT_NOT_FOUND)' THEN 'PRICE_MISMATCH'
                WHEN v_reason ~ '^SHIFT_CLOSED' THEN 'SHIFT_CLOSED' END;
            IF v_code IS NULL THEN
                RAISE;
            END IF;
        END;
    END IF;

    IF v_code IS NOT NULL THEN
        UPDATE public.offline_sales x SET status = 'conflict', conflict_code = v_code WHERE x.id = o.id;
        -- A sale whose printed totals T01 does not give is a bug: its receipt is held if not yet released.
        IF v_code = 'TOTALS_MISMATCH' THEN
            IF v_f.id IS NULL OR v_f.offline_released_at IS NULL THEN
                UPDATE public.offline_sales x SET fiscal_hold = 'RECEIPT_MISMATCH' WHERE x.id = o.id;
            END IF;
            PERFORM app.offline_alert(o.organization_id, o.branch_id, o.id, 'offline.bug',
                jsonb_build_object('reason', 'TOTALS_MISMATCH', 'number', o.number));
            v_alerts := v_alerts || 'offline.bug'::text;
        END IF;
    END IF;

    -- 4. The receipt goes to the ETA whatever the business result, unless it is held.
    SELECT * INTO o FROM public.offline_sales x WHERE x.id = p_id;
    IF v_f.id IS NOT NULL AND o.fiscal_hold IS NULL AND v_f.offline_released_at IS NULL THEN
        UPDATE public.fiscal_submissions f SET offline_released_at = now(), updated_at = now() WHERE f.id = v_f.id;
        PERFORM app.offline_event(v_f.id, 'offline_released', o.number);
        PERFORM app.eta_enqueue(o.organization_id, 'eta.submit', 'eta.submit:' || o.device_id::text,
            jsonb_build_object('device_id', o.device_id));
        v_released := true;
    END IF;

    RETURN jsonb_build_object('id', o.id, 'status', o.status, 'code', o.conflict_code, 'released', v_released,
                              'sale_id', o.sale_id, 'flags', to_jsonb(o.flags), 'alerts', to_jsonb(v_alerts));
END;
$$;

-- PostgREST exposes only public: the worker reaches the two functions above through these, granted
-- to the service role only (as T02's eta_* worker functions).
CREATE FUNCTION public.offline_worker_load(p_device_id uuid, p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT app.offline_load_received(p_device_id, p_limit)
$$;

CREATE FUNCTION public.offline_worker_process(p_id uuid, p_signature_ok boolean, p_uuid_ok boolean,
                                              p_qr text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$
    SELECT app.offline_process(p_id, p_signature_ok, p_uuid_ok, p_qr)
$$;

-- 9. Review and resolution (D11) -----------------------------------------------------------------

CREATE FUNCTION public.list_offline_sales(p_status text DEFAULT NULL, p_branch_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    PERFORM app.require_permission('offline.resolve');
    v_org := app.current_org_id();
    IF p_status IS NOT NULL AND p_status NOT IN ('received', 'posted', 'conflict', 'duplicate', 'rejected') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: status' USING ERRCODE = 'P0001';
    END IF;
    IF p_branch_id IS NOT NULL THEN
        PERFORM app.require_branch_access(p_branch_id);
    END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(app.offline_sale_json(v_org, k.id) ORDER BY k.received_at DESC, k.seq DESC)
        FROM (SELECT o.id, o.received_at, o.seq FROM public.offline_sales o
              WHERE o.organization_id = v_org AND app.has_branch_access(o.branch_id)
                AND (p_status IS NULL OR o.status = p_status) AND (p_branch_id IS NULL OR o.branch_id = p_branch_id)
              ORDER BY o.received_at DESC, o.seq DESC LIMIT 500) k), '[]'::jsonb);
END;
$$;

-- One offline sale as printed: its lines with names and serials, the payment, the receipt's UUIDs,
-- the overrides. Never the content text, the receipt JSON or the signature.
CREATE FUNCTION public.get_offline_sale(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; o public.offline_sales; c jsonb;
BEGIN
    PERFORM app.require_permission('offline.resolve');
    v_org := app.current_org_id();
    SELECT * INTO o FROM public.offline_sales x WHERE x.id = p_id AND x.organization_id = v_org;
    IF NOT FOUND OR NOT app.has_branch_access(o.branch_id) THEN
        RAISE EXCEPTION 'OFFLINE_SALE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    c := o.content::jsonb;
    RETURN app.offline_sale_json(v_org, o.id) || jsonb_build_object(
        'lines', (SELECT jsonb_agg(jsonb_build_object(
                      'line_no', n, 'product_id', x ->> 'product_id', 'name_ar', p.name_ar, 'name_en', p.name_en,
                      'sku', p.sku, 'unit_id', x ->> 'unit_id', 'serial', u.serial,
                      'quantity', (x ->> 'quantity')::integer, 'unit_price', x ->> 'unit_price',
                      'tax_rate', x ->> 'tax_rate', 'tax_amount', x ->> 'tax_amount', 'line_total', x ->> 'line_total')
                      ORDER BY n)
                  FROM jsonb_array_elements(c -> 'lines') WITH ORDINALITY y(x, n)
                  LEFT JOIN public.products p ON p.id = (x ->> 'product_id')::uuid AND p.organization_id = v_org
                  LEFT JOIN public.units u ON u.id = (x ->> 'unit_id')::uuid AND u.organization_id = v_org),
        'subtotal', c ->> 'subtotal', 'tax_total', c ->> 'tax_total',
        'payment', jsonb_build_object('amount', c #>> '{payments,0,amount}', 'tendered', c #>> '{payments,0,tendered}',
                                      'change', c #>> '{payments,0,change}'),
        'eta_uuid', o.eta_uuid, 'previous_uuid', o.previous_uuid, 'overrides', o.overrides);
END;
$$;

-- The manager's decision on one offline sale (D11). Nothing here changes a printed price,
-- quantity, payment or total: a decision only lets the worker post it, elsewhere or later, or
-- (for a revoked lease only) refuses it.
CREATE FUNCTION public.resolve_offline_sale(p_id uuid, p_action text, p_reason text, p_unit_ids jsonb DEFAULT NULL,
                                            p_shift_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; o public.offline_sales; c jsonb; v_reason text := btrim(p_reason); v_ov jsonb;
    v_key text; v_line jsonb; v_u public.units; v_s public.shifts; v_f public.fiscal_submissions;
    v_lease_hold boolean; v_before jsonb; v_unit uuid;
BEGIN
    v_emp := app.require_permission('offline.resolve');
    v_org := app.current_org_id();
    SELECT * INTO o FROM public.offline_sales x WHERE x.id = p_id AND x.organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OFFLINE_SALE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(o.branch_id);
    IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 500 THEN
        RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    v_before := jsonb_build_object('status', o.status, 'conflict_code', o.conflict_code, 'fiscal_hold', o.fiscal_hold);
    v_ov := o.overrides;
    v_lease_hold := o.fiscal_hold IS NOT DISTINCT FROM 'LEASE_REVOKED' AND o.status IN ('received', 'conflict');
    c := o.content::jsonb;

    IF p_action = 'accept' AND v_lease_hold THEN
        v_ov := jsonb_set(v_ov, '{accepted}', COALESCE(v_ov -> 'accepted', '[]'::jsonb) || '"LEASE_REVOKED"'::jsonb);
        UPDATE public.offline_sales x SET fiscal_hold = NULL WHERE x.id = o.id;
    ELSIF p_action = 'accept' AND o.status = 'conflict'
          AND o.conflict_code IN ('TIME_INVALID', 'LIMIT_EXCEEDED', 'PRICE_MISMATCH') THEN
        v_ov := jsonb_set(v_ov, '{accepted}', COALESCE(v_ov -> 'accepted', '[]'::jsonb) || to_jsonb(o.conflict_code));
    ELSIF p_action = 'use_serial' AND o.status = 'conflict' AND o.conflict_code = 'SERIAL_UNAVAILABLE' THEN
        IF p_unit_ids IS NULL OR jsonb_typeof(p_unit_ids) <> 'object' OR p_unit_ids = '{}'::jsonb THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: unit_ids' USING ERRCODE = 'P0001';
        END IF;
        FOR v_key IN SELECT jsonb_object_keys(p_unit_ids) LOOP
            v_line := CASE WHEN v_key ~ '^[1-9][0-9]{0,2}$' THEN c -> 'lines' -> (v_key::integer - 1) END;
            IF v_line IS NULL OR (p_unit_ids ->> v_key) !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
                RAISE EXCEPTION 'VALIDATION_FAILED: unit_ids' USING ERRCODE = 'P0001';
            END IF;
            v_unit := (p_unit_ids ->> v_key)::uuid;
            SELECT * INTO v_u FROM public.units u WHERE u.id = v_unit AND u.organization_id = v_org;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'UNIT_NOT_FOUND' USING ERRCODE = 'P0001';
            END IF;
            IF v_u.product_id::text <> v_line ->> 'product_id' THEN
                RAISE EXCEPTION 'UNIT_PRODUCT_MISMATCH' USING ERRCODE = 'P0001';
            END IF;
            IF v_u.branch_id <> o.branch_id OR v_u.status <> 'in_stock' THEN
                RAISE EXCEPTION 'UNIT_NOT_AVAILABLE: % is not in stock in this branch', v_u.serial USING ERRCODE = 'P0001';
            END IF;
        END LOOP;
        v_ov := jsonb_set(v_ov, '{units}', COALESCE(v_ov -> 'units', '{}'::jsonb) || p_unit_ids);
    ELSIF p_action = 'post_to_shift' AND o.status = 'conflict' AND o.conflict_code = 'SHIFT_CLOSED' THEN
        SELECT * INTO v_s FROM public.shifts s WHERE s.id = p_shift_id AND s.organization_id = v_org;
        IF NOT FOUND OR v_s.branch_id <> o.branch_id THEN
            RAISE EXCEPTION 'SHIFT_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF v_s.status <> 'open' THEN
            RAISE EXCEPTION 'SHIFT_CLOSED: the shift is closed' USING ERRCODE = 'P0001';
        END IF;
        v_ov := v_ov || jsonb_build_object('shift_id', p_shift_id);
    ELSIF p_action = 'reject' AND v_lease_hold THEN
        UPDATE public.offline_sales x
           SET status = 'rejected', conflict_code = 'LEASE_REVOKED', resolved_by = v_emp, resolved_at = now(),
               resolution_reason = v_reason
         WHERE x.id = o.id;
        SELECT * INTO v_f FROM public.fiscal_submissions f WHERE f.offline_sale_id = o.id FOR UPDATE;
        IF v_f.id IS NOT NULL THEN
            UPDATE public.fiscal_submissions f
               SET status = 'cancelled', last_error = 'OFFLINE_REJECTED_LEASE_REVOKED', next_retry_at = NULL,
                   updated_at = now()
             WHERE f.id = v_f.id;
        END IF;
        PERFORM app.write_audit('offline_sale.resolved', 'offline_sale', o.id, v_before,
            jsonb_build_object('action', 'reject', 'number', o.number, 'status', 'rejected'), v_reason, o.branch_id,
            'warning'::public.audit_severity);
        RETURN app.offline_sale_json(v_org, o.id);
    ELSE
        RAISE EXCEPTION 'RESOLUTION_NOT_ALLOWED' USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.offline_sales x
       SET overrides = v_ov, status = 'received', conflict_code = NULL, resolved_by = v_emp, resolved_at = now(),
           resolution_reason = v_reason
     WHERE x.id = o.id;
    PERFORM app.eta_enqueue(v_org, 'offline.process', 'offline.process:' || o.device_id::text,
        jsonb_build_object('device_id', o.device_id));
    PERFORM app.write_audit('offline_sale.resolved', 'offline_sale', o.id, v_before,
        jsonb_build_object('action', p_action, 'number', o.number, 'overrides', v_ov), v_reason, o.branch_id,
        'warning'::public.audit_severity);
    RETURN app.offline_sale_json(v_org, o.id);
END;
$$;

-- 10. Settings (D16) -----------------------------------------------------------------------------

CREATE FUNCTION public.get_offline_settings()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    PERFORM app.require_permission('org.settings_manage');
    RETURN app.offline_settings_json(app.current_org_id());
END;
$$;

CREATE FUNCTION public.set_offline_settings(p_enabled boolean, p_max_sale_total text, p_max_hours integer,
                                            p_max_sales integer, p_max_lease_total text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_before jsonb;
BEGIN
    v_emp := app.require_permission('org.settings_manage');
    v_org := app.current_org_id();
    IF p_enabled IS NULL OR p_max_hours IS NULL OR p_max_sales IS NULL
       OR p_max_sale_total !~ '^\d{1,16}(\.\d{1,2})?$' OR p_max_lease_total !~ '^\d{1,16}(\.\d{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: offline settings' USING ERRCODE = 'P0001';
    END IF;
    v_before := app.offline_settings_json(v_org);
    BEGIN
        UPDATE public.org_settings s
           SET offline_enabled = p_enabled, offline_max_sale_total = p_max_sale_total::numeric,
               offline_max_hours = p_max_hours, offline_max_sales = p_max_sales,
               offline_max_lease_total = p_max_lease_total::numeric, updated_at = now(), updated_by = v_emp
         WHERE s.organization_id = v_org;
    EXCEPTION WHEN check_violation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: offline settings out of bounds' USING ERRCODE = 'P0001';
    END;
    PERFORM app.write_audit('offline.settings_updated', 'org_settings', v_org, v_before,
        app.offline_settings_json(v_org), NULL, NULL,
        CASE WHEN (v_before ->> 'offline_enabled')::boolean IS DISTINCT FROM p_enabled
             THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN app.offline_settings_json(v_org);
END;
$$;

-- 11. Changes to merged code (D12) ---------------------------------------------------------------

-- D12.1 T02's fiscal trigger (20261012120000_t02_eta_receipts.sql), unchanged but for its first
-- statement: an offline sale's fiscal row exists already (it carries the printed receipt).
CREATE OR REPLACE FUNCTION app.sales_eta_fiscal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_env public.eta_environment;
BEGIN
    IF NEW.offline_created_at IS NOT NULL THEN
        RETURN NULL;
    END IF;
    IF NEW.is_b2b THEN
        RETURN NULL;
    END IF;
    SELECT s.environment INTO v_env FROM public.eta_settings s
    WHERE s.organization_id = NEW.organization_id AND s.is_enabled;
    IF NOT FOUND OR NOT app.org_has_module(NEW.organization_id, 'eta') THEN
        RETURN NULL;
    END IF;
    INSERT INTO public.fiscal_submissions (organization_id, branch_id, device_id, doc_type, sale_id, environment,
                                           internal_id, status, created_by)
    VALUES (NEW.organization_id, NEW.branch_id, NEW.device_id, 'b2c_receipt', NEW.id, v_env, NEW.number,
            'pending', NEW.created_by);
    PERFORM app.eta_enqueue(NEW.organization_id, 'eta.prepare',
        'eta.prepare:' || COALESCE(NEW.device_id, NEW.branch_id)::text,
        jsonb_build_object('device_id', NEW.device_id, 'branch_id', NEW.branch_id));
    RETURN NULL;
END;
$$;

-- D12.2 T02's submit loader: an offline receipt waits until it is released; issue time is the
-- offline sale's for a receipt without a sale. Otherwise unchanged.
CREATE OR REPLACE FUNCTION public.eta_claim_for_submit(p_device_id uuid, p_limit integer DEFAULT 50,
                                                       p_lease_seconds integer DEFAULT 300)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_out jsonb;
BEGIN
    WITH due AS (
        SELECT f.id, COALESCE(s.issued_at, os.issued_at, f.created_at) AS issued_at, f.internal_id,
               COALESCE(f.payload ? 'sent', false) AS was_sent
        FROM public.fiscal_submissions f
        LEFT JOIN public.sales s ON s.id = f.sale_id AND s.organization_id = f.organization_id
        LEFT JOIN public.offline_sales os ON os.id = f.offline_sale_id AND os.organization_id = f.organization_id
        WHERE f.device_id = p_device_id AND f.status = 'pending' AND f.eta_uuid IS NOT NULL
          AND (f.next_retry_at IS NULL OR f.next_retry_at <= now())
          AND NOT (f.offline_sale_id IS NOT NULL AND f.offline_released_at IS NULL)
        ORDER BY COALESCE(s.issued_at, os.issued_at, f.created_at), f.internal_id
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 500)
        FOR UPDATE OF f SKIP LOCKED
    ), leased AS (
        UPDATE public.fiscal_submissions f
           SET next_retry_at = now() + make_interval(secs => GREATEST(COALESCE(p_lease_seconds, 300), 1)),
               payload = f.payload || jsonb_build_object('sent', true), updated_at = now()
          FROM due WHERE f.id = due.id
        RETURNING f.id, f.organization_id, f.environment, f.internal_id, f.eta_uuid, f.attempts,
                  f.payload ->> 'receipt_json' AS receipt_json, due.issued_at, due.was_sent
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'fiscal_id', l.id, 'organization_id', l.organization_id, 'environment', l.environment,
               'internal_id', l.internal_id, 'uuid', l.eta_uuid, 'attempts', l.attempts,
               'receipt_json', l.receipt_json, 'was_sent', l.was_sent) ORDER BY l.issued_at, l.internal_id),
           '[]'::jsonb)
    INTO v_out FROM leased l;
    RETURN v_out;
END;
$$;

-- D12.3 T02's deadline alert: the issue time of a receipt without a sale is its offline sale's.
-- Otherwise unchanged (a return's row, which has neither, is still not alerted here).
CREATE OR REPLACE FUNCTION public.eta_claim_deadline_alerts(p_device_id uuid, p_hours integer DEFAULT 20,
                                                            p_now timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_out jsonb;
BEGIN
    WITH late AS (
        UPDATE public.fiscal_submissions f
           SET payload = COALESCE(f.payload, '{}'::jsonb) || jsonb_build_object('deadline_alerted_at', p_now),
               updated_at = now()
          FROM (SELECT g.id, COALESCE(s.issued_at, os.issued_at) AS issued_at
                FROM public.fiscal_submissions g
                LEFT JOIN public.sales s ON s.id = g.sale_id AND s.organization_id = g.organization_id
                LEFT JOIN public.offline_sales os ON os.id = g.offline_sale_id AND os.organization_id = g.organization_id
                WHERE g.device_id = p_device_id) x
         WHERE x.id = f.id AND x.issued_at IS NOT NULL
           AND f.device_id = p_device_id AND f.status = 'pending'
           AND x.issued_at < p_now - make_interval(hours => GREATEST(COALESCE(p_hours, 20), 1))
           AND NOT (COALESCE(f.payload, '{}'::jsonb) ? 'deadline_alerted_at')
        RETURNING f.id, f.organization_id, f.internal_id, x.issued_at
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('fiscal_id', l.id, 'organization_id', l.organization_id,
                                                 'internal_id', l.internal_id, 'issued_at', l.issued_at)
                              ORDER BY l.issued_at), '[]'::jsonb)
    INTO v_out FROM late l;
    RETURN v_out;
END;
$$;

-- D12.4 T03's correction (20261014090000_t03_eta_monitor.sql): an offline receipt whose sale is not
-- posted is reviewed as an offline sale first. Otherwise unchanged.
CREATE OR REPLACE FUNCTION public.fiscal_request_correction(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_f public.fiscal_submissions;
BEGIN
    v_emp := app.require_permission('fiscal.retry');
    v_org := app.current_org_id();
    PERFORM app.require_module('eta');
    v_f := app.fiscal_visible(p_id, true);
    IF v_f.offline_sale_id IS NOT NULL AND v_f.sale_id IS NULL THEN
        RAISE EXCEPTION 'OFFLINE_REVIEW_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    IF v_f.status <> 'rejected' THEN
        RAISE EXCEPTION 'NOT_REJECTED: the receipt is %', v_f.status USING ERRCODE = 'P0001';
    END IF;
    IF v_f.environment IS DISTINCT FROM (SELECT s.environment FROM public.eta_settings s
                                         WHERE s.organization_id = v_org) THEN
        RAISE EXCEPTION 'ETA_ENV_MISMATCH: the receipt belongs to %', v_f.environment USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.jobs j
               WHERE j.job_type = 'eta.correct' AND j.status IN ('queued', 'running')
                 AND j.dedupe_key LIKE 'eta.correct:' || p_id::text || '%') THEN
        RAISE EXCEPTION 'CORRECTION_QUEUED' USING ERRCODE = 'P0001';
    END IF;

    PERFORM app.eta_enqueue(v_org, 'eta.correct', 'eta.correct:' || p_id::text,
        jsonb_build_object('fiscal_id', p_id, 'expected_old_uuid', v_f.eta_uuid));

    PERFORM app.write_audit('fiscal.correction_requested', 'fiscal_submission', p_id,
        jsonb_build_object('status', v_f.status, 'eta_uuid', v_f.eta_uuid, 'last_error', left(v_f.last_error, 500)),
        jsonb_build_object('status', v_f.status, 'internal_id', v_f.internal_id, 'correction', 'queued'),
        NULL, v_f.branch_id);
    RETURN jsonb_build_object('id', p_id, 'status', v_f.status, 'queued', true);
END;
$$;

-- D12.5 Closing a shift (K02's close_shift and EC-147's force_close_shift both update the row):
-- refused while offline sales of the shift wait to be posted or resolved.
CREATE FUNCTION app.shifts_offline_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.offline_sales o
               WHERE o.organization_id = NEW.organization_id AND o.status IN ('received', 'conflict')
                 AND ((o.overrides ->> 'shift_id') = NEW.id::text
                      OR (o.overrides ->> 'shift_id' IS NULL AND o.shift_id = NEW.id))) THEN
        RAISE EXCEPTION 'OFFLINE_SALES_OPEN: offline sales of this shift are not posted yet' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_shifts_offline_guard BEFORE UPDATE OF status ON public.shifts
    FOR EACH ROW WHEN (OLD.status = 'open' AND NEW.status = 'closed')
    EXECUTE FUNCTION app.shifts_offline_guard();

-- D12.6 Unpairing (a new or no token) or deactivating a device revokes its leases (O03's
-- unpair_device, pair_device and set_device_active are not edited).
CREATE FUNCTION app.devices_offline_revoke()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    UPDATE public.offline_leases l SET revoked_at = now()
    WHERE l.device_id = NEW.id AND l.revoked_at IS NULL;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_devices_offline_leases AFTER UPDATE OF token_hash, is_active ON public.devices
    FOR EACH ROW WHEN (OLD.token_hash IS DISTINCT FROM NEW.token_hash OR (OLD.is_active AND NOT NEW.is_active))
    EXECUTE FUNCTION app.devices_offline_revoke();

-- D12.8 K04's day close (close_day writes this row): refused while offline sales of the branch
-- issued on that day wait to be posted or resolved.
CREATE FUNCTION app.day_closes_offline_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.offline_sales o
               JOIN public.organizations org ON org.id = o.organization_id
               WHERE o.organization_id = NEW.organization_id AND o.branch_id = NEW.branch_id
                 AND o.status IN ('received', 'conflict')
                 AND (o.issued_at AT TIME ZONE org.timezone)::date = NEW.business_date) THEN
        RAISE EXCEPTION 'OFFLINE_SALES_OPEN: offline sales of this day are not posted yet' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_day_closes_offline_guard BEFORE INSERT OR UPDATE OF status ON public.day_closes
    FOR EACH ROW WHEN (NEW.status = 'closed')
    EXECUTE FUNCTION app.day_closes_offline_guard();

-- D12 (added, D10/D11): an offline sale's receipt is released before its business conflict is
-- decided, so the ETA may accept it before the sale is posted. The baseline freezes an accepted row
-- (trg_fiscal_submissions_final -> app.freeze_when_status('accepted', 'cancelled')); posting the
-- resolved sale then writes the row's sale_id once, and nothing else may change. Same rule otherwise.
CREATE FUNCTION app.fiscal_submissions_freeze()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF OLD.status IN ('accepted', 'cancelled') THEN
        -- The one update allowed: an accepted offline receipt without a sale gets the sale its
        -- offline sale was posted as, once; every other column stays as it was.
        IF OLD.status = 'accepted' AND OLD.offline_sale_id IS NOT NULL
           AND OLD.sale_id IS NULL AND NEW.sale_id IS NOT NULL
           AND NEW.sale_id = (SELECT o.sale_id FROM public.offline_sales o WHERE o.id = OLD.offline_sale_id)
           AND (to_jsonb(NEW) - 'sale_id') = (to_jsonb(OLD) - 'sale_id') THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'DOCUMENT_FINAL: %.% is % and can no longer change',
            TG_TABLE_SCHEMA, TG_TABLE_NAME, OLD.status USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER trg_fiscal_submissions_final ON public.fiscal_submissions;
CREATE TRIGGER trg_fiscal_submissions_final BEFORE UPDATE ON public.fiscal_submissions
    FOR EACH ROW EXECUTE FUNCTION app.fiscal_submissions_freeze();

-- D12.9 M03's excluded columns (20261027090000_m03_full_export.sql), plus the offline signature.
CREATE OR REPLACE FUNCTION app.export_excluded_columns()
RETURNS TABLE (table_name text, column_pattern text, reason text)
LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    VALUES
    ('*', 'token\_hash', 'hash of a login or invitation token'),
    ('*', '%\_secret%', 'secret material or a pointer to it (vault ids)'),
    ('*', 'password%', 'password material'),
    ('*', 'pairing\_code%', 'device pairing code (hash)'),
    ('devices', 'eta\_preshared\_key\_vault\_id', 'ETA signing material (vault id)'),
    ('offline_sales', 'signature', 'S08: the device''s signature of an offline sale')
$$;

-- D12.7 The S01 core. Its body (N02's, 20261018090000_n02_installment_sale.sql) moves to
-- app.post_sale_core_full with one trailing parameter; app.post_sale_core keeps its signature,
-- grants and every caller, and calls it with p_offline NULL (unchanged behaviour).
-- p_offline set (only by app.offline_process): the sale is posted as it was printed: its lines'
-- prices, rates, tax and totals, its number, its issue time (offline_created_at too) and its
-- business day; no price-override permission is asked (the prices were checked against the
-- lease's snapshot). The audit names the shop explicitly (the worker has no session; online, the
-- session's shop comes first as before).
CREATE FUNCTION app.post_sale_core_full(p_org uuid, p_emp uuid, p_shift public.shifts, p_lines jsonb,
                                   p_customer_id uuid, p_expected_total numeric, p_idempotency_key text,
                                   p_payments jsonb DEFAULT NULL, p_sale_discount jsonb DEFAULT NULL,
                                   p_discount_reason text DEFAULT NULL, p_discount_approval_id uuid DEFAULT NULL,
                                   p_pay_amount numeric DEFAULT NULL, p_offline jsonb DEFAULT NULL)
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
    v_cart := app.sale_cart(p_org, p_shift.branch_id, p_lines,
                            CASE WHEN p_offline IS NULL THEN app.has_permission('price.override') ELSE true END,
                            p_sale_discount);
    IF p_offline IS NOT NULL THEN
        v_cart := app.offline_cart(v_cart, p_offline);   -- S08: as printed
    END IF;
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
    v_date := CASE WHEN p_offline IS NULL THEN app.org_today(p_org) ELSE (p_offline ->> 'business_date')::date END;
    INSERT INTO public.sales (organization_id, number, branch_id, device_id, shift_id, customer_id, kind,
                              is_b2b, prices_include_vat, subtotal, discount_total, discount_reason, tax_total,
                              total, cost_total, issued_at, business_date, offline_created_at, idempotency_key,
                              created_by)
    VALUES (p_org,
            CASE WHEN p_offline IS NULL THEN app.next_document_number(p_org, p_shift.branch_id, 'sale')
                 ELSE p_offline ->> 'number' END,
            p_shift.branch_id,
            p_shift.device_id, p_shift.id, p_customer_id, 'pos', false,
            (v_cart ->> 'prices_include_vat')::boolean, (v_cart ->> 'subtotal')::numeric, v_discount, v_reason,
            (v_cart ->> 'tax_total')::numeric, v_total, round(v_cost, 2),
            CASE WHEN p_offline IS NULL THEN clock_timestamp() ELSE (p_offline ->> 'issued_at')::timestamptz END,
            v_date, (p_offline ->> 'issued_at')::timestamptz, p_idempotency_key, p_emp)
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

    -- The payment lines cover the sale total, or the down payment of an installment sale (N02).
    IF p_pay_amount IS NULL THEN
        v_paid := app.post_sale_payments(v_sale, p_shift, p_emp, p_payments, v_total);
    ELSIF p_pay_amount > 0 THEN
        v_paid := app.post_sale_payments(v_sale, p_shift, p_emp, p_payments, p_pay_amount);
    ELSE
        v_paid := '[]'::jsonb;
    END IF;

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
        CASE WHEN v_overrides IS NULL THEN 'info' ELSE 'warning' END::public.audit_severity, p_org);
    RETURN v_sale.id;
END;
$$;

CREATE OR REPLACE FUNCTION app.post_sale_core(p_org uuid, p_emp uuid, p_shift public.shifts, p_lines jsonb,
                                              p_customer_id uuid, p_expected_total numeric, p_idempotency_key text,
                                              p_payments jsonb DEFAULT NULL, p_sale_discount jsonb DEFAULT NULL,
                                              p_discount_reason text DEFAULT NULL,
                                              p_discount_approval_id uuid DEFAULT NULL,
                                              p_pay_amount numeric DEFAULT NULL)
RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$
    SELECT app.post_sale_core_full(p_org, p_emp, p_shift, p_lines, p_customer_id, p_expected_total,
                                   p_idempotency_key, p_payments, p_sale_discount, p_discount_reason,
                                   p_discount_approval_id, p_pay_amount, NULL)
$$;

-- 12. Grants -------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.offline_clean(text, integer), app.offline_try_jsonb(text),
    app.offline_content(text), app.offline_eta_on(uuid), app.offline_alert(uuid, uuid, uuid, text, jsonb),
    app.offline_event(uuid, text, text), app.offline_snapshot_data(uuid, uuid), app.offline_seller_json(uuid, uuid),
    app.offline_settings_json(uuid), app.offline_sale_json(uuid, uuid),
    app.offline_receive(uuid, uuid, jsonb, integer, text, uuid), app.offline_receive_all(uuid, uuid, jsonb, text, uuid),
    app.offline_cart(jsonb, jsonb), app.offline_issued_day(uuid, timestamptz),
    app.offline_business_date(uuid, uuid, timestamptz),
    app.shifts_offline_guard(), app.devices_offline_revoke(), app.day_closes_offline_guard(),
    app.fiscal_submissions_freeze(),
    app.post_sale_core_full(uuid, uuid, public.shifts, jsonb, uuid, numeric, text, jsonb, jsonb, text, uuid, numeric, jsonb)
    FROM PUBLIC, anon, authenticated;

-- Service role only (the worker).
REVOKE ALL ON FUNCTION app.offline_load_received(uuid, integer), app.offline_process(uuid, boolean, boolean, text),
    public.offline_worker_load(uuid, integer), public.offline_worker_process(uuid, boolean, boolean, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.offline_load_received(uuid, integer), app.offline_process(uuid, boolean, boolean, text),
    public.offline_worker_load(uuid, integer), public.offline_worker_process(uuid, boolean, boolean, text)
    TO service_role;

REVOKE ALL ON FUNCTION public.issue_offline_lease(text, text), public.sync_offline_sales(jsonb),
    public.import_offline_sales(uuid, jsonb), public.list_offline_sales(text, uuid), public.get_offline_sale(uuid),
    public.resolve_offline_sale(uuid, text, text, jsonb, uuid), public.get_offline_settings(),
    public.set_offline_settings(boolean, text, integer, integer, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.issue_offline_lease(text, text), public.sync_offline_sales(jsonb),
    public.import_offline_sales(uuid, jsonb), public.list_offline_sales(text, uuid), public.get_offline_sale(uuid),
    public.resolve_offline_sale(uuid, text, text, jsonb, uuid), public.get_offline_settings(),
    public.set_offline_settings(boolean, text, integer, integer, text)
    TO authenticated;
