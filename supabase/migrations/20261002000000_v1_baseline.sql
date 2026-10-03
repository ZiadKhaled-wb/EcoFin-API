-- =============================================================================
-- EcoTech Pro: V1 baseline schema (Jira EC-21, slice F02)
-- Target: Supabase (Postgres 15+). Tested on Postgres 16 with Supabase role stubs.
-- Spec:   docs/EcoTech_Pro_Data_Model.md (source of truth; this file implements it)
-- Date:   2026-10-02
-- =============================================================================
--
-- WHAT THIS IS
--   The single baseline for a FRESH Supabase project. It replaces
--   initialization-v2.1.sql + 0001..0004 for new installs. It refuses to run on
--   a database that already has public.organizations.
--   After this file, every change is a NEW migration file. Adding tables,
--   columns, enum values, functions or permissions never touches existing data.
--
-- DECISIONS (agreed by the team, 2 Oct 2026)
--   * Money is numeric(18,2). Average cost is numeric(18,4). Never float.
--   * Sales are their own documents. An installment sale = a sale + a contract
--     that finances it. A cash sale has no contract.
--   * Split payments are V1: one sale can have many payments (payment_allocations).
--   * Installment schedule lines are split into principal and profit.
--   * Stock: append-only stock_movements + stock_levels kept by trigger with
--     CHECK (on_hand >= 0). Overselling is impossible at the database level.
--   * Roles: OWNER, BRANCH_MANAGER, CASHIER, WAREHOUSE, COLLECTOR, ACCOUNTANT, LAWYER.
--   * V2 tables (HR, partners, notifications, cards, third-party finance) are
--     left out. V2 adds enum values with ALTER TYPE ... ADD VALUE.
--   * Owners join by emailed invite (no license keys).
--
-- ACCESS MODEL (Data Model §2)
--   * anon: nothing.
--   * authenticated (the API, calling with the employee's JWT):
--       - SELECT on tenant tables, rows limited by RLS to the caller's org.
--         PII columns (national_id) and secrets are NOT granted.
--       - NO insert/update/delete on any table.
--       - Writes go through SECURITY DEFINER functions in `public` with
--         SET search_path = ''. Each derives org/employee from auth.uid(),
--         calls app.require_permission(), locks rows, writes ledgers + audit.
--         Those functions are added by each slice in its own migration.
--   * service_role: platform jobs only (provisioning, scheduled jobs, ETA).
--   * Helpers live in schema `app`, which PostgREST does not expose.
--
-- DATA RULES ENFORCED HERE (not left to app code)
--   * Every tenant FK is composite (x_id, organization_id): cross-shop links
--     are impossible.
--   * ON DELETE RESTRICT everywhere. Nothing is hard-deleted.
--   * Ledgers, payments, issued documents and audit rows are append-only.
--     Corrections are new reversing rows (reverses_*_id, reversible once).
--   * Contracts and schedule lines: terms are frozen; only status/superseded move.
--   * stock_levels, cash_balances, store_credit_balances are maintained by
--     triggers and can't go negative (bank accounts excepted).
--   * Ledger rows can't be posted into a closed business day (K04).
--
-- ORDER RULES
--   R1. LANGUAGE sql bodies are validated at CREATE: SQL helpers after tables.
--   R2. Composite FK targets need UNIQUE (id, organization_id) first.
--   R3. Mutual FKs: one side is added later with ALTER TABLE (section 15).
--
-- HOW TO RUN
--   Local:  supabase db reset   (file lives in supabase/migrations/)
--   Remote: supabase db push, on an EMPTY project only.
-- =============================================================================

BEGIN;

DO $$
BEGIN
    IF to_regclass('public.organizations') IS NOT NULL THEN
        RAISE EXCEPTION 'baseline: public.organizations already exists. This file is for an EMPTY project only.';
    END IF;
    IF to_regrole('anon') IS NULL OR to_regrole('authenticated') IS NULL
       OR to_regrole('service_role') IS NULL THEN
        RAISE EXCEPTION 'baseline: Supabase roles anon / authenticated / service_role not found';
    END IF;
    IF to_regprocedure('auth.uid()') IS NULL OR to_regclass('auth.users') IS NULL THEN
        RAISE EXCEPTION 'baseline: auth.uid() / auth.users not found';
    END IF;
END $$;


-- =============================================================================
-- 1. EXTENSIONS, SCHEMAS
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS citext  WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;   -- fast POS search by name
-- gen_random_uuid() is built into Postgres 13+.

-- Private schema for helpers and triggers. Not exposed over /rest/v1.
CREATE SCHEMA IF NOT EXISTS app;
REVOKE ALL ON SCHEMA app FROM PUBLIC;
GRANT USAGE ON SCHEMA app TO authenticated, service_role;


-- =============================================================================
-- 2. ENUM TYPES (Data Model §9). Add values later with ALTER TYPE ... ADD VALUE.
-- =============================================================================

-- Platform and people
CREATE TYPE public.employee_role      AS ENUM ('OWNER', 'BRANCH_MANAGER', 'CASHIER', 'WAREHOUSE',
                                               'COLLECTOR', 'ACCOUNTANT', 'LAWYER');
CREATE TYPE public.org_status         AS ENUM ('active', 'suspended', 'expired', 'closed');
CREATE TYPE public.creditor_model     AS ENUM ('in_house');                 -- V2: third_party
CREATE TYPE public.device_status      AS ENUM ('unregistered', 'pending', 'active', 'revoked');
CREATE TYPE public.eta_environment    AS ENUM ('preprod', 'prod');
CREATE TYPE public.file_purpose       AS ENUM ('logo', 'product_image', 'customer_id', 'survey_photo',
                                               'signature', 'contract_pdf', 'promissory_note',
                                               'delivery_proof', 'expense_receipt', 'legal_document',
                                               'import', 'export', 'other');
CREATE TYPE public.job_status         AS ENUM ('queued', 'running', 'succeeded', 'failed', 'dead');
CREATE TYPE public.audit_severity     AS ENUM ('info', 'warning', 'critical');
CREATE TYPE public.import_kind        AS ENUM ('products', 'customers', 'suppliers', 'opening_stock',
                                               'opening_cash', 'opening_contracts', 'full_export');
CREATE TYPE public.import_status      AS ENUM ('uploaded', 'validating', 'validated', 'importing',
                                               'completed', 'failed', 'cancelled');

-- Documents (one list for numbering, ledger sources and audit)
CREATE TYPE public.doc_type AS ENUM (
    'sale', 'sales_return', 'quotation', 'sales_order', 'delivery', 'contract', 'payment',
    'purchase_order', 'purchase_invoice', 'purchase_return', 'supplier_payment',
    'transfer', 'stock_count', 'stock_adjustment', 'cash_transfer', 'expense',
    'warranty_claim', 'legal_case', 'shift', 'charge', 'contract_change', 'import');

-- Catalog and inventory
CREATE TYPE public.tax_kind            AS ENUM ('standard', 'zero', 'exempt');
CREATE TYPE public.unit_status         AS ENUM ('in_stock', 'reserved', 'in_transit', 'sold',
                                                'returned', 'in_repair', 'written_off');
CREATE TYPE public.stock_movement_type AS ENUM ('opening', 'purchase_in', 'purchase_return_out',
                                                'sale_out', 'sale_return_in', 'transfer_out',
                                                'transfer_in', 'adjustment', 'delivery_out',
                                                'claim_out', 'claim_in');
CREATE TYPE public.stock_state         AS ENUM ('sellable', 'damaged');   -- damaged returns are kept apart
CREATE TYPE public.reservation_status  AS ENUM ('active', 'released', 'fulfilled');
CREATE TYPE public.transfer_status     AS ENUM ('draft', 'sent', 'received', 'partially_received', 'cancelled');
CREATE TYPE public.count_status        AS ENUM ('open', 'posted', 'cancelled');
CREATE TYPE public.adjustment_reason   AS ENUM ('damage', 'loss', 'found', 'correction', 'count', 'other');

-- Purchasing and approvals
CREATE TYPE public.po_status               AS ENUM ('draft', 'sent', 'partially_received', 'received', 'cancelled');
CREATE TYPE public.purchase_invoice_status AS ENUM ('draft', 'pending_approval', 'approved', 'rejected');
CREATE TYPE public.purchase_refund_mode    AS ENUM ('supplier_credit', 'cash');
CREATE TYPE public.approval_kind           AS ENUM ('purchase_invoice', 'price_override', 'credit_exception',
                                                    'discount_above_cap', 'charge_waiver', 'reschedule',
                                                    'write_off', 'refund');
CREATE TYPE public.approval_status         AS ENUM ('pending', 'approved', 'rejected', 'cancelled');

-- Customers and sales
CREATE TYPE public.customer_status   AS ENUM ('active', 'watch', 'blocked');
CREATE TYPE public.survey_status     AS ENUM ('assigned', 'submitted', 'approved', 'rejected', 'cancelled');
CREATE TYPE public.quotation_status  AS ENUM ('draft', 'sent', 'accepted', 'expired', 'cancelled');
CREATE TYPE public.order_status      AS ENUM ('open', 'partially_delivered', 'delivered', 'cancelled');
CREATE TYPE public.fulfilment_mode   AS ENUM ('from_stock', 'to_order');
CREATE TYPE public.delivery_status   AS ENUM ('scheduled', 'out_for_delivery', 'delivered', 'failed', 'cancelled');
CREATE TYPE public.sale_kind         AS ENUM ('pos', 'delivery');
CREATE TYPE public.return_kind       AS ENUM ('return', 'void', 'exchange');
CREATE TYPE public.refund_method     AS ENUM ('cash', 'bank_transfer', 'store_credit', 'contract_adjustment');
CREATE TYPE public.return_condition  AS ENUM ('resellable', 'damaged');
CREATE TYPE public.claim_status      AS ENUM ('open', 'in_repair', 'repaired', 'replaced', 'rejected', 'closed');

-- Installments and legal
CREATE TYPE public.installment_frequency AS ENUM ('monthly', 'weekly');
CREATE TYPE public.late_fee_type         AS ENUM ('none', 'fixed', 'percent');
CREATE TYPE public.early_settlement_rule AS ENUM ('no_discount', 'waive_future_profit', 'percent_of_future_profit');
CREATE TYPE public.contract_status       AS ENUM ('active', 'completed', 'rescheduled', 'written_off', 'returned');
CREATE TYPE public.charge_kind           AS ENUM ('late_fee');
CREATE TYPE public.change_kind           AS ENUM ('early_settlement', 'reschedule', 'write_off', 'return_adjustment');
CREATE TYPE public.legal_status          AS ENUM ('preparing', 'filed', 'in_court', 'judgment', 'closed');

-- Money
CREATE TYPE public.cash_account_kind  AS ENUM ('safe', 'bank', 'drawer', 'collector_wallet');
CREATE TYPE public.cash_movement_type AS ENUM ('float_in', 'float_out', 'sale', 'refund', 'deposit',
                                               'collection', 'supplier_payment', 'supplier_refund',
                                               'expense', 'transfer_in', 'transfer_out', 'settlement',
                                               'adjustment', 'opening');
CREATE TYPE public.payment_direction  AS ENUM ('in', 'out');
CREATE TYPE public.payment_method     AS ENUM ('cash', 'bank_transfer', 'store_credit');   -- V2: card
CREATE TYPE public.cash_transfer_kind AS ENUM ('transfer', 'collector_settlement');
CREATE TYPE public.shift_status       AS ENUM ('open', 'closed');
CREATE TYPE public.commission_status  AS ENUM ('accrued', 'paid', 'cancelled');
CREATE TYPE public.day_close_status   AS ENUM ('closed', 'reopened');

-- Tax (ETA)
CREATE TYPE public.fiscal_doc_type AS ENUM ('b2c_receipt', 'b2c_return', 'b2b_invoice', 'b2b_credit_note');
CREATE TYPE public.fiscal_status   AS ENUM ('pending', 'submitted', 'accepted', 'rejected', 'failed', 'cancelled');


-- =============================================================================
-- 3. GENERIC TRIGGER FUNCTIONS (no table dependencies)
-- =============================================================================

CREATE FUNCTION app.set_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

-- Append-only guard: ledgers, payments, issued documents, audit rows.
CREATE FUNCTION app.forbid_update_delete()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    RAISE EXCEPTION 'APPEND_ONLY: % on %.% is not allowed. Post a reversing row instead.',
        TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME USING ERRCODE = 'P0001';
END;
$$;

-- No hard deletes on master data and status documents (archive or cancel instead).
CREATE FUNCTION app.forbid_delete()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    RAISE EXCEPTION 'NO_DELETE: rows in %.% are never deleted. Archive or cancel instead.',
        TG_TABLE_SCHEMA, TG_TABLE_NAME USING ERRCODE = 'P0001';
END;
$$;

-- Frozen rows: only the columns named in TG_ARGV may change on UPDATE.
-- Used for contracts (terms frozen, status moves) and schedule lines.
CREATE FUNCTION app.only_columns_change()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
    v_allowed text[] := TG_ARGV;
BEGIN
    IF (to_jsonb(OLD) - v_allowed) IS DISTINCT FROM (to_jsonb(NEW) - v_allowed) THEN
        RAISE EXCEPTION 'FROZEN_ROW: on %.% only these columns may change: %',
            TG_TABLE_SCHEMA, TG_TABLE_NAME, array_to_string(v_allowed, ', ')
            USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;


-- =============================================================================
-- 4. PLATFORM (no organization_id): plans, permissions, super admins, logins
-- =============================================================================
-- Conventions for every TENANT table below (Data Model §1):
--   id uuid PK, organization_id NOT NULL, UNIQUE (id, organization_id),
--   created_at, created_by. Master data also has updated_at/updated_by/archived_at.
--   The FK organization_id -> organizations and every *_by -> employees FK are
--   added by one loop in section 15, so they can't be forgotten.

CREATE TABLE public.plans (
    key            text PRIMARY KEY CHECK (key ~ '^[a-z0-9_]+$'),
    name           text NOT NULL,
    description    text,
    price_monthly  numeric(18,2) NOT NULL CHECK (price_monthly >= 0),
    max_branches   integer CHECK (max_branches > 0),        -- NULL = unlimited
    max_users      integer CHECK (max_users > 0),
    max_devices    integer CHECK (max_devices > 0),
    modules        text[] NOT NULL DEFAULT '{}',             -- e.g. {pos,installments,purchasing,legal}
    is_active      boolean NOT NULL DEFAULT true,
    display_order  integer NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- F06. The shared permission keys (must match the F03 contracts list).
CREATE TABLE public.permissions (
    key          text PRIMARY KEY CHECK (key ~ '^[a-z_]+(\.[a-z_]+)+$'),
    module       text NOT NULL,
    description  text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);

-- Default permissions per role. OWNER always has every permission (app.has_permission).
CREATE TABLE public.role_permissions (
    role            public.employee_role NOT NULL,
    permission_key  text NOT NULL REFERENCES public.permissions (key) ON DELETE RESTRICT,
    PRIMARY KEY (role, permission_key)
);

CREATE TABLE public.super_admins (
    auth_user_id  uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE RESTRICT,
    full_name     text NOT NULL,
    email         extensions.citext NOT NULL UNIQUE,
    is_active     boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- F04 lockout / rate limiting. Service role only.
CREATE TABLE public.login_attempts (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    identifier  text NOT NULL,                 -- lower-cased username or email
    tenant_slug text,
    success     boolean NOT NULL,
    ip          inet,
    user_agent  text,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX login_attempts_identifier_idx ON public.login_attempts (identifier, created_at DESC);
CREATE INDEX login_attempts_ip_idx         ON public.login_attempts (ip, created_at DESC);


-- =============================================================================
-- 5. ORGANIZATION, SETTINGS, BRANCHES, EMPLOYEES, DEVICES, INVITES
-- =============================================================================

CREATE TABLE public.organizations (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_slug          text NOT NULL UNIQUE
                         CHECK (tenant_slug ~ '^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])?$'),
    name                 text NOT NULL,
    legal_name           text,
    commercial_register  text,
    tax_registration_no  text,                         -- ETA registration number
    timezone             text NOT NULL DEFAULT 'Africa/Cairo',
    default_language     text NOT NULL DEFAULT 'ar' CHECK (default_language IN ('ar', 'en')),
    logo_file_id         uuid,                          -- FK in section 15 (R3)
    plan_key             text NOT NULL REFERENCES public.plans (key) ON DELETE RESTRICT,
    subscription_start   date,
    subscription_end     date,
    status               public.org_status NOT NULL DEFAULT 'active',
    creditor_model       public.creditor_model NOT NULL DEFAULT 'in_house',
    installments_enabled boolean NOT NULL DEFAULT true,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    CHECK (subscription_end IS NULL OR subscription_start IS NULL OR subscription_end >= subscription_start)
);
CREATE INDEX organizations_plan_idx ON public.organizations (plan_key);

-- P03. One row per org.
CREATE TABLE public.org_settings (
    organization_id              uuid PRIMARY KEY,
    receipt_header               text,
    receipt_footer               text,
    receipt_width_mm             integer NOT NULL DEFAULT 80 CHECK (receipt_width_mm IN (58, 80)),
    prices_include_vat           boolean NOT NULL DEFAULT true,
    default_tax_class_id         uuid,                  -- FK in section 15
    discount_caps                jsonb NOT NULL DEFAULT '{}'::jsonb,   -- {"CASHIER": 5, "BRANCH_MANAGER": 15} (%)
    return_policy_days           integer NOT NULL DEFAULT 14 CHECK (return_policy_days >= 0),
    purchase_approval_threshold  numeric(18,2) CHECK (purchase_approval_threshold >= 0),  -- NULL = no approval
    credit_limit_income_multiple numeric(6,2) CHECK (credit_limit_income_multiple >= 0),
    collector_commission_pct     numeric(5,2) NOT NULL DEFAULT 0 CHECK (collector_commission_pct BETWEEN 0 AND 100),
    allow_negative_bank          boolean NOT NULL DEFAULT false,
    updated_at                   timestamptz NOT NULL DEFAULT now(),
    updated_by                   uuid
);

-- P04 / P05. Feature flags and per-org module config. V2 providers become new keys.
CREATE TABLE public.organization_features (
    organization_id  uuid NOT NULL,
    feature_key      text NOT NULL CHECK (feature_key ~ '^[a-z0-9_.]+$'),
    is_enabled       boolean NOT NULL DEFAULT false,
    config           jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    PRIMARY KEY (organization_id, feature_key)
);

-- T02-T04. ETA connection. The client secret lives in Supabase Vault; only its id is stored.
CREATE TABLE public.eta_settings (
    organization_id         uuid PRIMARY KEY,
    environment             public.eta_environment NOT NULL DEFAULT 'preprod',
    client_id               text,
    client_secret_vault_id  uuid,
    activity_code           text,
    is_enabled              boolean NOT NULL DEFAULT false,
    updated_at              timestamptz NOT NULL DEFAULT now(),
    updated_by              uuid
);

-- P05. Manual subscription payments (online billing is P06, V2).
CREATE TABLE public.subscription_payments (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    plan_key         text NOT NULL REFERENCES public.plans (key) ON DELETE RESTRICT,
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    period_start     date NOT NULL,
    period_end       date NOT NULL CHECK (period_end >= period_start),
    paid_at          timestamptz NOT NULL DEFAULT now(),
    reference        text,
    recorded_by_admin uuid REFERENCES public.super_admins (auth_user_id) ON DELETE RESTRICT,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT subscription_payments_id_org_key UNIQUE (id, organization_id)
);
CREATE INDEX subscription_payments_org_idx ON public.subscription_payments (organization_id, period_start DESC);

CREATE TABLE public.branches (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    code             text NOT NULL CHECK (code ~ '^[A-Z0-9]{1,6}$'),   -- used in document numbers
    name             text NOT NULL,
    address          text,
    city             text,
    governorate      text,
    phone            text,
    eta_branch_code  text,
    is_main          boolean NOT NULL DEFAULT false,
    is_active        boolean NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    archived_at      timestamptz,
    CONSTRAINT branches_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT branches_code_key   UNIQUE (organization_id, code)
);
CREATE UNIQUE INDEX branches_one_main_idx ON public.branches (organization_id) WHERE is_main;

-- One employee row per shop. auth_user_id is NULL until the invite is accepted.
-- The same login can be an employee of several shops (see app.current_employee_id).
CREATE TABLE public.employees (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id       uuid NOT NULL,
    auth_user_id          uuid REFERENCES auth.users (id) ON DELETE RESTRICT,   -- one login may work for several shops
    full_name             text NOT NULL,
    phone                 text,
    email                 extensions.citext,
    username              extensions.citext CHECK (username ~ '^[a-z0-9._-]{3,32}$'),
    national_id           text,                          -- PII: not granted to authenticated
    role                  public.employee_role NOT NULL,
    default_branch_id     uuid,
    is_active             boolean NOT NULL DEFAULT true,
    must_change_password  boolean NOT NULL DEFAULT false,
    last_login_at         timestamptz,
    created_at            timestamptz NOT NULL DEFAULT now(),
    created_by            uuid,
    updated_at            timestamptz NOT NULL DEFAULT now(),
    updated_by            uuid,
    archived_at           timestamptz,
    CONSTRAINT employees_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT employees_auth_org_key UNIQUE (auth_user_id, organization_id),
    FOREIGN KEY (default_branch_id, organization_id) REFERENCES public.branches (id, organization_id)
);
CREATE UNIQUE INDEX employees_one_owner_idx    ON public.employees (organization_id) WHERE role = 'OWNER' AND archived_at IS NULL;
CREATE UNIQUE INDEX employees_username_idx     ON public.employees (organization_id, username) WHERE username IS NOT NULL;
CREATE UNIQUE INDEX employees_email_idx        ON public.employees (organization_id, email) WHERE email IS NOT NULL;
CREATE INDEX employees_org_role_idx            ON public.employees (organization_id, role) WHERE is_active;

-- Branch scope (F06). OWNER sees every branch without rows here.
CREATE TABLE public.employee_branches (
    organization_id  uuid NOT NULL,
    employee_id      uuid NOT NULL,
    branch_id        uuid NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    PRIMARY KEY (employee_id, branch_id),
    FOREIGN KEY (employee_id, organization_id) REFERENCES public.employees (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)   REFERENCES public.branches (id, organization_id)
);
CREATE INDEX employee_branches_branch_idx ON public.employee_branches (organization_id, branch_id);

-- Add (granted = true) or remove (false) one permission for one employee.
CREATE TABLE public.employee_permission_overrides (
    organization_id  uuid NOT NULL,
    employee_id      uuid NOT NULL,
    permission_key   text NOT NULL REFERENCES public.permissions (key) ON DELETE RESTRICT,
    granted          boolean NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    PRIMARY KEY (employee_id, permission_key),
    FOREIGN KEY (employee_id, organization_id) REFERENCES public.employees (id, organization_id)
);
CREATE INDEX employee_permission_overrides_org_idx ON public.employee_permission_overrides (organization_id);

-- POS terminals (ETA serial, shifts, offline sync).
CREATE TABLE public.devices (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    branch_id        uuid NOT NULL,
    name             text NOT NULL,
    eta_serial       text,
    eta_os_version   text,
    eta_status       public.device_status NOT NULL DEFAULT 'unregistered',
    is_active        boolean NOT NULL DEFAULT true,
    last_seen_at     timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    archived_at      timestamptz,
    CONSTRAINT devices_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (branch_id, organization_id) REFERENCES public.branches (id, organization_id)
);
CREATE INDEX devices_branch_idx ON public.devices (organization_id, branch_id);
CREATE UNIQUE INDEX devices_eta_serial_idx ON public.devices (organization_id, eta_serial) WHERE eta_serial IS NOT NULL;

-- P01 / O02. The employee row is created with the invite (auth_user_id NULL);
-- accepting links the auth user. Only the token hash is stored.
CREATE TABLE public.invites (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    employee_id      uuid NOT NULL,
    email            extensions.citext NOT NULL,
    token_hash       text NOT NULL UNIQUE,              -- not granted to authenticated
    expires_at       timestamptz NOT NULL,
    accepted_at      timestamptz,
    revoked_at       timestamptz,
    invited_by       uuid,                              -- NULL when sent by the platform (owner invite)
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT invites_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (employee_id, organization_id) REFERENCES public.employees (id, organization_id),
    CHECK (accepted_at IS NULL OR revoked_at IS NULL)
);
CREATE UNIQUE INDEX invites_one_open_idx ON public.invites (employee_id) WHERE accepted_at IS NULL AND revoked_at IS NULL;


-- =============================================================================
-- 6. FOUNDATION: FILES, NUMBERING, AUDIT, JOBS, IMPORTS
-- =============================================================================

-- F14. Objects in the private bucket `tenant-files`. Path must start with '<org id>/'.
CREATE TABLE public.files (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    bucket           text NOT NULL DEFAULT 'tenant-files',
    path             text NOT NULL,
    original_name    text,
    mime             text NOT NULL,
    size_bytes       bigint NOT NULL CHECK (size_bytes >= 0),
    sha256           char(64),
    purpose          public.file_purpose NOT NULL,
    entity_type      text,                               -- e.g. 'customer', 'field_survey', 'legal_case'
    entity_id        uuid,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT files_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT files_path_key   UNIQUE (bucket, path),
    CONSTRAINT files_path_has_org_prefix CHECK (path LIKE organization_id::text || '/%')
);
CREATE INDEX files_entity_idx ON public.files (organization_id, entity_type, entity_id);

-- F11. Gap-free counters per org / branch / document type / year.
-- Use app.next_document_number() inside the same transaction as the document.
CREATE TABLE public.document_counters (
    organization_id  uuid NOT NULL,
    branch_id        uuid NOT NULL,
    doc_type         public.doc_type NOT NULL,
    period_year      integer NOT NULL CHECK (period_year BETWEEN 2020 AND 2200),
    next_value       bigint NOT NULL DEFAULT 1 CHECK (next_value > 0),
    PRIMARY KEY (organization_id, branch_id, doc_type, period_year),
    FOREIGN KEY (branch_id, organization_id) REFERENCES public.branches (id, organization_id)
);

-- F07. Append-only. Written inside every write function (app.write_audit).
CREATE TABLE public.audit_log (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organization_id  uuid NOT NULL,
    branch_id        uuid,
    employee_id      uuid,                              -- NULL for platform/service actions
    super_admin_id   uuid REFERENCES public.super_admins (auth_user_id) ON DELETE RESTRICT,
    device_id        uuid,
    ip               inet,
    user_agent       text,
    request_id       text,
    action           text NOT NULL,                     -- e.g. 'sale.create', 'auth.login_failed'
    entity_type      text,
    entity_id        uuid,
    severity         public.audit_severity NOT NULL DEFAULT 'info',
    reason           text,
    before           jsonb,
    after            jsonb,
    created_at       timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (branch_id, organization_id)   REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (employee_id, organization_id) REFERENCES public.employees (id, organization_id),
    FOREIGN KEY (device_id, organization_id)   REFERENCES public.devices (id, organization_id)
);
CREATE INDEX audit_log_org_time_idx ON public.audit_log (organization_id, created_at DESC);
CREATE INDEX audit_log_entity_idx   ON public.audit_log (organization_id, entity_type, entity_id);
CREATE INDEX audit_log_employee_idx ON public.audit_log (organization_id, employee_id, created_at DESC);

-- F13. Job queue, claimed with app.claim_jobs() (FOR UPDATE SKIP LOCKED). Service role only.
CREATE TABLE public.jobs (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid REFERENCES public.organizations (id) ON DELETE RESTRICT,  -- NULL = platform job
    job_type         text NOT NULL,                     -- e.g. 'eta.submit', 'installments.assess_late_fees'
    payload          jsonb NOT NULL DEFAULT '{}'::jsonb,
    dedupe_key       text,
    status           public.job_status NOT NULL DEFAULT 'queued',
    run_at           timestamptz NOT NULL DEFAULT now(),
    attempts         integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    max_attempts     integer NOT NULL DEFAULT 5 CHECK (max_attempts > 0),
    locked_at        timestamptz,
    locked_by        text,
    last_error       text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    finished_at      timestamptz
);
CREATE INDEX jobs_ready_idx ON public.jobs (run_at) WHERE status = 'queued';
CREATE UNIQUE INDEX jobs_dedupe_idx ON public.jobs (job_type, dedupe_key)
    WHERE dedupe_key IS NOT NULL AND status IN ('queued', 'running');

-- M01 / M02 / M03.
CREATE TABLE public.import_jobs (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    kind             public.import_kind NOT NULL,
    status           public.import_status NOT NULL DEFAULT 'uploaded',
    file_id          uuid,
    result_file_id   uuid,
    dry_run          boolean NOT NULL DEFAULT true,
    rows_total       integer NOT NULL DEFAULT 0,
    rows_ok          integer NOT NULL DEFAULT 0,
    rows_failed      integer NOT NULL DEFAULT 0,
    report           jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    finished_at      timestamptz,
    CONSTRAINT import_jobs_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (file_id, organization_id)        REFERENCES public.files (id, organization_id),
    FOREIGN KEY (result_file_id, organization_id) REFERENCES public.files (id, organization_id)
);
CREATE INDEX import_jobs_org_idx ON public.import_jobs (organization_id, created_at DESC);

-- P03. Immutable versions; a contract stores the policy it used.
CREATE TABLE public.installment_policies (
    id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id           uuid NOT NULL,
    version                   integer NOT NULL CHECK (version > 0),
    min_down_payment_pct      numeric(5,2) NOT NULL DEFAULT 0 CHECK (min_down_payment_pct BETWEEN 0 AND 100),
    max_months                integer NOT NULL CHECK (max_months BETWEEN 1 AND 120),
    markup_tiers              jsonb NOT NULL,           -- [{"up_to_months": 6, "pct": 10}, ...] (flat = one tier)
    allowed_frequencies       public.installment_frequency[] NOT NULL DEFAULT '{monthly}',
    min_installment           numeric(18,2) NOT NULL DEFAULT 0 CHECK (min_installment >= 0),
    rounding_step             numeric(18,2) NOT NULL DEFAULT 1 CHECK (rounding_step > 0),  -- round installments to whole pounds by default
    late_fee_type             public.late_fee_type NOT NULL DEFAULT 'none',
    late_fee_value            numeric(18,2) NOT NULL DEFAULT 0 CHECK (late_fee_value >= 0),
    late_fee_recurring        boolean NOT NULL DEFAULT false,     -- once, or per overdue period
    late_fee_cap              numeric(18,2) CHECK (late_fee_cap >= 0),
    grace_days                integer NOT NULL DEFAULT 0 CHECK (grace_days >= 0),
    early_settlement_rule     public.early_settlement_rule NOT NULL DEFAULT 'no_discount',
    early_settlement_pct      numeric(5,2) CHECK (early_settlement_pct BETWEEN 0 AND 100),
    guarantor_required_above  numeric(18,2) CHECK (guarantor_required_above >= 0),
    survey_required_above     numeric(18,2) CHECK (survey_required_above >= 0),
    effective_from            timestamptz NOT NULL DEFAULT now(),
    created_at                timestamptz NOT NULL DEFAULT now(),
    created_by                uuid,
    CONSTRAINT installment_policies_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT installment_policies_version_key UNIQUE (organization_id, version),
    CHECK (jsonb_typeof(markup_tiers) = 'array' AND jsonb_array_length(markup_tiers) > 0),
    CHECK (cardinality(allowed_frequencies) > 0),
    CHECK (early_settlement_rule <> 'percent_of_future_profit' OR early_settlement_pct IS NOT NULL)
);


-- =============================================================================
-- 7. CATALOG AND TAX (C01, C02, T01)
-- =============================================================================

CREATE TABLE public.tax_classes (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    name             text NOT NULL,
    kind             public.tax_kind NOT NULL DEFAULT 'standard',
    rate             numeric(5,2) NOT NULL CHECK (rate BETWEEN 0 AND 100),
    eta_tax_type     text NOT NULL DEFAULT 'T1',        -- ETA code, e.g. T1 = VAT
    eta_subtype      text NOT NULL DEFAULT 'V009',
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    archived_at      timestamptz,
    CONSTRAINT tax_classes_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT tax_classes_name_key   UNIQUE (organization_id, name),
    CHECK (kind = 'standard' OR rate = 0)
);

CREATE TABLE public.categories (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    name             text NOT NULL,
    parent_id        uuid,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    archived_at      timestamptz,
    CONSTRAINT categories_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT categories_name_key   UNIQUE (organization_id, name),
    FOREIGN KEY (parent_id, organization_id) REFERENCES public.categories (id, organization_id),
    CHECK (parent_id IS DISTINCT FROM id)
);
CREATE INDEX categories_parent_idx ON public.categories (organization_id, parent_id);

CREATE TABLE public.products (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    name_ar          text NOT NULL,
    name_en          text,
    sku              text NOT NULL,
    barcode          text,
    category_id      uuid,
    unit_of_measure  text NOT NULL DEFAULT 'piece',
    cash_price       numeric(18,2) NOT NULL CHECK (cash_price >= 0),
    installment_price numeric(18,2) CHECK (installment_price >= 0),   -- NULL = use cash_price + policy markup
    avg_cost         numeric(18,4) NOT NULL DEFAULT 0 CHECK (avg_cost >= 0),  -- set only by purchase approval
    tax_class_id     uuid NOT NULL,
    warranty_months  integer NOT NULL DEFAULT 0 CHECK (warranty_months >= 0),
    is_serialized    boolean NOT NULL DEFAULT false,    -- phones etc.: tracked per unit (IMEI/serial)
    min_stock        integer NOT NULL DEFAULT 0 CHECK (min_stock >= 0),
    image_file_id    uuid,
    eta_item_code    text,                              -- EGS/GS1 code, required before ETA submission
    eta_item_type    text CHECK (eta_item_type IN ('EGS', 'GS1')),
    is_active        boolean NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    archived_at      timestamptz,
    CONSTRAINT products_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT products_sku_key    UNIQUE (organization_id, sku),
    FOREIGN KEY (category_id, organization_id)   REFERENCES public.categories (id, organization_id),
    FOREIGN KEY (tax_class_id, organization_id)  REFERENCES public.tax_classes (id, organization_id),
    FOREIGN KEY (image_file_id, organization_id) REFERENCES public.files (id, organization_id)
);
CREATE UNIQUE INDEX products_barcode_idx ON public.products (organization_id, barcode) WHERE barcode IS NOT NULL;
CREATE INDEX products_category_idx ON public.products (organization_id, category_id);
CREATE INDEX products_name_ar_trgm ON public.products USING gin (name_ar extensions.gin_trgm_ops);
CREATE INDEX products_name_en_trgm ON public.products USING gin (name_en extensions.gin_trgm_ops);


-- =============================================================================
-- 8. PURCHASING (U01-U06) — before inventory: units link to invoice lines
-- =============================================================================

CREATE TABLE public.suppliers (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid NOT NULL,
    name                text NOT NULL,
    phone               text,
    tax_registration_no text,
    address             text,
    payment_terms_days  integer NOT NULL DEFAULT 0 CHECK (payment_terms_days >= 0),
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid,
    updated_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          uuid,
    archived_at         timestamptz,
    CONSTRAINT suppliers_id_org_key UNIQUE (id, organization_id)
);
CREATE INDEX suppliers_org_idx  ON public.suppliers (organization_id, name);
CREATE INDEX suppliers_name_trgm ON public.suppliers USING gin (name extensions.gin_trgm_ops);

CREATE TABLE public.purchase_orders (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    number           text NOT NULL,
    supplier_id      uuid NOT NULL,
    branch_id        uuid NOT NULL,
    status           public.po_status NOT NULL DEFAULT 'draft',
    expected_date    date,
    notes            text,
    idempotency_key  text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    CONSTRAINT purchase_orders_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT purchase_orders_number_key UNIQUE (organization_id, number),
    CONSTRAINT purchase_orders_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (supplier_id, organization_id) REFERENCES public.suppliers (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)   REFERENCES public.branches (id, organization_id)
);
CREATE INDEX purchase_orders_supplier_idx ON public.purchase_orders (organization_id, supplier_id);
CREATE INDEX purchase_orders_status_idx   ON public.purchase_orders (organization_id, status);

CREATE TABLE public.purchase_order_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid NOT NULL,
    po_id               uuid NOT NULL,
    product_id          uuid NOT NULL,
    quantity            integer NOT NULL CHECK (quantity > 0),
    expected_unit_cost  numeric(18,2) CHECK (expected_unit_cost >= 0),
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid,
    CONSTRAINT purchase_order_lines_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (po_id, organization_id)      REFERENCES public.purchase_orders (id, organization_id),
    FOREIGN KEY (product_id, organization_id) REFERENCES public.products (id, organization_id)
);
CREATE INDEX purchase_order_lines_po_idx ON public.purchase_order_lines (organization_id, po_id);

-- Editable while draft / pending_approval; frozen once approved or rejected (trigger, section 16).
CREATE TABLE public.purchase_invoices (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid NOT NULL,
    number              text NOT NULL,
    supplier_invoice_no text,
    supplier_id         uuid NOT NULL,
    branch_id           uuid NOT NULL,
    po_id               uuid,
    invoice_date        date NOT NULL,
    status              public.purchase_invoice_status NOT NULL DEFAULT 'draft',
    subtotal            numeric(18,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    tax_total           numeric(18,2) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
    total               numeric(18,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
    approved_by         uuid,
    approved_at         timestamptz,
    rejected_reason     text,
    idempotency_key     text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid,
    updated_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          uuid,
    CONSTRAINT purchase_invoices_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT purchase_invoices_number_key UNIQUE (organization_id, number),
    CONSTRAINT purchase_invoices_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (supplier_id, organization_id) REFERENCES public.suppliers (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)   REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (po_id, organization_id)       REFERENCES public.purchase_orders (id, organization_id),
    CHECK (total = subtotal + tax_total),
    CHECK ((status = 'approved') = (approved_at IS NOT NULL))
);
CREATE UNIQUE INDEX purchase_invoices_supplier_no_idx
    ON public.purchase_invoices (organization_id, supplier_id, supplier_invoice_no)
    WHERE supplier_invoice_no IS NOT NULL AND status <> 'rejected';
CREATE INDEX purchase_invoices_supplier_idx ON public.purchase_invoices (organization_id, supplier_id, invoice_date DESC);
CREATE INDEX purchase_invoices_status_idx   ON public.purchase_invoices (organization_id, status);

CREATE TABLE public.purchase_invoice_lines (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    invoice_id       uuid NOT NULL,
    product_id       uuid NOT NULL,
    po_line_id       uuid,
    quantity         integer NOT NULL CHECK (quantity > 0),
    unit_cost        numeric(18,2) NOT NULL CHECK (unit_cost >= 0),
    tax_class_id     uuid NOT NULL,
    tax_amount       numeric(18,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    line_total       numeric(18,2) NOT NULL CHECK (line_total >= 0),
    serials          text[],                            -- serialized products: one serial per unit, units created on approval
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT purchase_invoice_lines_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (invoice_id, organization_id)   REFERENCES public.purchase_invoices (id, organization_id),
    FOREIGN KEY (product_id, organization_id)   REFERENCES public.products (id, organization_id),
    FOREIGN KEY (po_line_id, organization_id)   REFERENCES public.purchase_order_lines (id, organization_id),
    FOREIGN KEY (tax_class_id, organization_id) REFERENCES public.tax_classes (id, organization_id),
    CHECK (serials IS NULL OR cardinality(serials) = quantity)
);
CREATE INDEX purchase_invoice_lines_invoice_idx ON public.purchase_invoice_lines (organization_id, invoice_id);
CREATE INDEX purchase_invoice_lines_po_line_idx ON public.purchase_invoice_lines (organization_id, po_line_id) WHERE po_line_id IS NOT NULL;
CREATE INDEX purchase_invoice_lines_product_idx ON public.purchase_invoice_lines (organization_id, product_id);

-- U06 + price override, credit exception, over-cap discount, waivers, etc.
CREATE TABLE public.approvals (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    branch_id        uuid,
    kind             public.approval_kind NOT NULL,
    entity_type      text NOT NULL,
    entity_id        uuid,
    amount           numeric(18,2),
    payload          jsonb NOT NULL DEFAULT '{}'::jsonb,
    status           public.approval_status NOT NULL DEFAULT 'pending',
    requested_by     uuid NOT NULL,
    reason           text,
    decided_by       uuid,
    decided_at       timestamptz,
    decision_note    text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT approvals_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (branch_id, organization_id) REFERENCES public.branches (id, organization_id),
    CHECK ((status IN ('approved', 'rejected')) = (decided_at IS NOT NULL)),
    CHECK (decided_by IS NULL OR decided_by <> requested_by)          -- no self-approval
);
CREATE INDEX approvals_pending_idx ON public.approvals (organization_id, status, kind) WHERE status = 'pending';
CREATE INDEX approvals_entity_idx  ON public.approvals (organization_id, entity_type, entity_id);


-- =============================================================================
-- 9. INVENTORY (I01-I06): units, ledger, levels, reservations, transfers, counts
-- =============================================================================

-- I04. One row per serialized item (IMEI / serial). Status and branch change
-- only inside write functions (only those columns may change: trigger, section 16).
CREATE TABLE public.units (
    id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id          uuid NOT NULL,
    product_id               uuid NOT NULL,
    serial                   text NOT NULL,
    branch_id                uuid NOT NULL,             -- current location
    status                   public.unit_status NOT NULL DEFAULT 'in_stock',
    cost                     numeric(18,2) NOT NULL CHECK (cost >= 0),
    purchase_invoice_line_id uuid,                      -- NULL for opening stock (M02)
    created_at               timestamptz NOT NULL DEFAULT now(),
    created_by               uuid,
    updated_at               timestamptz NOT NULL DEFAULT now(),
    updated_by               uuid,
    CONSTRAINT units_id_org_key  UNIQUE (id, organization_id),
    CONSTRAINT units_serial_key  UNIQUE (organization_id, serial),
    FOREIGN KEY (product_id, organization_id) REFERENCES public.products (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)  REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (purchase_invoice_line_id, organization_id) REFERENCES public.purchase_invoice_lines (id, organization_id)
);
CREATE INDEX units_product_branch_idx ON public.units (organization_id, product_id, branch_id, status);
CREATE INDEX units_invoice_line_idx   ON public.units (organization_id, purchase_invoice_line_id) WHERE purchase_invoice_line_id IS NOT NULL;

-- Current stock per product and branch. Changed ONLY by the triggers on
-- stock_movements and stock_reservations (section 17). Never written directly.
CREATE TABLE public.stock_levels (
    organization_id  uuid NOT NULL,
    product_id       uuid NOT NULL,
    branch_id        uuid NOT NULL,
    stock_state      public.stock_state NOT NULL DEFAULT 'sellable',
    on_hand          integer NOT NULL DEFAULT 0,
    reserved         integer NOT NULL DEFAULT 0,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, product_id, branch_id, stock_state),
    FOREIGN KEY (product_id, organization_id) REFERENCES public.products (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)  REFERENCES public.branches (id, organization_id),
    CONSTRAINT stock_levels_no_oversell     CHECK (on_hand >= 0),
    CONSTRAINT stock_levels_reserved_range  CHECK (reserved >= 0 AND reserved <= on_hand),
    CONSTRAINT stock_levels_reserve_sellable CHECK (stock_state = 'sellable' OR reserved = 0)
);
CREATE INDEX stock_levels_branch_idx ON public.stock_levels (organization_id, branch_id);

-- The stock ledger. Append-only. Serialized products move one unit per row (±1).
CREATE TABLE public.stock_movements (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id       uuid NOT NULL,
    product_id            uuid NOT NULL,
    branch_id             uuid NOT NULL,
    unit_id               uuid,
    quantity              integer NOT NULL CHECK (quantity <> 0),
    type                  public.stock_movement_type NOT NULL,
    stock_state           public.stock_state NOT NULL DEFAULT 'sellable',   -- damaged returns go to 'damaged'
    unit_cost             numeric(18,4) NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),  -- cost at the time: inventory valuation (D04)
    source_type           public.doc_type NOT NULL,
    source_id             uuid NOT NULL,
    source_line_id        uuid,
    reverses_movement_id  uuid,
    business_date         date NOT NULL,                -- shop-local date; set by trigger if omitted
    created_at            timestamptz NOT NULL DEFAULT now(),
    created_by            uuid,
    CONSTRAINT stock_movements_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (product_id, organization_id) REFERENCES public.products (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)  REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (unit_id, organization_id)    REFERENCES public.units (id, organization_id),
    FOREIGN KEY (reverses_movement_id, organization_id) REFERENCES public.stock_movements (id, organization_id),
    CHECK (unit_id IS NULL OR quantity IN (1, -1))
);
CREATE UNIQUE INDEX stock_movements_reversed_once_idx ON public.stock_movements (reverses_movement_id) WHERE reverses_movement_id IS NOT NULL;
CREATE INDEX stock_movements_product_idx ON public.stock_movements (organization_id, product_id, branch_id, created_at DESC);
CREATE INDEX stock_movements_source_idx  ON public.stock_movements (organization_id, source_type, source_id);
CREATE INDEX stock_movements_unit_idx    ON public.stock_movements (organization_id, unit_id, created_at) WHERE unit_id IS NOT NULL;
CREATE INDEX stock_movements_date_idx    ON public.stock_movements (organization_id, branch_id, business_date);

-- S10. Held stock for sales orders. Trigger keeps stock_levels.reserved in sync.
CREATE TABLE public.stock_reservations (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    product_id       uuid NOT NULL,
    branch_id        uuid NOT NULL,
    unit_id          uuid,
    order_line_id    uuid NOT NULL,                     -- FK in section 15 (R3)
    quantity         integer NOT NULL CHECK (quantity > 0),
    status           public.reservation_status NOT NULL DEFAULT 'active',
    released_at      timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    CONSTRAINT stock_reservations_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (product_id, organization_id) REFERENCES public.products (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)  REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (unit_id, organization_id)    REFERENCES public.units (id, organization_id),
    CHECK (unit_id IS NULL OR quantity = 1),
    CHECK ((status = 'active') = (released_at IS NULL))
);
CREATE INDEX stock_reservations_active_idx ON public.stock_reservations (organization_id, product_id, branch_id) WHERE status = 'active';
CREATE INDEX stock_reservations_line_idx   ON public.stock_reservations (organization_id, order_line_id);
CREATE UNIQUE INDEX stock_reservations_unit_idx ON public.stock_reservations (unit_id) WHERE unit_id IS NOT NULL AND status = 'active';

-- I03. In transit = sent minus received.
CREATE TABLE public.stock_transfers (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    number           text NOT NULL,
    from_branch_id   uuid NOT NULL,
    to_branch_id     uuid NOT NULL,
    status           public.transfer_status NOT NULL DEFAULT 'draft',
    notes            text,
    sent_at          timestamptz,
    sent_by          uuid,
    received_at      timestamptz,
    received_by      uuid,
    idempotency_key  text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    CONSTRAINT stock_transfers_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT stock_transfers_number_key UNIQUE (organization_id, number),
    CONSTRAINT stock_transfers_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (from_branch_id, organization_id) REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (to_branch_id, organization_id)   REFERENCES public.branches (id, organization_id),
    CHECK (from_branch_id <> to_branch_id)
);
CREATE INDEX stock_transfers_open_idx ON public.stock_transfers (organization_id, to_branch_id, status);

CREATE TABLE public.stock_transfer_lines (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid NOT NULL,
    transfer_id        uuid NOT NULL,
    product_id         uuid NOT NULL,
    unit_id            uuid,
    qty_sent           integer NOT NULL CHECK (qty_sent > 0),
    qty_received       integer CHECK (qty_received >= 0 AND qty_received <= qty_sent),
    discrepancy_reason text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid,
    CONSTRAINT stock_transfer_lines_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (transfer_id, organization_id) REFERENCES public.stock_transfers (id, organization_id),
    FOREIGN KEY (product_id, organization_id)  REFERENCES public.products (id, organization_id),
    FOREIGN KEY (unit_id, organization_id)     REFERENCES public.units (id, organization_id),
    CHECK (unit_id IS NULL OR qty_sent = 1),
    CHECK (qty_received IS NULL OR qty_received = qty_sent OR discrepancy_reason IS NOT NULL)
);
CREATE INDEX stock_transfer_lines_transfer_idx ON public.stock_transfer_lines (organization_id, transfer_id);

-- I02. Count sheet; posting creates a stock_adjustment.
CREATE TABLE public.stock_counts (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    number           text NOT NULL,
    branch_id        uuid NOT NULL,
    category_id      uuid,                              -- NULL = whole branch
    status           public.count_status NOT NULL DEFAULT 'open',
    posted_at        timestamptz,
    posted_by        uuid,
    idempotency_key  text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    CONSTRAINT stock_counts_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT stock_counts_number_key UNIQUE (organization_id, number),
    CONSTRAINT stock_counts_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (branch_id, organization_id)   REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (category_id, organization_id) REFERENCES public.categories (id, organization_id),
    CHECK ((status = 'posted') = (posted_at IS NOT NULL))
);
CREATE UNIQUE INDEX stock_counts_one_open_idx ON public.stock_counts (organization_id, branch_id, COALESCE(category_id, '00000000-0000-0000-0000-000000000000'::uuid)) WHERE status = 'open';

CREATE TABLE public.stock_count_lines (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    count_id         uuid NOT NULL,
    product_id       uuid NOT NULL,
    unit_id          uuid,
    expected_qty     integer NOT NULL CHECK (expected_qty >= 0),
    counted_qty      integer CHECK (counted_qty >= 0),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    CONSTRAINT stock_count_lines_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (count_id, organization_id)   REFERENCES public.stock_counts (id, organization_id),
    FOREIGN KEY (product_id, organization_id) REFERENCES public.products (id, organization_id),
    FOREIGN KEY (unit_id, organization_id)    REFERENCES public.units (id, organization_id)
);
CREATE UNIQUE INDEX stock_count_lines_product_idx ON public.stock_count_lines (count_id, product_id, COALESCE(unit_id, '00000000-0000-0000-0000-000000000000'::uuid));

-- I02. Append-only: an adjustment is posted once; a mistake is fixed by another adjustment.
CREATE TABLE public.stock_adjustments (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    number           text NOT NULL,
    branch_id        uuid NOT NULL,
    reason           public.adjustment_reason NOT NULL,
    note             text,
    count_id         uuid,
    idempotency_key  text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT stock_adjustments_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT stock_adjustments_number_key UNIQUE (organization_id, number),
    CONSTRAINT stock_adjustments_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (branch_id, organization_id) REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (count_id, organization_id)  REFERENCES public.stock_counts (id, organization_id),
    CHECK (reason <> 'other' OR note IS NOT NULL)
);
CREATE UNIQUE INDEX stock_adjustments_one_per_count_idx ON public.stock_adjustments (count_id) WHERE count_id IS NOT NULL;

CREATE TABLE public.stock_adjustment_lines (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    adjustment_id    uuid NOT NULL,
    product_id       uuid NOT NULL,
    unit_id          uuid,
    quantity         integer NOT NULL CHECK (quantity <> 0),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT stock_adjustment_lines_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (adjustment_id, organization_id) REFERENCES public.stock_adjustments (id, organization_id),
    FOREIGN KEY (product_id, organization_id)    REFERENCES public.products (id, organization_id),
    FOREIGN KEY (unit_id, organization_id)       REFERENCES public.units (id, organization_id),
    CHECK (unit_id IS NULL OR quantity IN (1, -1))
);
CREATE INDEX stock_adjustment_lines_adj_idx ON public.stock_adjustment_lines (organization_id, adjustment_id);


-- =============================================================================
-- 10. CUSTOMERS (R01-R05)
-- =============================================================================

CREATE TABLE public.customers (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid NOT NULL,
    full_name           text NOT NULL,
    phones              text[] NOT NULL DEFAULT '{}',
    national_id         text,                          -- PII: read only through a customer.view_pii function
    birth_date          date,
    gender              text CHECK (gender IN ('male', 'female')),
    address             text,
    city                text,
    job                 text,
    employer            text,
    monthly_income      numeric(18,2) CHECK (monthly_income >= 0),
    credit_limit        numeric(18,2) NOT NULL DEFAULT 0 CHECK (credit_limit >= 0),  -- R03; exposure comes from a view
    status              public.customer_status NOT NULL DEFAULT 'active',
    is_business         boolean NOT NULL DEFAULT false,
    tax_registration_no text,                          -- B2B e-invoices (T04)
    id_file_id          uuid,
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid,
    updated_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          uuid,
    archived_at         timestamptz,
    CONSTRAINT customers_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (id_file_id, organization_id) REFERENCES public.files (id, organization_id),
    CHECK (NOT is_business OR tax_registration_no IS NOT NULL)
);
CREATE UNIQUE INDEX customers_national_id_idx ON public.customers (organization_id, national_id) WHERE national_id IS NOT NULL;
CREATE INDEX customers_org_idx       ON public.customers (organization_id, created_at DESC);
CREATE INDEX customers_phones_idx    ON public.customers USING gin (phones);
CREATE INDEX customers_name_trgm     ON public.customers USING gin (full_name extensions.gin_trgm_ops);

-- R04. Open point (Data Model §11.1): linked to a customer when the guarantor is also one.
CREATE TABLE public.guarantors (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    full_name        text NOT NULL,
    phone            text,
    national_id      text,                              -- PII
    address          text,
    job              text,
    monthly_income   numeric(18,2) CHECK (monthly_income >= 0),
    customer_id      uuid,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    archived_at      timestamptz,
    CONSTRAINT guarantors_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (customer_id, organization_id) REFERENCES public.customers (id, organization_id)
);
CREATE UNIQUE INDEX guarantors_national_id_idx ON public.guarantors (organization_id, national_id) WHERE national_id IS NOT NULL;
CREATE INDEX guarantors_customer_idx ON public.guarantors (organization_id, customer_id) WHERE customer_id IS NOT NULL;

CREATE TABLE public.customer_guarantors (
    organization_id  uuid NOT NULL,
    customer_id      uuid NOT NULL,
    guarantor_id     uuid NOT NULL,
    relation         text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    PRIMARY KEY (customer_id, guarantor_id),
    FOREIGN KEY (customer_id, organization_id)  REFERENCES public.customers (id, organization_id),
    FOREIGN KEY (guarantor_id, organization_id) REFERENCES public.guarantors (id, organization_id)
);
CREATE INDEX customer_guarantors_guarantor_idx ON public.customer_guarantors (organization_id, guarantor_id);

-- R05. Photos live in files (entity_type = 'field_survey').
CREATE TABLE public.field_surveys (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    customer_id      uuid NOT NULL,
    assigned_to      uuid NOT NULL,
    status           public.survey_status NOT NULL DEFAULT 'assigned',
    scores           jsonb NOT NULL DEFAULT '{}'::jsonb,
    notes            text,
    lat              numeric(9,6) CHECK (lat BETWEEN -90 AND 90),
    lng              numeric(9,6) CHECK (lng BETWEEN -180 AND 180),
    gps_accuracy_m   numeric(8,2) CHECK (gps_accuracy_m >= 0),
    submitted_at     timestamptz,
    decided_by       uuid,
    decided_at       timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    CONSTRAINT field_surveys_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (customer_id, organization_id) REFERENCES public.customers (id, organization_id),
    FOREIGN KEY (assigned_to, organization_id) REFERENCES public.employees (id, organization_id)
);
CREATE INDEX field_surveys_customer_idx ON public.field_surveys (organization_id, customer_id);
CREATE INDEX field_surveys_assignee_idx ON public.field_surveys (organization_id, assigned_to, status);


-- =============================================================================
-- 11. CASH ACCOUNTS AND SHIFTS (K01, K02, N06) — sales and payments point here
-- =============================================================================

CREATE TABLE public.cash_accounts (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    branch_id        uuid,                              -- NULL only for org-wide bank accounts
    name             text NOT NULL,
    kind             public.cash_account_kind NOT NULL,
    employee_id      uuid,                              -- collector wallets only
    is_active        boolean NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    archived_at      timestamptz,
    CONSTRAINT cash_accounts_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT cash_accounts_name_key   UNIQUE NULLS NOT DISTINCT (organization_id, branch_id, name),
    FOREIGN KEY (branch_id, organization_id)   REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (employee_id, organization_id) REFERENCES public.employees (id, organization_id),
    CHECK ((kind = 'collector_wallet') = (employee_id IS NOT NULL)),
    CHECK (kind = 'bank' OR branch_id IS NOT NULL)
);
-- Open point §11.3: one wallet per collector (not per day).
CREATE UNIQUE INDEX cash_accounts_one_wallet_idx ON public.cash_accounts (organization_id, employee_id) WHERE kind = 'collector_wallet';
CREATE INDEX cash_accounts_branch_idx ON public.cash_accounts (organization_id, branch_id, kind);

-- Current balance per cash account. Changed ONLY by the trigger on cash_movements.
CREATE TABLE public.cash_balances (
    organization_id  uuid NOT NULL,
    cash_account_id  uuid NOT NULL,
    balance          numeric(18,2) NOT NULL DEFAULT 0,
    allow_negative   boolean NOT NULL DEFAULT false,   -- bank accounts when org_settings.allow_negative_bank
    updated_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (cash_account_id),
    FOREIGN KEY (cash_account_id, organization_id) REFERENCES public.cash_accounts (id, organization_id),
    CONSTRAINT cash_balances_not_negative CHECK (allow_negative OR balance >= 0)
);

-- K02. Expected cash = opening float + this shift's movements (view).
CREATE TABLE public.shifts (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid NOT NULL,
    number             text NOT NULL,
    branch_id          uuid NOT NULL,
    device_id          uuid,
    employee_id        uuid NOT NULL,
    drawer_account_id  uuid NOT NULL,
    opening_float      numeric(18,2) NOT NULL DEFAULT 0 CHECK (opening_float >= 0),
    opened_at          timestamptz NOT NULL DEFAULT now(),
    closed_at          timestamptz,
    closed_by          uuid,
    counted_cash       numeric(18,2) CHECK (counted_cash >= 0),
    count_breakdown    jsonb,                           -- {"200": 5, "100": 3, ...}
    expected_cash      numeric(18,2),                   -- snapshot at close
    difference_reason  text,
    status             public.shift_status NOT NULL DEFAULT 'open',
    idempotency_key    text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         uuid,
    CONSTRAINT shifts_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT shifts_number_key UNIQUE (organization_id, number),
    CONSTRAINT shifts_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (branch_id, organization_id)         REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (device_id, organization_id)         REFERENCES public.devices (id, organization_id),
    FOREIGN KEY (employee_id, organization_id)       REFERENCES public.employees (id, organization_id),
    FOREIGN KEY (drawer_account_id, organization_id) REFERENCES public.cash_accounts (id, organization_id),
    CHECK ((status = 'closed') = (closed_at IS NOT NULL)),
    CHECK (status = 'open' OR counted_cash IS NOT NULL)
);
CREATE UNIQUE INDEX shifts_one_open_per_employee_idx ON public.shifts (organization_id, employee_id) WHERE status = 'open';
CREATE UNIQUE INDEX shifts_one_open_per_device_idx   ON public.shifts (organization_id, device_id) WHERE status = 'open' AND device_id IS NOT NULL;
CREATE UNIQUE INDEX shifts_one_open_per_drawer_idx   ON public.shifts (organization_id, drawer_account_id) WHERE status = 'open';
CREATE INDEX shifts_branch_idx ON public.shifts (organization_id, branch_id, opened_at DESC);


-- =============================================================================
-- 12. SALES DOCUMENTS (S01-S12)
-- =============================================================================

-- S09. No stock or money effect.
CREATE TABLE public.quotations (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    number           text NOT NULL,
    customer_id      uuid,
    branch_id        uuid NOT NULL,
    status           public.quotation_status NOT NULL DEFAULT 'draft',
    valid_until      date,
    subtotal         numeric(18,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    discount_total   numeric(18,2) NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
    tax_total        numeric(18,2) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
    total            numeric(18,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
    notes            text,
    idempotency_key  text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    CONSTRAINT quotations_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT quotations_number_key UNIQUE (organization_id, number),
    CONSTRAINT quotations_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (customer_id, organization_id) REFERENCES public.customers (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)   REFERENCES public.branches (id, organization_id)
);
CREATE INDEX quotations_customer_idx ON public.quotations (organization_id, customer_id);

CREATE TABLE public.quotation_lines (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    quotation_id     uuid NOT NULL,
    line_no          integer NOT NULL CHECK (line_no > 0),
    product_id       uuid,                              -- NULL = custom item (furniture made to order)
    description      text,
    custom_notes     text,
    quantity         integer NOT NULL CHECK (quantity > 0),
    unit_price       numeric(18,2) NOT NULL CHECK (unit_price >= 0),
    discount_amount  numeric(18,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    tax_amount       numeric(18,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    line_total       numeric(18,2) NOT NULL CHECK (line_total >= 0),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT quotation_lines_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT quotation_lines_no_key     UNIQUE (quotation_id, line_no),
    FOREIGN KEY (quotation_id, organization_id) REFERENCES public.quotations (id, organization_id),
    FOREIGN KEY (product_id, organization_id)   REFERENCES public.products (id, organization_id),
    CHECK (product_id IS NOT NULL OR description IS NOT NULL)
);

-- S10. Deposits are payment_allocations pointing at the order.
CREATE TABLE public.sales_orders (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    number           text NOT NULL,
    customer_id      uuid NOT NULL,
    branch_id        uuid NOT NULL,
    quotation_id     uuid,
    status           public.order_status NOT NULL DEFAULT 'open',
    prices_include_vat boolean NOT NULL,
    subtotal         numeric(18,2) NOT NULL CHECK (subtotal >= 0),
    discount_total   numeric(18,2) NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
    tax_total        numeric(18,2) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
    total            numeric(18,2) NOT NULL CHECK (total >= 0),
    delivery_address text,
    notes            text,
    cancelled_reason text,
    idempotency_key  text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    CONSTRAINT sales_orders_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT sales_orders_number_key UNIQUE (organization_id, number),
    CONSTRAINT sales_orders_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (customer_id, organization_id)  REFERENCES public.customers (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)    REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (quotation_id, organization_id) REFERENCES public.quotations (id, organization_id),
    CHECK (total = subtotal - discount_total + CASE WHEN prices_include_vat THEN 0 ELSE tax_total END),
    CHECK (status <> 'cancelled' OR cancelled_reason IS NOT NULL)
);
CREATE INDEX sales_orders_customer_idx ON public.sales_orders (organization_id, customer_id);
CREATE INDEX sales_orders_status_idx   ON public.sales_orders (organization_id, branch_id, status);

CREATE TABLE public.sales_order_lines (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    order_id         uuid NOT NULL,
    line_no          integer NOT NULL CHECK (line_no > 0),
    product_id       uuid NOT NULL,
    custom_notes     text,                              -- size, colour, fabric...
    quantity         integer NOT NULL CHECK (quantity > 0),
    unit_price       numeric(18,2) NOT NULL CHECK (unit_price >= 0),
    discount_amount  numeric(18,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    tax_class_id     uuid NOT NULL,
    tax_rate         numeric(5,2) NOT NULL CHECK (tax_rate BETWEEN 0 AND 100),
    tax_amount       numeric(18,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    line_total       numeric(18,2) NOT NULL CHECK (line_total >= 0),
    fulfilment       public.fulfilment_mode NOT NULL DEFAULT 'from_stock',
    po_line_id       uuid,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT sales_order_lines_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT sales_order_lines_no_key     UNIQUE (order_id, line_no),
    FOREIGN KEY (order_id, organization_id)     REFERENCES public.sales_orders (id, organization_id),
    FOREIGN KEY (product_id, organization_id)   REFERENCES public.products (id, organization_id),
    FOREIGN KEY (tax_class_id, organization_id) REFERENCES public.tax_classes (id, organization_id),
    FOREIGN KEY (po_line_id, organization_id)   REFERENCES public.purchase_order_lines (id, organization_id)
);
CREATE INDEX sales_order_lines_order_idx ON public.sales_order_lines (organization_id, order_id);

-- S11. Completing a delivery issues a `sales` row for the delivered lines.
CREATE TABLE public.deliveries (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid NOT NULL,
    number             text NOT NULL,
    order_id           uuid NOT NULL,
    branch_id          uuid NOT NULL,
    scheduled_date     date NOT NULL,
    time_window        text,
    address            text NOT NULL,
    driver_employee_id uuid,
    status             public.delivery_status NOT NULL DEFAULT 'scheduled',
    failed_reason      text,
    proof_file_id      uuid,
    delivered_at       timestamptz,
    idempotency_key    text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         uuid,
    CONSTRAINT deliveries_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT deliveries_number_key UNIQUE (organization_id, number),
    CONSTRAINT deliveries_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (order_id, organization_id)           REFERENCES public.sales_orders (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)          REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (driver_employee_id, organization_id) REFERENCES public.employees (id, organization_id),
    FOREIGN KEY (proof_file_id, organization_id)      REFERENCES public.files (id, organization_id),
    CHECK ((status = 'delivered') = (delivered_at IS NOT NULL)),
    CHECK (status <> 'failed' OR failed_reason IS NOT NULL)
);
CREATE INDEX deliveries_schedule_idx ON public.deliveries (organization_id, branch_id, scheduled_date, status);
CREATE INDEX deliveries_order_idx    ON public.deliveries (organization_id, order_id);

CREATE TABLE public.delivery_lines (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    delivery_id      uuid NOT NULL,
    order_line_id    uuid NOT NULL,
    unit_id          uuid,
    quantity         integer NOT NULL CHECK (quantity > 0),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT delivery_lines_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (delivery_id, organization_id)   REFERENCES public.deliveries (id, organization_id),
    FOREIGN KEY (order_line_id, organization_id) REFERENCES public.sales_order_lines (id, organization_id),
    FOREIGN KEY (unit_id, organization_id)       REFERENCES public.units (id, organization_id),
    CHECK (unit_id IS NULL OR quantity = 1)
);
CREATE INDEX delivery_lines_delivery_idx   ON public.delivery_lines (organization_id, delivery_id);
CREATE INDEX delivery_lines_order_line_idx ON public.delivery_lines (organization_id, order_line_id);

-- S01. Never updated. A void is a sales_returns row with kind 'void'.
-- An installment sale is a sale + a contract (contracts.sale_id).
CREATE TABLE public.sales (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid NOT NULL,
    number             text NOT NULL,
    branch_id          uuid NOT NULL,
    device_id          uuid,
    shift_id           uuid,
    customer_id        uuid,                            -- NULL = walk-in cash customer
    order_id           uuid,
    delivery_id        uuid,
    kind               public.sale_kind NOT NULL DEFAULT 'pos',
    is_b2b             boolean NOT NULL DEFAULT false,
    prices_include_vat boolean NOT NULL,                -- snapshot of org_settings
    subtotal           numeric(18,2) NOT NULL CHECK (subtotal >= 0),
    discount_total     numeric(18,2) NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
    tax_total          numeric(18,2) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
    total              numeric(18,2) NOT NULL CHECK (total >= 0),
    cost_total         numeric(18,2) NOT NULL DEFAULT 0 CHECK (cost_total >= 0),  -- snapshot for margin (D02)
    discount_reason    text,
    issued_at          timestamptz NOT NULL DEFAULT now(),
    business_date      date NOT NULL,
    offline_created_at timestamptz,                     -- S08: when the device made it offline
    idempotency_key    text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid,
    CONSTRAINT sales_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT sales_number_key UNIQUE (organization_id, number),
    CONSTRAINT sales_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (branch_id, organization_id)   REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (device_id, organization_id)   REFERENCES public.devices (id, organization_id),
    FOREIGN KEY (shift_id, organization_id)    REFERENCES public.shifts (id, organization_id),
    FOREIGN KEY (customer_id, organization_id) REFERENCES public.customers (id, organization_id),
    FOREIGN KEY (order_id, organization_id)    REFERENCES public.sales_orders (id, organization_id),
    FOREIGN KEY (delivery_id, organization_id) REFERENCES public.deliveries (id, organization_id),
    CHECK (total = subtotal - discount_total + CASE WHEN prices_include_vat THEN 0 ELSE tax_total END),
    CHECK (kind <> 'delivery' OR (order_id IS NOT NULL AND delivery_id IS NOT NULL)),
    CHECK (NOT is_b2b OR customer_id IS NOT NULL),
    CHECK (discount_total = 0 OR discount_reason IS NOT NULL)
);
CREATE INDEX sales_branch_date_idx ON public.sales (organization_id, branch_id, business_date DESC);
CREATE INDEX sales_customer_idx    ON public.sales (organization_id, customer_id) WHERE customer_id IS NOT NULL;
CREATE INDEX sales_shift_idx       ON public.sales (organization_id, shift_id) WHERE shift_id IS NOT NULL;
CREATE INDEX sales_order_idx       ON public.sales (organization_id, order_id) WHERE order_id IS NOT NULL;
CREATE UNIQUE INDEX sales_one_per_delivery_idx ON public.sales (delivery_id) WHERE delivery_id IS NOT NULL;

CREATE TABLE public.sale_lines (
    id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id            uuid NOT NULL,
    sale_id                    uuid NOT NULL,
    line_no                    integer NOT NULL CHECK (line_no > 0),
    product_id                 uuid NOT NULL,
    unit_id                    uuid,
    order_line_id              uuid,
    quantity                   integer NOT NULL CHECK (quantity > 0),
    unit_price                 numeric(18,2) NOT NULL CHECK (unit_price >= 0),
    discount_amount            numeric(18,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),   -- includes its share of a whole-sale discount
    tax_class_id               uuid NOT NULL,
    tax_rate                   numeric(5,2) NOT NULL CHECK (tax_rate BETWEEN 0 AND 100),        -- snapshot
    tax_amount                 numeric(18,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    line_total                 numeric(18,2) NOT NULL CHECK (line_total >= 0),
    unit_cost                  numeric(18,4) NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),          -- snapshot for margin
    warranty_until             date,
    price_override_approval_id uuid,
    created_at                 timestamptz NOT NULL DEFAULT now(),
    created_by                 uuid,
    CONSTRAINT sale_lines_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT sale_lines_id_unit_key UNIQUE (id, unit_id, organization_id),   -- returns must return the sold unit
    CONSTRAINT sale_lines_no_key     UNIQUE (sale_id, line_no),
    FOREIGN KEY (sale_id, organization_id)       REFERENCES public.sales (id, organization_id),
    FOREIGN KEY (product_id, organization_id)    REFERENCES public.products (id, organization_id),
    FOREIGN KEY (unit_id, organization_id)       REFERENCES public.units (id, organization_id),
    FOREIGN KEY (order_line_id, organization_id) REFERENCES public.sales_order_lines (id, organization_id),
    FOREIGN KEY (tax_class_id, organization_id)  REFERENCES public.tax_classes (id, organization_id),
    FOREIGN KEY (price_override_approval_id, organization_id) REFERENCES public.approvals (id, organization_id),
    CHECK (unit_id IS NULL OR quantity = 1),
    CHECK (discount_amount <= unit_price * quantity)
);
CREATE INDEX sale_lines_sale_idx    ON public.sale_lines (organization_id, sale_id);
CREATE INDEX sale_lines_product_idx ON public.sale_lines (organization_id, product_id);
CREATE INDEX sale_lines_unit_idx    ON public.sale_lines (organization_id, unit_id) WHERE unit_id IS NOT NULL;
CREATE INDEX sale_lines_order_line_idx ON public.sale_lines (organization_id, order_line_id) WHERE order_line_id IS NOT NULL;

-- S05 / S07. Return, same-day void, or exchange (exchange_sale_id = the new sale).
CREATE TABLE public.sales_returns (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    number           text NOT NULL,
    sale_id          uuid NOT NULL,
    branch_id        uuid NOT NULL,
    shift_id         uuid,
    kind             public.return_kind NOT NULL,
    refund_method    public.refund_method NOT NULL,
    subtotal         numeric(18,2) NOT NULL CHECK (subtotal >= 0),
    tax_total        numeric(18,2) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
    total            numeric(18,2) NOT NULL CHECK (total >= 0),
    reason           text NOT NULL,
    exchange_sale_id uuid,
    approval_id      uuid,
    business_date    date NOT NULL,
    idempotency_key  text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT sales_returns_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT sales_returns_number_key UNIQUE (organization_id, number),
    CONSTRAINT sales_returns_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (sale_id, organization_id)          REFERENCES public.sales (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)        REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (shift_id, organization_id)         REFERENCES public.shifts (id, organization_id),
    FOREIGN KEY (exchange_sale_id, organization_id) REFERENCES public.sales (id, organization_id),
    FOREIGN KEY (approval_id, organization_id)      REFERENCES public.approvals (id, organization_id),
    CHECK ((kind = 'exchange') = (exchange_sale_id IS NOT NULL)),
    CHECK (exchange_sale_id IS DISTINCT FROM sale_id)
);
CREATE INDEX sales_returns_sale_idx ON public.sales_returns (organization_id, sale_id);
CREATE INDEX sales_returns_date_idx ON public.sales_returns (organization_id, branch_id, business_date DESC);
CREATE INDEX sales_returns_exchange_idx ON public.sales_returns (organization_id, exchange_sale_id) WHERE exchange_sale_id IS NOT NULL;
CREATE UNIQUE INDEX sales_returns_one_void_idx ON public.sales_returns (sale_id) WHERE kind = 'void';

CREATE TABLE public.sales_return_lines (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    return_id        uuid NOT NULL,
    sale_line_id     uuid NOT NULL,
    unit_id          uuid,
    quantity         integer NOT NULL CHECK (quantity > 0),
    condition        public.return_condition NOT NULL DEFAULT 'resellable',
    refund_amount    numeric(18,2) NOT NULL CHECK (refund_amount >= 0),
    tax_amount       numeric(18,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    unit_cost        numeric(18,4) NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),   -- restock at the original cost
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT sales_return_lines_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (return_id, organization_id)    REFERENCES public.sales_returns (id, organization_id),
    FOREIGN KEY (sale_line_id, organization_id) REFERENCES public.sale_lines (id, organization_id),
    FOREIGN KEY (unit_id, organization_id)      REFERENCES public.units (id, organization_id),
    FOREIGN KEY (sale_line_id, unit_id, organization_id) REFERENCES public.sale_lines (id, unit_id, organization_id),
    CHECK (unit_id IS NULL OR quantity = 1)
);
CREATE INDEX sales_return_lines_return_idx    ON public.sales_return_lines (organization_id, return_id);
CREATE INDEX sales_return_lines_sale_line_idx ON public.sales_return_lines (organization_id, sale_line_id);

-- S12. Warranty period comes from sale_lines.warranty_until.
CREATE TABLE public.warranty_claims (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid NOT NULL,
    number              text NOT NULL,
    branch_id           uuid NOT NULL,
    sale_line_id        uuid NOT NULL,
    unit_id             uuid,
    customer_id         uuid,
    issue               text NOT NULL,
    status              public.claim_status NOT NULL DEFAULT 'open',
    replacement_unit_id uuid,
    resolution          text,
    closed_at           timestamptz,
    idempotency_key     text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid,
    updated_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          uuid,
    CONSTRAINT warranty_claims_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT warranty_claims_number_key UNIQUE (organization_id, number),
    CONSTRAINT warranty_claims_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (branch_id, organization_id)           REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (sale_line_id, organization_id)        REFERENCES public.sale_lines (id, organization_id),
    FOREIGN KEY (unit_id, organization_id)             REFERENCES public.units (id, organization_id),
    FOREIGN KEY (customer_id, organization_id)         REFERENCES public.customers (id, organization_id),
    FOREIGN KEY (replacement_unit_id, organization_id) REFERENCES public.units (id, organization_id),
    CHECK (replacement_unit_id IS NULL OR status = 'replaced')
);
CREATE INDEX warranty_claims_open_idx ON public.warranty_claims (organization_id, status) WHERE status NOT IN ('closed', 'rejected');
CREATE INDEX warranty_claims_unit_idx ON public.warranty_claims (organization_id, unit_id) WHERE unit_id IS NOT NULL;
CREATE INDEX warranty_claims_sale_line_idx ON public.warranty_claims (organization_id, sale_line_id);


-- =============================================================================
-- 13. INSTALLMENTS (N01-N07) AND LEGAL (L01)
-- =============================================================================

-- N02. Terms never change after issue; only status / current_version move
-- (trigger, section 16). Finances either a sale (POS) or a sales order (furniture,
-- open point §11.2: both supported, the slice picks one).
CREATE TABLE public.contracts (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid NOT NULL,
    number             text NOT NULL,
    customer_id        uuid NOT NULL,
    branch_id          uuid NOT NULL,
    sale_id            uuid,
    order_id           uuid,
    policy_id          uuid NOT NULL,
    creditor           public.creditor_model NOT NULL,  -- snapshot of the org at issue
    cash_price         numeric(18,2) NOT NULL CHECK (cash_price > 0),
    down_payment       numeric(18,2) NOT NULL DEFAULT 0 CHECK (down_payment >= 0),
    financed_amount    numeric(18,2) NOT NULL CHECK (financed_amount > 0),
    markup_pct         numeric(7,4) NOT NULL CHECK (markup_pct >= 0),
    markup_amount      numeric(18,2) NOT NULL CHECK (markup_amount >= 0),
    total_payable      numeric(18,2) NOT NULL,
    installments_count integer NOT NULL CHECK (installments_count BETWEEN 1 AND 520),
    frequency          public.installment_frequency NOT NULL,
    first_due_date     date NOT NULL,
    current_version    integer NOT NULL DEFAULT 1 CHECK (current_version > 0),
    status             public.contract_status NOT NULL DEFAULT 'active',
    closed_at          timestamptz,
    credit_approval_id uuid,                            -- set when the credit limit was exceeded with approval
    is_migrated        boolean NOT NULL DEFAULT false,  -- M02 opening contracts
    migration_batch_id uuid,
    idempotency_key    text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         uuid,
    CONSTRAINT contracts_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT contracts_id_customer_key UNIQUE (id, customer_id, organization_id),
    CONSTRAINT contracts_number_key UNIQUE (organization_id, number),
    CONSTRAINT contracts_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (customer_id, organization_id)        REFERENCES public.customers (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)          REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (sale_id, organization_id)            REFERENCES public.sales (id, organization_id),
    FOREIGN KEY (order_id, organization_id)           REFERENCES public.sales_orders (id, organization_id),
    FOREIGN KEY (policy_id, organization_id)          REFERENCES public.installment_policies (id, organization_id),
    FOREIGN KEY (credit_approval_id, organization_id) REFERENCES public.approvals (id, organization_id),
    FOREIGN KEY (migration_batch_id, organization_id) REFERENCES public.import_jobs (id, organization_id),
    CONSTRAINT contracts_one_source  CHECK (is_migrated OR num_nonnulls(sale_id, order_id) = 1),
    CONSTRAINT contracts_down_le_price CHECK (down_payment < cash_price),
    CONSTRAINT contracts_financed    CHECK (financed_amount = cash_price - down_payment),
    CONSTRAINT contracts_total       CHECK (total_payable = financed_amount + markup_amount),
    CHECK ((status = 'active') = (closed_at IS NULL) OR status = 'rescheduled')
);
CREATE UNIQUE INDEX contracts_one_per_sale_idx  ON public.contracts (sale_id)  WHERE sale_id IS NOT NULL;
CREATE UNIQUE INDEX contracts_one_per_order_idx ON public.contracts (order_id) WHERE order_id IS NOT NULL;
CREATE INDEX contracts_customer_idx ON public.contracts (organization_id, customer_id, status);
CREATE INDEX contracts_status_idx   ON public.contracts (organization_id, status, branch_id);
CREATE INDEX contracts_policy_idx   ON public.contracts (organization_id, policy_id);

CREATE TABLE public.contract_guarantors (
    organization_id  uuid NOT NULL,
    contract_id      uuid NOT NULL,
    guarantor_id     uuid NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    PRIMARY KEY (contract_id, guarantor_id),
    FOREIGN KEY (contract_id, organization_id)  REFERENCES public.contracts (id, organization_id),
    FOREIGN KEY (guarantor_id, organization_id) REFERENCES public.guarantors (id, organization_id)
);
CREATE INDEX contract_guarantors_guarantor_idx ON public.contract_guarantors (organization_id, guarantor_id);

-- Each line is split into principal + profit. Rescheduling adds a new version
-- and marks the old lines superseded (the only column that may change).
-- Paid / overdue status comes from v_schedule_line_status.
CREATE TABLE public.schedule_lines (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    contract_id      uuid NOT NULL,
    version          integer NOT NULL CHECK (version > 0),
    seq              integer NOT NULL CHECK (seq > 0),
    due_date         date NOT NULL,
    principal        numeric(18,2) NOT NULL CHECK (principal >= 0),
    profit           numeric(18,2) NOT NULL CHECK (profit >= 0),
    amount           numeric(18,2) GENERATED ALWAYS AS (principal + profit) STORED,
    superseded       boolean NOT NULL DEFAULT false,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT schedule_lines_id_org_key      UNIQUE (id, organization_id),
    CONSTRAINT schedule_lines_id_contract_key UNIQUE (id, contract_id, organization_id),
    CONSTRAINT schedule_lines_seq_key         UNIQUE (contract_id, version, seq),
    FOREIGN KEY (contract_id, organization_id) REFERENCES public.contracts (id, organization_id),
    CHECK (principal + profit > 0)
);
CREATE INDEX schedule_lines_due_idx ON public.schedule_lines (organization_id, due_date) WHERE NOT superseded;
CREATE INDEX schedule_lines_contract_idx ON public.schedule_lines (organization_id, contract_id, version, seq);

-- N04. A job run twice can't double a fee: UNIQUE (line, kind, assessed_on).
CREATE TABLE public.charges (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    contract_id      uuid NOT NULL,
    schedule_line_id uuid NOT NULL,
    kind             public.charge_kind NOT NULL DEFAULT 'late_fee',
    assessed_on      date NOT NULL,
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT charges_id_org_key      UNIQUE (id, organization_id),
    CONSTRAINT charges_id_contract_key UNIQUE (id, contract_id, organization_id),
    CONSTRAINT charges_once_key        UNIQUE (schedule_line_id, kind, assessed_on),
    FOREIGN KEY (schedule_line_id, contract_id, organization_id)
        REFERENCES public.schedule_lines (id, contract_id, organization_id)
);
CREATE INDEX charges_contract_idx ON public.charges (organization_id, contract_id);

CREATE TABLE public.charge_waivers (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    charge_id        uuid NOT NULL,
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    reason           text NOT NULL,
    approved_by      uuid NOT NULL,
    approval_id      uuid,
    idempotency_key  text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT charge_waivers_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT charge_waivers_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (charge_id, organization_id)   REFERENCES public.charges (id, organization_id),
    FOREIGN KEY (approval_id, organization_id) REFERENCES public.approvals (id, organization_id)
);
CREATE INDEX charge_waivers_charge_idx ON public.charge_waivers (organization_id, charge_id);

-- N05. Early settlement, reschedule, write-off, return adjustment.
CREATE TABLE public.contract_changes (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    contract_id      uuid NOT NULL,
    kind             public.change_kind NOT NULL,
    old_version      integer NOT NULL,
    new_version      integer,
    amount           numeric(18,2) CHECK (amount >= 0),  -- payoff / written-off / adjusted amount
    profit_waived    numeric(18,2) NOT NULL DEFAULT 0 CHECK (profit_waived >= 0),
    reason           text NOT NULL,
    approved_by      uuid,
    approval_id      uuid,
    sales_return_id  uuid,
    idempotency_key  text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT contract_changes_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT contract_changes_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (contract_id, organization_id)     REFERENCES public.contracts (id, organization_id),
    FOREIGN KEY (approval_id, organization_id)     REFERENCES public.approvals (id, organization_id),
    FOREIGN KEY (sales_return_id, organization_id) REFERENCES public.sales_returns (id, organization_id),
    CHECK (new_version IS NULL OR new_version > old_version),          -- reschedule / return adjustment / payoff can add a version
    CHECK (kind <> 'reschedule' OR new_version IS NOT NULL),
    CHECK (kind <> 'return_adjustment' OR sales_return_id IS NOT NULL)
);
CREATE INDEX contract_changes_contract_idx ON public.contract_changes (organization_id, contract_id);

-- L01 (absorbs N09). Documents live in files (entity_type = 'legal_case').
CREATE TABLE public.legal_cases (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid NOT NULL,
    number             text NOT NULL,
    contract_id        uuid NOT NULL,
    customer_id        uuid NOT NULL,
    case_number        text,                            -- court's number
    court              text,
    case_type          text,
    lawyer_employee_id uuid,
    status             public.legal_status NOT NULL DEFAULT 'preparing',
    claim_amount       numeric(18,2) CHECK (claim_amount >= 0),
    next_hearing_date  date,
    closed_at          timestamptz,
    outcome            text,
    idempotency_key    text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         uuid,
    CONSTRAINT legal_cases_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT legal_cases_number_key UNIQUE (organization_id, number),
    CONSTRAINT legal_cases_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (contract_id, customer_id, organization_id) REFERENCES public.contracts (id, customer_id, organization_id),
    FOREIGN KEY (customer_id, organization_id)        REFERENCES public.customers (id, organization_id),
    FOREIGN KEY (lawyer_employee_id, organization_id) REFERENCES public.employees (id, organization_id),
    CHECK ((status = 'closed') = (closed_at IS NOT NULL))
);
CREATE UNIQUE INDEX legal_cases_one_open_idx ON public.legal_cases (contract_id) WHERE status <> 'closed';
CREATE INDEX legal_cases_hearing_idx ON public.legal_cases (organization_id, next_hearing_date) WHERE status <> 'closed';
CREATE INDEX legal_cases_lawyer_idx  ON public.legal_cases (organization_id, lawyer_employee_id);

CREATE TABLE public.legal_hearings (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    case_id          uuid NOT NULL,
    hearing_date     date NOT NULL,
    outcome          text,
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    CONSTRAINT legal_hearings_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (case_id, organization_id) REFERENCES public.legal_cases (id, organization_id)
);
CREATE INDEX legal_hearings_case_idx ON public.legal_hearings (organization_id, case_id, hearing_date);

CREATE TABLE public.legal_case_notes (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    case_id          uuid NOT NULL,
    note             text NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT legal_case_notes_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (case_id, organization_id) REFERENCES public.legal_cases (id, organization_id)
);
CREATE INDEX legal_case_notes_case_idx ON public.legal_case_notes (organization_id, case_id);


-- =============================================================================
-- 14. MONEY: PAYMENTS, CASH LEDGER, STORE CREDIT, SUPPLIERS, EXPENSES, CLOSE, ETA
-- =============================================================================

-- Customer-side money. Append-only. A payment is reversed by a new payment
-- with reverses_payment_id; views ignore reversed payments.
CREATE TABLE public.payments (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid NOT NULL,
    number              text NOT NULL,
    branch_id           uuid NOT NULL,
    direction           public.payment_direction NOT NULL,
    method              public.payment_method NOT NULL,
    amount              numeric(18,2) NOT NULL CHECK (amount > 0),
    customer_id         uuid,
    cash_account_id     uuid,                           -- NULL only for store credit
    shift_id            uuid,
    reference           text,                           -- bank transfer reference
    received_by         uuid,
    paid_at             timestamptz NOT NULL DEFAULT now(),
    business_date       date NOT NULL,
    reverses_payment_id uuid,
    reason              text,
    idempotency_key     text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid,
    CONSTRAINT payments_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT payments_number_key UNIQUE (organization_id, number),
    CONSTRAINT payments_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (branch_id, organization_id)           REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (customer_id, organization_id)         REFERENCES public.customers (id, organization_id),
    FOREIGN KEY (cash_account_id, organization_id)     REFERENCES public.cash_accounts (id, organization_id),
    FOREIGN KEY (shift_id, organization_id)            REFERENCES public.shifts (id, organization_id),
    FOREIGN KEY (reverses_payment_id, organization_id) REFERENCES public.payments (id, organization_id),
    CHECK ((method = 'store_credit') = (cash_account_id IS NULL)),
    CHECK (method <> 'store_credit' OR customer_id IS NOT NULL),
    CHECK (method <> 'bank_transfer' OR reference IS NOT NULL),
    CHECK (reverses_payment_id IS NULL OR reason IS NOT NULL)
);
CREATE UNIQUE INDEX payments_reversed_once_idx ON public.payments (reverses_payment_id) WHERE reverses_payment_id IS NOT NULL;
CREATE INDEX payments_customer_idx ON public.payments (organization_id, customer_id, paid_at DESC) WHERE customer_id IS NOT NULL;
CREATE INDEX payments_date_idx     ON public.payments (organization_id, branch_id, business_date);
CREATE INDEX payments_shift_idx    ON public.payments (organization_id, shift_id) WHERE shift_id IS NOT NULL;

-- What each payment paid. Exactly one target per row. Collections (N03) are
-- split into principal / profit; contract_id is stored for fast balances and
-- checked against the line / charge by composite FK.
CREATE TABLE public.payment_allocations (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    payment_id       uuid NOT NULL,
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    sale_id          uuid,
    order_id         uuid,                              -- deposit
    schedule_line_id uuid,
    charge_id        uuid,
    return_id        uuid,                              -- refund (direction = out)
    contract_id      uuid,
    principal_amount numeric(18,2) CHECK (principal_amount >= 0),
    profit_amount    numeric(18,2) CHECK (profit_amount >= 0),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT payment_allocations_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (payment_id, organization_id) REFERENCES public.payments (id, organization_id),
    FOREIGN KEY (sale_id, organization_id)    REFERENCES public.sales (id, organization_id),
    FOREIGN KEY (order_id, organization_id)   REFERENCES public.sales_orders (id, organization_id),
    FOREIGN KEY (return_id, organization_id)  REFERENCES public.sales_returns (id, organization_id),
    FOREIGN KEY (schedule_line_id, contract_id, organization_id)
        REFERENCES public.schedule_lines (id, contract_id, organization_id),
    FOREIGN KEY (charge_id, contract_id, organization_id)
        REFERENCES public.charges (id, contract_id, organization_id),
    CONSTRAINT payment_allocations_one_target
        CHECK (num_nonnulls(sale_id, order_id, schedule_line_id, charge_id, return_id) = 1),
    CHECK ((schedule_line_id IS NOT NULL OR charge_id IS NOT NULL) = (contract_id IS NOT NULL)),
    CHECK ((schedule_line_id IS NOT NULL) = (principal_amount IS NOT NULL AND profit_amount IS NOT NULL)),
    CHECK (schedule_line_id IS NULL OR principal_amount + profit_amount = amount)
);
CREATE INDEX payment_allocations_payment_idx  ON public.payment_allocations (organization_id, payment_id);
CREATE INDEX payment_allocations_sale_idx     ON public.payment_allocations (organization_id, sale_id) WHERE sale_id IS NOT NULL;
CREATE INDEX payment_allocations_order_idx    ON public.payment_allocations (organization_id, order_id) WHERE order_id IS NOT NULL;
CREATE INDEX payment_allocations_line_idx     ON public.payment_allocations (organization_id, schedule_line_id) WHERE schedule_line_id IS NOT NULL;
CREATE INDEX payment_allocations_charge_idx   ON public.payment_allocations (organization_id, charge_id) WHERE charge_id IS NOT NULL;
CREATE INDEX payment_allocations_return_idx   ON public.payment_allocations (organization_id, return_id) WHERE return_id IS NOT NULL;
CREATE INDEX payment_allocations_contract_idx ON public.payment_allocations (organization_id, contract_id) WHERE contract_id IS NOT NULL;

-- Overpayments and store-credit refunds. Balance kept in store_credit_balances (>= 0).
CREATE TABLE public.store_credit_movements (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    customer_id      uuid NOT NULL,
    amount           numeric(18,2) NOT NULL CHECK (amount <> 0),
    source_type      public.doc_type NOT NULL,
    source_id        uuid NOT NULL,
    branch_id        uuid NOT NULL,
    business_date    date NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT store_credit_movements_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (customer_id, organization_id) REFERENCES public.customers (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)   REFERENCES public.branches (id, organization_id)
);
CREATE INDEX store_credit_movements_customer_idx ON public.store_credit_movements (organization_id, customer_id, created_at DESC);

CREATE TABLE public.store_credit_balances (
    organization_id  uuid NOT NULL,
    customer_id      uuid NOT NULL,
    balance          numeric(18,2) NOT NULL DEFAULT 0,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (customer_id),
    FOREIGN KEY (customer_id, organization_id) REFERENCES public.customers (id, organization_id),
    CONSTRAINT store_credit_not_negative CHECK (balance >= 0)
);

-- K01 / N06. Moving money between accounts; collector settlements record any shortage.
CREATE TABLE public.cash_transfers (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    number           text NOT NULL,
    from_account_id  uuid NOT NULL,
    to_account_id    uuid NOT NULL,
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    kind             public.cash_transfer_kind NOT NULL DEFAULT 'transfer',
    shortage_amount  numeric(18,2) NOT NULL DEFAULT 0 CHECK (shortage_amount >= 0),
    reason           text,
    business_date    date NOT NULL,
    idempotency_key  text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT cash_transfers_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT cash_transfers_number_key UNIQUE (organization_id, number),
    CONSTRAINT cash_transfers_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (from_account_id, organization_id) REFERENCES public.cash_accounts (id, organization_id),
    FOREIGN KEY (to_account_id, organization_id)   REFERENCES public.cash_accounts (id, organization_id),
    CHECK (from_account_id <> to_account_id),
    CHECK (shortage_amount = 0 OR (kind = 'collector_settlement' AND reason IS NOT NULL))
);
CREATE INDEX cash_transfers_from_idx ON public.cash_transfers (organization_id, from_account_id, created_at DESC);
CREATE INDEX cash_transfers_to_idx   ON public.cash_transfers (organization_id, to_account_id, created_at DESC);

CREATE TABLE public.expense_categories (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    name             text NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    archived_at      timestamptz,
    CONSTRAINT expense_categories_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT expense_categories_name_key   UNIQUE (organization_id, name)
);

-- K03. Append-only; a mistake is reversed by a new expense row.
CREATE TABLE public.expenses (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid NOT NULL,
    number              text NOT NULL,
    branch_id           uuid NOT NULL,
    category_id         uuid NOT NULL,
    amount              numeric(18,2) NOT NULL CHECK (amount > 0),
    cash_account_id     uuid NOT NULL,
    shift_id            uuid,
    note                text,
    receipt_file_id     uuid,
    reverses_expense_id uuid,
    business_date       date NOT NULL,
    idempotency_key     text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid,
    CONSTRAINT expenses_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT expenses_number_key UNIQUE (organization_id, number),
    CONSTRAINT expenses_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (branch_id, organization_id)           REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (category_id, organization_id)         REFERENCES public.expense_categories (id, organization_id),
    FOREIGN KEY (cash_account_id, organization_id)     REFERENCES public.cash_accounts (id, organization_id),
    FOREIGN KEY (shift_id, organization_id)            REFERENCES public.shifts (id, organization_id),
    FOREIGN KEY (receipt_file_id, organization_id)     REFERENCES public.files (id, organization_id),
    FOREIGN KEY (reverses_expense_id, organization_id) REFERENCES public.expenses (id, organization_id)
);
CREATE UNIQUE INDEX expenses_reversed_once_idx ON public.expenses (reverses_expense_id) WHERE reverses_expense_id IS NOT NULL;
CREATE INDEX expenses_date_idx ON public.expenses (organization_id, branch_id, business_date);

-- N06. Never mixed into cash; paid out through an expense.
CREATE TABLE public.collector_commissions (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid NOT NULL,
    employee_id        uuid NOT NULL,
    payment_id         uuid NOT NULL,
    amount             numeric(18,2) NOT NULL CHECK (amount > 0),
    status             public.commission_status NOT NULL DEFAULT 'accrued',
    paid_by_expense_id uuid,
    paid_at            timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         uuid,
    CONSTRAINT collector_commissions_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT collector_commissions_payment_key UNIQUE (payment_id),
    FOREIGN KEY (employee_id, organization_id)        REFERENCES public.employees (id, organization_id),
    FOREIGN KEY (payment_id, organization_id)         REFERENCES public.payments (id, organization_id),
    FOREIGN KEY (paid_by_expense_id, organization_id) REFERENCES public.expenses (id, organization_id),
    CHECK ((status = 'paid') = (paid_by_expense_id IS NOT NULL AND paid_at IS NOT NULL))
);
CREATE INDEX collector_commissions_employee_idx ON public.collector_commissions (organization_id, employee_id, status);

-- Supplier-side money (U03). Append-only, same reversal rule as payments.
CREATE TABLE public.supplier_payments (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid NOT NULL,
    number              text NOT NULL,
    supplier_id         uuid NOT NULL,
    branch_id           uuid NOT NULL,
    cash_account_id     uuid NOT NULL,
    amount              numeric(18,2) NOT NULL CHECK (amount > 0),
    paid_at             timestamptz NOT NULL DEFAULT now(),
    business_date       date NOT NULL,
    reference           text,
    reverses_payment_id uuid,
    reason              text,
    idempotency_key     text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid,
    CONSTRAINT supplier_payments_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT supplier_payments_number_key UNIQUE (organization_id, number),
    CONSTRAINT supplier_payments_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (supplier_id, organization_id)         REFERENCES public.suppliers (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)           REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (cash_account_id, organization_id)     REFERENCES public.cash_accounts (id, organization_id),
    FOREIGN KEY (reverses_payment_id, organization_id) REFERENCES public.supplier_payments (id, organization_id),
    CHECK (reverses_payment_id IS NULL OR reason IS NOT NULL)
);
CREATE UNIQUE INDEX supplier_payments_reversed_once_idx ON public.supplier_payments (reverses_payment_id) WHERE reverses_payment_id IS NOT NULL;
CREATE INDEX supplier_payments_supplier_idx ON public.supplier_payments (organization_id, supplier_id, paid_at DESC);

CREATE TABLE public.supplier_payment_allocations (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid NOT NULL,
    supplier_payment_id uuid NOT NULL,
    purchase_invoice_id uuid NOT NULL,
    amount              numeric(18,2) NOT NULL CHECK (amount > 0),
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid,
    CONSTRAINT supplier_payment_allocations_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (supplier_payment_id, organization_id) REFERENCES public.supplier_payments (id, organization_id),
    FOREIGN KEY (purchase_invoice_id, organization_id) REFERENCES public.purchase_invoices (id, organization_id)
);
CREATE INDEX supplier_payment_allocations_payment_idx ON public.supplier_payment_allocations (organization_id, supplier_payment_id);
CREATE INDEX supplier_payment_allocations_invoice_idx ON public.supplier_payment_allocations (organization_id, purchase_invoice_id);

-- U04. Append-only.
CREATE TABLE public.purchase_returns (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid NOT NULL,
    number              text NOT NULL,
    purchase_invoice_id uuid NOT NULL,
    supplier_id         uuid NOT NULL,
    branch_id           uuid NOT NULL,
    refund_mode         public.purchase_refund_mode NOT NULL,
    cash_account_id     uuid,
    subtotal            numeric(18,2) NOT NULL CHECK (subtotal >= 0),
    tax_total           numeric(18,2) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
    total               numeric(18,2) NOT NULL CHECK (total >= 0),
    reason              text NOT NULL,
    business_date       date NOT NULL,
    idempotency_key     text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid,
    CONSTRAINT purchase_returns_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT purchase_returns_number_key UNIQUE (organization_id, number),
    CONSTRAINT purchase_returns_idem_key   UNIQUE (organization_id, idempotency_key),
    FOREIGN KEY (purchase_invoice_id, organization_id) REFERENCES public.purchase_invoices (id, organization_id),
    FOREIGN KEY (supplier_id, organization_id)         REFERENCES public.suppliers (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)           REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (cash_account_id, organization_id)     REFERENCES public.cash_accounts (id, organization_id),
    CHECK ((refund_mode = 'cash') = (cash_account_id IS NOT NULL)),
    CHECK (total = subtotal + tax_total)
);
CREATE INDEX purchase_returns_invoice_idx ON public.purchase_returns (organization_id, purchase_invoice_id);

CREATE TABLE public.purchase_return_lines (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    return_id        uuid NOT NULL,
    invoice_line_id  uuid NOT NULL,
    product_id       uuid NOT NULL,
    unit_id          uuid,
    quantity         integer NOT NULL CHECK (quantity > 0),
    unit_cost        numeric(18,2) NOT NULL CHECK (unit_cost >= 0),
    tax_amount       numeric(18,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    line_total       numeric(18,2) NOT NULL CHECK (line_total >= 0),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT purchase_return_lines_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (return_id, organization_id)       REFERENCES public.purchase_returns (id, organization_id),
    FOREIGN KEY (invoice_line_id, organization_id) REFERENCES public.purchase_invoice_lines (id, organization_id),
    FOREIGN KEY (product_id, organization_id)      REFERENCES public.products (id, organization_id),
    FOREIGN KEY (unit_id, organization_id)         REFERENCES public.units (id, organization_id),
    CHECK (unit_id IS NULL OR quantity = 1)
);
CREATE INDEX purchase_return_lines_return_idx  ON public.purchase_return_lines (organization_id, return_id);
CREATE INDEX purchase_return_lines_inv_line_idx ON public.purchase_return_lines (organization_id, invoice_line_id);

-- The cash ledger. Append-only. Balance kept in cash_balances by trigger.
CREATE TABLE public.cash_movements (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id      uuid NOT NULL,
    cash_account_id      uuid NOT NULL,
    branch_id            uuid NOT NULL,                 -- the account's branch; for org-wide banks, the paying branch
    shift_id             uuid,
    amount               numeric(18,2) NOT NULL CHECK (amount <> 0),   -- + in, - out
    type                 public.cash_movement_type NOT NULL,
    source_type          public.doc_type NOT NULL,
    source_id            uuid NOT NULL,
    reverses_movement_id uuid,
    note                 text,
    business_date        date NOT NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid,
    CONSTRAINT cash_movements_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (cash_account_id, organization_id)      REFERENCES public.cash_accounts (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)            REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (shift_id, organization_id)             REFERENCES public.shifts (id, organization_id),
    FOREIGN KEY (reverses_movement_id, organization_id) REFERENCES public.cash_movements (id, organization_id)
);
CREATE UNIQUE INDEX cash_movements_reversed_once_idx ON public.cash_movements (reverses_movement_id) WHERE reverses_movement_id IS NOT NULL;
CREATE INDEX cash_movements_account_idx ON public.cash_movements (organization_id, cash_account_id, created_at DESC);
CREATE INDEX cash_movements_shift_idx   ON public.cash_movements (organization_id, shift_id) WHERE shift_id IS NOT NULL;
CREATE INDEX cash_movements_source_idx  ON public.cash_movements (organization_id, source_type, source_id);
CREATE INDEX cash_movements_date_idx    ON public.cash_movements (organization_id, branch_id, business_date);

-- K04. A closed day can't take new ledger rows (trigger, section 17).
CREATE TABLE public.day_closes (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    branch_id        uuid NOT NULL,
    business_date    date NOT NULL,
    status           public.day_close_status NOT NULL DEFAULT 'closed',
    totals           jsonb NOT NULL DEFAULT '{}'::jsonb,    -- snapshot: sales, returns, collections, expenses, cash by account
    issues           jsonb NOT NULL DEFAULT '[]'::jsonb,    -- open shifts, unsent ETA docs, differences
    closed_by        uuid NOT NULL,
    closed_at        timestamptz NOT NULL DEFAULT now(),
    reopened_by      uuid,
    reopened_at      timestamptz,
    reopen_reason    text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    CONSTRAINT day_closes_id_org_key UNIQUE (id, organization_id),
    CONSTRAINT day_closes_day_key    UNIQUE (organization_id, branch_id, business_date),
    FOREIGN KEY (branch_id, organization_id) REFERENCES public.branches (id, organization_id),
    CHECK ((status = 'reopened') = (reopened_at IS NOT NULL AND reopen_reason IS NOT NULL))
);

-- T02-T04. One submission per document, never submitted twice.
CREATE TABLE public.fiscal_submissions (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    branch_id        uuid NOT NULL,
    device_id        uuid,
    doc_type         public.fiscal_doc_type NOT NULL,
    sale_id          uuid,
    return_id        uuid,
    environment      public.eta_environment NOT NULL,
    internal_id      text NOT NULL,                     -- our document number sent to ETA
    eta_uuid         text,
    eta_long_id      text,
    status           public.fiscal_status NOT NULL DEFAULT 'pending',
    attempts         integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_retry_at    timestamptz,
    last_error       text,
    payload          jsonb,
    qr_payload       text,
    submitted_at     timestamptz,
    accepted_at      timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT fiscal_submissions_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (branch_id, organization_id) REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (device_id, organization_id) REFERENCES public.devices (id, organization_id),
    FOREIGN KEY (sale_id, organization_id)   REFERENCES public.sales (id, organization_id),
    FOREIGN KEY (return_id, organization_id) REFERENCES public.sales_returns (id, organization_id),
    CHECK (num_nonnulls(sale_id, return_id) = 1),
    CHECK ((doc_type IN ('b2c_receipt', 'b2b_invoice')) = (sale_id IS NOT NULL)),
    CHECK ((status = 'accepted') = (accepted_at IS NOT NULL AND eta_uuid IS NOT NULL))
);
CREATE UNIQUE INDEX fiscal_submissions_sale_idx   ON public.fiscal_submissions (sale_id)   WHERE sale_id IS NOT NULL;
CREATE UNIQUE INDEX fiscal_submissions_return_idx ON public.fiscal_submissions (return_id) WHERE return_id IS NOT NULL;
CREATE UNIQUE INDEX fiscal_submissions_eta_uuid_idx ON public.fiscal_submissions (eta_uuid) WHERE eta_uuid IS NOT NULL;
CREATE INDEX fiscal_submissions_queue_idx ON public.fiscal_submissions (status, next_retry_at) WHERE status IN ('pending', 'failed');
CREATE INDEX fiscal_submissions_monitor_idx ON public.fiscal_submissions (organization_id, status, created_at DESC);


-- =============================================================================
-- 15. DEFERRED AND GENERIC FOREIGN KEYS
-- =============================================================================

ALTER TABLE public.organizations
    ADD CONSTRAINT organizations_logo_file_fk
    FOREIGN KEY (logo_file_id, id) REFERENCES public.files (id, organization_id);

ALTER TABLE public.org_settings
    ADD CONSTRAINT org_settings_default_tax_fk
    FOREIGN KEY (default_tax_class_id, organization_id) REFERENCES public.tax_classes (id, organization_id);

ALTER TABLE public.stock_reservations
    ADD CONSTRAINT stock_reservations_order_line_fk
    FOREIGN KEY (order_line_id, organization_id) REFERENCES public.sales_order_lines (id, organization_id);

-- Every tenant table -> organizations, and every "who" column (*_by) -> employees
-- of the SAME organization. One loop, so a new table can't forget them.
DO $$
DECLARE r record;
BEGIN
    -- organization_id -> organizations(id)
    FOR r IN
        SELECT c.table_name
        FROM information_schema.columns c
        JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
        WHERE c.table_schema = 'public' AND c.column_name = 'organization_id' AND t.table_type = 'BASE TABLE'
          AND NOT EXISTS (
              SELECT 1 FROM pg_constraint k
              WHERE k.conrelid = format('public.%I', c.table_name)::regclass AND k.contype = 'f'
                AND k.confrelid = 'public.organizations'::regclass)
    LOOP
        EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (organization_id)
                        REFERENCES public.organizations (id) ON DELETE RESTRICT',
                       r.table_name, r.table_name || '_org_fk');
    END LOOP;

    -- created_by, updated_by, approved_by, decided_by, sent_by, received_by,
    -- posted_by, closed_by, reopened_by, requested_by, invited_by -> employees
    FOR r IN
        SELECT c.table_name, c.column_name
        FROM information_schema.columns c
        JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
        WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE'
          AND c.column_name LIKE '%\_by' AND c.data_type = 'uuid'
          AND EXISTS (SELECT 1 FROM information_schema.columns o
                      WHERE o.table_schema = 'public' AND o.table_name = c.table_name
                        AND o.column_name = 'organization_id')
    LOOP
        EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (%I, organization_id)
                        REFERENCES public.employees (id, organization_id)',
                       r.table_name, left(r.table_name || '_' || r.column_name || '_fk', 63), r.column_name);
    END LOOP;
END $$;


-- =============================================================================
-- 16. ACCESS HELPERS (schema app). Write functions call these.
-- =============================================================================
-- SECURITY DEFINER so they can read employees/permissions past RLS.

-- One login can work for several shops (an owner with two companies, an
-- accountant serving two shops): employees is UNIQUE (auth_user_id, organization_id).
-- The active shop comes from the `x-org-id` request header (set by the API from
-- the session) or the `app.org_id` setting. It only SELECTS among the caller's
-- own employee rows, so a forged value can't reach another shop. With a single
-- membership, no header is needed.
CREATE FUNCTION app.requested_org_id()
RETURNS uuid LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
BEGIN
    RETURN COALESCE(
        NULLIF(current_setting('app.org_id', true), ''),
        NULLIF(current_setting('request.headers', true), '')::jsonb ->> 'x-org-id')::uuid;
EXCEPTION WHEN others THEN
    RETURN NULL;                         -- malformed value = no selection
END;
$$;

-- The caller's employee row in the active shop (NULL if none or ambiguous).
CREATE FUNCTION app.current_employee_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT CASE WHEN count(*) = 1 THEN (array_agg(e.id))[1] END
    FROM public.employees e
    WHERE e.auth_user_id = auth.uid() AND e.is_active AND e.archived_at IS NULL
      AND (app.requested_org_id() IS NULL OR e.organization_id = app.requested_org_id())
$$;

CREATE FUNCTION app.current_org_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT e.organization_id FROM public.employees e WHERE e.id = app.current_employee_id()
$$;

CREATE FUNCTION app.current_role()
RETURNS public.employee_role LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT e.role FROM public.employees e WHERE e.id = app.current_employee_id()
$$;

CREATE FUNCTION app.is_super_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT EXISTS (SELECT 1 FROM public.super_admins s
                   WHERE s.auth_user_id = auth.uid() AND s.is_active)
$$;

-- Role default + per-employee override. OWNER has everything.
CREATE FUNCTION app.has_permission(p_key text)
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
        FROM public.employees e WHERE e.id = app.current_employee_id()), false)
$$;

-- Raises unless the caller is an active employee of an active shop with the
-- permission. Returns the employee id. Every write function starts with this.
CREATE FUNCTION app.require_permission(p_key text)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp    uuid := app.current_employee_id();
    v_status public.org_status;
BEGIN
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    SELECT o.status INTO v_status
    FROM public.organizations o JOIN public.employees e ON e.organization_id = o.id
    WHERE e.id = v_emp;
    IF v_status <> 'active' THEN
        RAISE EXCEPTION 'ORG_NOT_ACTIVE: %', v_status USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.permissions p WHERE p.key = p_key) THEN
        RAISE EXCEPTION 'UNKNOWN_PERMISSION: %', p_key USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission(p_key) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: %', p_key USING ERRCODE = '42501';
    END IF;
    RETURN v_emp;
END;
$$;

-- Branch scope (F06): OWNER sees all branches; others need an employee_branches row.
CREATE FUNCTION app.has_branch_access(p_branch_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.employees e
        JOIN public.branches b ON b.id = p_branch_id AND b.organization_id = e.organization_id
        WHERE e.id = app.current_employee_id()
          AND (e.role = 'OWNER'
               OR EXISTS (SELECT 1 FROM public.employee_branches eb
                          WHERE eb.employee_id = e.id AND eb.branch_id = p_branch_id)))
$$;

CREATE FUNCTION app.require_branch_access(p_branch_id uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF NOT app.has_branch_access(p_branch_id) THEN
        RAISE EXCEPTION 'BRANCH_DENIED: %', p_branch_id USING ERRCODE = '42501';
    END IF;
END;
$$;

-- Today in the shop's timezone (business dates, due dates, day close).
CREATE FUNCTION app.org_today(p_organization_id uuid)
RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT (now() AT TIME ZONE o.timezone)::date FROM public.organizations o WHERE o.id = p_organization_id
$$;

-- K04. One lock key per shop + branch + business day. Ledger inserts take it
-- SHARED (many at once); close_day takes it EXCLUSIVE with app.lock_day_for_close()
-- before reading totals, so nothing can slip into a day while it is being closed.
CREATE FUNCTION app.day_lock_key(p_organization_id uuid, p_branch_id uuid, p_day date)
RETURNS bigint LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT hashtextextended(p_organization_id::text || '/' || p_branch_id::text || '/' || p_day::text, 0)
$$;

CREATE FUNCTION app.lock_day_for_close(p_organization_id uuid, p_branch_id uuid, p_day date)
RETURNS void LANGUAGE sql SET search_path = ''
AS $$
    SELECT pg_advisory_xact_lock(app.day_lock_key(p_organization_id, p_branch_id, p_day))
$$;

-- F11. Call inside the same transaction as the document insert. The counter
-- row stays locked until commit, so numbers are unique, ordered and gap-free
-- (a rollback rolls the counter back too). Format: BR1-SL-26-000123.
CREATE FUNCTION app.next_document_number(p_organization_id uuid, p_branch_id uuid, p_doc_type public.doc_type)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_year   integer := extract(year FROM app.org_today(p_organization_id))::integer;
    v_value  bigint;
    v_code   text;
    v_prefix text := CASE p_doc_type
        WHEN 'sale' THEN 'SL'             WHEN 'sales_return' THEN 'RT'
        WHEN 'quotation' THEN 'QT'        WHEN 'sales_order' THEN 'SO'
        WHEN 'delivery' THEN 'DL'         WHEN 'contract' THEN 'CT'
        WHEN 'payment' THEN 'PY'          WHEN 'purchase_order' THEN 'PO'
        WHEN 'purchase_invoice' THEN 'PI' WHEN 'purchase_return' THEN 'PR'
        WHEN 'supplier_payment' THEN 'SP' WHEN 'transfer' THEN 'TR'
        WHEN 'stock_count' THEN 'SC'      WHEN 'stock_adjustment' THEN 'SA'
        WHEN 'cash_transfer' THEN 'CX'    WHEN 'expense' THEN 'EX'
        WHEN 'warranty_claim' THEN 'WC'   WHEN 'legal_case' THEN 'LC'
        WHEN 'shift' THEN 'SH'            ELSE upper(left(p_doc_type::text, 2)) END;
BEGIN
    SELECT b.code INTO v_code FROM public.branches b
    WHERE b.id = p_branch_id AND b.organization_id = p_organization_id;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'BRANCH_NOT_IN_ORG' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO public.document_counters (organization_id, branch_id, doc_type, period_year, next_value)
    VALUES (p_organization_id, p_branch_id, p_doc_type, v_year, 2)
    ON CONFLICT (organization_id, branch_id, doc_type, period_year)
    DO UPDATE SET next_value = public.document_counters.next_value + 1
    RETURNING next_value - 1 INTO v_value;

    RETURN format('%s-%s-%s-%s', v_code, v_prefix, right(v_year::text, 2), lpad(v_value::text, 6, '0'));
END;
$$;

-- F07. One call per write function. Org and employee come from the session
-- (p_organization_id only for service-role/platform calls). IP, user agent,
-- request id and device id are read from the PostgREST request headers if
-- present. PII keys are stripped from before/after, so the audit log never
-- becomes a side door to national IDs.
CREATE FUNCTION app.write_audit(
    p_action          text,
    p_entity_type     text,
    p_entity_id       uuid,
    p_before          jsonb DEFAULT NULL,
    p_after           jsonb DEFAULT NULL,
    p_reason          text DEFAULT NULL,
    p_branch_id       uuid DEFAULT NULL,
    p_severity        public.audit_severity DEFAULT 'info',
    p_organization_id uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org     uuid := COALESCE(app.current_org_id(), p_organization_id);
    v_pii     text[] := ARRAY['national_id', 'token_hash', 'client_secret_vault_id', 'password'];
    v_headers jsonb;
    v_ip      inet;
    v_device  uuid;
BEGIN
    IF v_org IS NULL THEN
        RAISE EXCEPTION 'AUDIT_NO_ORG' USING ERRCODE = 'P0001';
    END IF;
    BEGIN
        v_headers := NULLIF(current_setting('request.headers', true), '')::jsonb;
        v_ip := NULLIF(btrim(split_part(v_headers ->> 'x-forwarded-for', ',', 1)), '')::inet;
        v_device := NULLIF(v_headers ->> 'x-device-id', '')::uuid;
    EXCEPTION WHEN others THEN
        v_ip := NULL; v_device := NULL;          -- a bad header never blocks the write
    END;
    IF v_device IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.devices d WHERE d.id = v_device AND d.organization_id = v_org) THEN
        v_device := NULL;
    END IF;

    INSERT INTO public.audit_log (organization_id, branch_id, employee_id, super_admin_id, device_id,
                                  ip, user_agent, request_id, action, entity_type, entity_id,
                                  severity, reason, before, after)
    VALUES (v_org, p_branch_id, app.current_employee_id(),
            CASE WHEN app.is_super_admin() THEN auth.uid() END, v_device,
            v_ip, v_headers ->> 'user-agent', v_headers ->> 'x-request-id',
            p_action, p_entity_type, p_entity_id, p_severity, p_reason,
            p_before - v_pii, p_after - v_pii);
END;
$$;

-- F13. Claim up to p_limit due jobs; concurrent workers never get the same job.
-- Jobs stuck in 'running' longer than p_stale (crashed worker) are retried;
-- jobs out of attempts become 'dead' and stop being claimed.
CREATE FUNCTION app.claim_jobs(p_worker text, p_limit integer DEFAULT 10,
                               p_stale interval DEFAULT interval '15 minutes')
RETURNS SETOF public.jobs LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    UPDATE public.jobs
       SET status = 'dead', finished_at = now(),
           last_error = COALESCE(last_error, 'max attempts reached')
     WHERE status IN ('queued', 'running', 'failed') AND attempts >= max_attempts
       AND (status <> 'running' OR locked_at < now() - p_stale);

    RETURN QUERY
    UPDATE public.jobs j
       SET status = 'running', locked_at = now(), locked_by = p_worker, attempts = j.attempts + 1
     WHERE j.id IN (SELECT id FROM public.jobs
                    WHERE attempts < max_attempts AND run_at <= now()
                      AND (status IN ('queued', 'failed')
                           OR (status = 'running' AND locked_at < now() - p_stale))
                    ORDER BY run_at
                    LIMIT p_limit
                    FOR UPDATE SKIP LOCKED)
    RETURNING j.*;
END;
$$;


-- =============================================================================
-- 17. LEDGER TRIGGERS: business date, closed days, stock / cash / credit balances
-- =============================================================================
-- Rules for the write functions that post to these ledgers (slice authors):
--   * Release or fulfil a reservation BEFORE posting the stock movement it covers.
--   * Post multi-line documents in product_id order (and cash in account order),
--     so two concurrent documents lock rows in the same order and can't deadlock.
--   * Never write stock_levels, cash_balances, store_credit_balances or unit
--     status directly: the triggers below own them.
-- No EXCEPTION blocks here: a conditional UPDATE + RAISE avoids one
-- subtransaction per ledger row on big documents.

-- BEFORE INSERT on dated ledgers and documents: fill business_date in the shop's
-- timezone, refuse future dates and dates in a closed day (K04). Takes the day
-- lock SHARED so close_day (EXCLUSIVE) can't race with it.
CREATE FUNCTION app.check_business_date()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_today  date := app.org_today(NEW.organization_id);
    v_branch uuid;
BEGIN
    IF NEW.business_date IS NULL THEN
        NEW.business_date := v_today;
    END IF;
    IF NEW.business_date > v_today THEN
        RAISE EXCEPTION 'FUTURE_BUSINESS_DATE: %', NEW.business_date USING ERRCODE = 'P0001';
    END IF;
    v_branch := (to_jsonb(NEW) ->> 'branch_id')::uuid;
    IF v_branch IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock_shared(app.day_lock_key(NEW.organization_id, v_branch, NEW.business_date));
        IF EXISTS (
            SELECT 1 FROM public.day_closes dc
            WHERE dc.organization_id = NEW.organization_id AND dc.branch_id = v_branch
              AND dc.business_date = NEW.business_date AND dc.status = 'closed') THEN
            RAISE EXCEPTION 'DAY_CLOSED: % is closed for this branch', NEW.business_date USING ERRCODE = 'P0001';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- BEFORE INSERT on stock_movements: serialized products move one unit at a
-- time, and the unit must be where the movement says it is. The unit row is
-- locked, so the same IMEI can't be sold twice by two tills at once.
CREATE FUNCTION app.check_stock_movement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_serialized boolean;
    v_unit       public.units%ROWTYPE;
BEGIN
    SELECT p.is_serialized INTO v_serialized FROM public.products p
    WHERE p.id = NEW.product_id AND p.organization_id = NEW.organization_id;
    IF v_serialized AND NEW.unit_id IS NULL THEN
        RAISE EXCEPTION 'UNIT_REQUIRED: product % is serialized', NEW.product_id USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_serialized AND NEW.unit_id IS NOT NULL THEN
        RAISE EXCEPTION 'UNIT_NOT_ALLOWED: product % is not serialized', NEW.product_id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.unit_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_unit FROM public.units u
    WHERE u.id = NEW.unit_id AND u.organization_id = NEW.organization_id FOR UPDATE;
    IF v_unit.product_id IS DISTINCT FROM NEW.product_id THEN
        RAISE EXCEPTION 'UNIT_PRODUCT_MISMATCH' USING ERRCODE = 'P0001';
    END IF;

    IF NEW.quantity < 0 THEN
        -- Out: the unit must be here and available (a reservation is released first).
        IF v_unit.branch_id <> NEW.branch_id OR v_unit.status NOT IN ('in_stock', 'reserved') THEN
            RAISE EXCEPTION 'UNIT_NOT_AVAILABLE: % is % at another or same branch', v_unit.serial, v_unit.status
                USING ERRCODE = 'P0001';
        END IF;
    ELSE
        -- In: the unit must not already be in stock somewhere (first movement excepted).
        IF v_unit.status IN ('in_stock', 'reserved')
           AND EXISTS (SELECT 1 FROM public.stock_movements m WHERE m.unit_id = NEW.unit_id) THEN
            RAISE EXCEPTION 'UNIT_ALREADY_IN_STOCK: %', v_unit.serial USING ERRCODE = 'P0001';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- AFTER INSERT on stock_movements: keep stock_levels and the unit's place/status.
-- The UPDATE locks the level row, so concurrent sales of one product queue up.
CREATE FUNCTION app.apply_stock_movement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    INSERT INTO public.stock_levels (organization_id, product_id, branch_id, stock_state)
    VALUES (NEW.organization_id, NEW.product_id, NEW.branch_id, NEW.stock_state)
    ON CONFLICT (organization_id, product_id, branch_id, stock_state) DO NOTHING;

    UPDATE public.stock_levels sl
       SET on_hand = sl.on_hand + NEW.quantity, updated_at = now()
     WHERE sl.organization_id = NEW.organization_id AND sl.product_id = NEW.product_id
       AND sl.branch_id = NEW.branch_id AND sl.stock_state = NEW.stock_state
       AND sl.on_hand + NEW.quantity >= sl.reserved;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUT_OF_STOCK: product % at branch % (% stock; reserved stock counts as taken)',
            NEW.product_id, NEW.branch_id, NEW.stock_state USING ERRCODE = '23514';
    END IF;

    IF NEW.unit_id IS NOT NULL THEN
        UPDATE public.units u
           SET branch_id = NEW.branch_id,
               status = CASE
                   WHEN NEW.quantity > 0 THEN 'in_stock'
                   WHEN NEW.type IN ('sale_out', 'delivery_out') THEN 'sold'
                   WHEN NEW.type = 'transfer_out' THEN 'in_transit'
                   WHEN NEW.type = 'purchase_return_out' THEN 'returned'
                   WHEN NEW.type = 'claim_out' THEN 'in_repair'
                   ELSE 'written_off'
               END::public.unit_status,
               updated_at = now()
         WHERE u.id = NEW.unit_id;
    END IF;
    RETURN NULL;
END;
$$;

-- AFTER INSERT/UPDATE on stock_reservations: keep stock_levels.reserved (sellable
-- stock only) and the reserved unit's status.
CREATE FUNCTION app.apply_stock_reservation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.status = 'active' THEN
        INSERT INTO public.stock_levels (organization_id, product_id, branch_id)
        VALUES (NEW.organization_id, NEW.product_id, NEW.branch_id)
        ON CONFLICT (organization_id, product_id, branch_id, stock_state) DO NOTHING;
        UPDATE public.stock_levels sl
           SET reserved = sl.reserved + NEW.quantity, updated_at = now()
         WHERE sl.organization_id = NEW.organization_id AND sl.product_id = NEW.product_id
           AND sl.branch_id = NEW.branch_id AND sl.stock_state = 'sellable'
           AND sl.reserved + NEW.quantity <= sl.on_hand;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'NOT_ENOUGH_STOCK_TO_RESERVE: product % at branch %',
                NEW.product_id, NEW.branch_id USING ERRCODE = '23514';
        END IF;
        IF NEW.unit_id IS NOT NULL THEN
            UPDATE public.units u SET status = 'reserved', updated_at = now()
             WHERE u.id = NEW.unit_id AND u.status = 'in_stock' AND u.branch_id = NEW.branch_id;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'UNIT_NOT_AVAILABLE_TO_RESERVE' USING ERRCODE = 'P0001';
            END IF;
        END IF;
    ELSIF TG_OP = 'UPDATE' AND OLD.status = 'active' AND NEW.status <> 'active' THEN
        UPDATE public.stock_levels sl
           SET reserved = sl.reserved - OLD.quantity, updated_at = now()
         WHERE sl.organization_id = OLD.organization_id AND sl.product_id = OLD.product_id
           AND sl.branch_id = OLD.branch_id AND sl.stock_state = 'sellable';
        IF OLD.unit_id IS NOT NULL THEN
            UPDATE public.units u SET status = 'in_stock', updated_at = now()
             WHERE u.id = OLD.unit_id AND u.status = 'reserved';
        END IF;
    ELSIF TG_OP = 'UPDATE' AND OLD.status <> 'active' AND NEW.status = 'active' THEN
        RAISE EXCEPTION 'RESERVATION_CLOSED: make a new reservation instead' USING ERRCODE = 'P0001';
    END IF;
    RETURN NULL;
END;
$$;

-- BEFORE INSERT on cash_movements: the branch is the account's branch. For
-- org-wide bank accounts the write function passes the branch that paid, so
-- closed-day checks still apply.
CREATE FUNCTION app.prepare_cash_movement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_branch uuid;
    v_active boolean;
BEGIN
    SELECT a.branch_id, a.is_active INTO v_branch, v_active
    FROM public.cash_accounts a
    WHERE a.id = NEW.cash_account_id AND a.organization_id = NEW.organization_id;
    IF NOT v_active THEN
        RAISE EXCEPTION 'CASH_ACCOUNT_INACTIVE' USING ERRCODE = 'P0001';
    END IF;
    NEW.branch_id := COALESCE(v_branch, NEW.branch_id);
    IF NEW.branch_id IS NULL THEN
        RAISE EXCEPTION 'BRANCH_REQUIRED: pass the paying branch for an org-wide bank account' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;

-- AFTER INSERT on cash_movements: keep cash_balances. Money out can't take a
-- safe, drawer or wallet below zero; banks only if org_settings.allow_negative_bank.
-- Money in is always accepted (it can only improve a balance).
CREATE FUNCTION app.apply_cash_movement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_kind  public.cash_account_kind;
    v_allow boolean;
BEGIN
    SELECT a.kind, (a.kind = 'bank' AND COALESCE(s.allow_negative_bank, false)) INTO v_kind, v_allow
    FROM public.cash_accounts a
    LEFT JOIN public.org_settings s ON s.organization_id = a.organization_id
    WHERE a.id = NEW.cash_account_id;

    INSERT INTO public.cash_balances (organization_id, cash_account_id, allow_negative)
    VALUES (NEW.organization_id, NEW.cash_account_id, v_kind = 'bank')
    ON CONFLICT (cash_account_id) DO NOTHING;

    UPDATE public.cash_balances cb
       SET balance = cb.balance + NEW.amount, updated_at = now()
     WHERE cb.cash_account_id = NEW.cash_account_id
       AND (NEW.amount > 0 OR v_allow OR cb.balance + NEW.amount >= 0);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INSUFFICIENT_FUNDS: cash account %', NEW.cash_account_id USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION app.apply_store_credit_movement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    INSERT INTO public.store_credit_balances (organization_id, customer_id)
    VALUES (NEW.organization_id, NEW.customer_id)
    ON CONFLICT (customer_id) DO NOTHING;
    UPDATE public.store_credit_balances scb
       SET balance = scb.balance + NEW.amount, updated_at = now()
     WHERE scb.customer_id = NEW.customer_id AND scb.balance + NEW.amount >= 0;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INSUFFICIENT_STORE_CREDIT: customer %', NEW.customer_id USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;

-- Status documents: once OLD.status is one of TG_ARGV, the row is frozen.
CREATE FUNCTION app.freeze_when_status()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    IF (to_jsonb(OLD) ->> 'status') = ANY (TG_ARGV) THEN
        RAISE EXCEPTION 'DOCUMENT_FINAL: %.% is % and can no longer change',
            TG_TABLE_SCHEMA, TG_TABLE_NAME, to_jsonb(OLD) ->> 'status' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;

-- Child lines: no insert/update/delete once the parent's status is final.
-- TG_ARGV[0] = parent table, TG_ARGV[1] = FK column, TG_ARGV[2..] = final statuses.
CREATE FUNCTION app.freeze_lines_when_parent_status()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_row    jsonb := to_jsonb(COALESCE(NEW, OLD));
    v_status text;
BEGIN
    EXECUTE format('SELECT status::text FROM public.%I WHERE id = $1 FOR SHARE', TG_ARGV[0])
        INTO v_status USING (v_row ->> TG_ARGV[1])::uuid;
    IF v_status = ANY (TG_ARGV[2:]) THEN
        RAISE EXCEPTION 'DOCUMENT_FINAL: % is % and its lines can no longer change',
            TG_ARGV[0], v_status USING ERRCODE = 'P0001';
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;


-- =============================================================================
-- 18. ATTACH TRIGGERS
-- =============================================================================

DO $$
DECLARE t text;
BEGIN
    -- updated_at on every table that has it
    FOR t IN
        SELECT c.table_name FROM information_schema.columns c
        JOIN information_schema.tables tb ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name
        WHERE c.table_schema = 'public' AND c.column_name = 'updated_at' AND tb.table_type = 'BASE TABLE'
          AND c.table_name NOT IN ('stock_levels', 'cash_balances', 'store_credit_balances')
    LOOP
        EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON public.%I
                        FOR EACH ROW EXECUTE FUNCTION app.set_updated_at()', t, t);
    END LOOP;

    -- Append-only: ledgers, payments, issued documents, audit, immutable versions
    FOREACH t IN ARRAY ARRAY[
        'stock_movements', 'cash_movements', 'store_credit_movements', 'audit_log',
        'payments', 'payment_allocations', 'supplier_payments', 'supplier_payment_allocations',
        'sales', 'sale_lines', 'sales_returns', 'sales_return_lines',
        'cash_transfers', 'expenses', 'charges', 'charge_waivers', 'contract_changes',
        'contract_guarantors', 'stock_adjustments', 'stock_adjustment_lines',
        'purchase_returns', 'purchase_return_lines', 'delivery_lines',
        'legal_case_notes', 'subscription_payments', 'installment_policies'
    ] LOOP
        EXECUTE format('CREATE TRIGGER trg_%s_append_only BEFORE UPDATE OR DELETE ON public.%I
                        FOR EACH ROW EXECUTE FUNCTION app.forbid_update_delete()', t, t);
    END LOOP;

    -- No hard deletes anywhere else, except editable draft lines and link rows
    FOR t IN
        SELECT tablename FROM pg_tables WHERE schemaname = 'public'
          AND tablename NOT IN (
              'stock_movements', 'cash_movements', 'store_credit_movements', 'audit_log',
              'payments', 'payment_allocations', 'supplier_payments', 'supplier_payment_allocations',
              'sales', 'sale_lines', 'sales_returns', 'sales_return_lines',
              'cash_transfers', 'expenses', 'charges', 'charge_waivers', 'contract_changes',
              'contract_guarantors', 'stock_adjustments', 'stock_adjustment_lines',
              'purchase_returns', 'purchase_return_lines', 'delivery_lines',
              'legal_case_notes', 'subscription_payments', 'installment_policies',
              -- deletable:
              'employee_branches', 'employee_permission_overrides', 'customer_guarantors',
              'quotation_lines', 'purchase_order_lines', 'purchase_invoice_lines',
              'stock_transfer_lines', 'stock_count_lines', 'sales_order_lines',
              'organization_features', 'jobs', 'login_attempts')
    LOOP
        EXECUTE format('CREATE TRIGGER trg_%s_no_delete BEFORE DELETE ON public.%I
                        FOR EACH ROW EXECUTE FUNCTION app.forbid_delete()', t, t);
    END LOOP;

    -- business_date + closed-day check
    FOREACH t IN ARRAY ARRAY[
        'stock_movements', 'payments', 'sales', 'sales_returns', 'expenses',
        'supplier_payments', 'purchase_returns', 'cash_transfers', 'store_credit_movements'
    ] LOOP
        EXECUTE format('CREATE TRIGGER trg_%s_business_date BEFORE INSERT ON public.%I
                        FOR EACH ROW EXECUTE FUNCTION app.check_business_date()', t, t);
    END LOOP;
END $$;

-- cash_movements: copy branch first (trigger names fire in alphabetical order)
CREATE TRIGGER trg_cash_movements_a_prepare BEFORE INSERT ON public.cash_movements
    FOR EACH ROW EXECUTE FUNCTION app.prepare_cash_movement();
CREATE TRIGGER trg_cash_movements_b_business_date BEFORE INSERT ON public.cash_movements
    FOR EACH ROW EXECUTE FUNCTION app.check_business_date();
CREATE TRIGGER trg_cash_movements_balance AFTER INSERT ON public.cash_movements
    FOR EACH ROW EXECUTE FUNCTION app.apply_cash_movement();

CREATE TRIGGER trg_stock_movements_check BEFORE INSERT ON public.stock_movements
    FOR EACH ROW EXECUTE FUNCTION app.check_stock_movement();
CREATE TRIGGER trg_stock_movements_levels AFTER INSERT ON public.stock_movements
    FOR EACH ROW EXECUTE FUNCTION app.apply_stock_movement();

CREATE TRIGGER trg_stock_reservations_levels AFTER INSERT OR UPDATE ON public.stock_reservations
    FOR EACH ROW EXECUTE FUNCTION app.apply_stock_reservation();

CREATE TRIGGER trg_store_credit_movements_balance AFTER INSERT ON public.store_credit_movements
    FOR EACH ROW EXECUTE FUNCTION app.apply_store_credit_movement();

-- Frozen rows: only these columns may change
CREATE TRIGGER trg_contracts_frozen BEFORE UPDATE ON public.contracts
    FOR EACH ROW EXECUTE FUNCTION app.only_columns_change('status', 'current_version', 'closed_at', 'updated_at', 'updated_by');
CREATE TRIGGER trg_schedule_lines_frozen BEFORE UPDATE ON public.schedule_lines
    FOR EACH ROW EXECUTE FUNCTION app.only_columns_change('superseded', 'amount');   -- amount is generated (NULL in NEW)
CREATE TRIGGER trg_units_frozen BEFORE UPDATE ON public.units
    FOR EACH ROW EXECUTE FUNCTION app.only_columns_change('branch_id', 'status', 'updated_at', 'updated_by');
CREATE TRIGGER trg_stock_reservations_frozen BEFORE UPDATE ON public.stock_reservations
    FOR EACH ROW EXECUTE FUNCTION app.only_columns_change('status', 'released_at', 'updated_at', 'updated_by');
CREATE TRIGGER trg_stock_levels_frozen BEFORE UPDATE ON public.stock_levels
    FOR EACH ROW EXECUTE FUNCTION app.only_columns_change('on_hand', 'reserved', 'updated_at');
CREATE TRIGGER trg_cash_balances_frozen BEFORE UPDATE ON public.cash_balances
    FOR EACH ROW EXECUTE FUNCTION app.only_columns_change('balance', 'allow_negative', 'updated_at');
CREATE TRIGGER trg_store_credit_balances_frozen BEFORE UPDATE ON public.store_credit_balances
    FOR EACH ROW EXECUTE FUNCTION app.only_columns_change('balance', 'updated_at');
-- An employee can't move to another org; a branch code is printed on documents.
CREATE TRIGGER trg_employees_org_fixed BEFORE UPDATE ON public.employees
    FOR EACH ROW WHEN (OLD.organization_id IS DISTINCT FROM NEW.organization_id)
    EXECUTE FUNCTION app.forbid_update_delete();
CREATE TRIGGER trg_branches_code_fixed BEFORE UPDATE ON public.branches
    FOR EACH ROW WHEN (OLD.code IS DISTINCT FROM NEW.code OR OLD.organization_id IS DISTINCT FROM NEW.organization_id)
    EXECUTE FUNCTION app.forbid_update_delete();

-- Final statuses freeze the document
CREATE TRIGGER trg_purchase_invoices_final BEFORE UPDATE ON public.purchase_invoices
    FOR EACH ROW EXECUTE FUNCTION app.freeze_when_status('approved', 'rejected');
CREATE TRIGGER trg_purchase_orders_final BEFORE UPDATE ON public.purchase_orders
    FOR EACH ROW EXECUTE FUNCTION app.freeze_when_status('received', 'cancelled');
CREATE TRIGGER trg_shifts_final BEFORE UPDATE ON public.shifts
    FOR EACH ROW EXECUTE FUNCTION app.freeze_when_status('closed');
CREATE TRIGGER trg_stock_transfers_final BEFORE UPDATE ON public.stock_transfers
    FOR EACH ROW EXECUTE FUNCTION app.freeze_when_status('received', 'partially_received', 'cancelled');
CREATE TRIGGER trg_stock_counts_final BEFORE UPDATE ON public.stock_counts
    FOR EACH ROW EXECUTE FUNCTION app.freeze_when_status('posted', 'cancelled');
CREATE TRIGGER trg_quotations_final BEFORE UPDATE ON public.quotations
    FOR EACH ROW EXECUTE FUNCTION app.freeze_when_status('accepted', 'expired', 'cancelled');
CREATE TRIGGER trg_sales_orders_final BEFORE UPDATE ON public.sales_orders
    FOR EACH ROW EXECUTE FUNCTION app.freeze_when_status('delivered', 'cancelled');
CREATE TRIGGER trg_deliveries_final BEFORE UPDATE ON public.deliveries
    FOR EACH ROW EXECUTE FUNCTION app.freeze_when_status('delivered', 'cancelled');
CREATE TRIGGER trg_approvals_final BEFORE UPDATE ON public.approvals
    FOR EACH ROW EXECUTE FUNCTION app.freeze_when_status('approved', 'rejected', 'cancelled');
CREATE TRIGGER trg_field_surveys_final BEFORE UPDATE ON public.field_surveys
    FOR EACH ROW EXECUTE FUNCTION app.freeze_when_status('approved', 'rejected', 'cancelled');
CREATE TRIGGER trg_warranty_claims_final BEFORE UPDATE ON public.warranty_claims
    FOR EACH ROW EXECUTE FUNCTION app.freeze_when_status('closed', 'rejected');
CREATE TRIGGER trg_fiscal_submissions_final BEFORE UPDATE ON public.fiscal_submissions
    FOR EACH ROW EXECUTE FUNCTION app.freeze_when_status('accepted', 'cancelled');
CREATE TRIGGER trg_collector_commissions_final BEFORE UPDATE ON public.collector_commissions
    FOR EACH ROW EXECUTE FUNCTION app.freeze_when_status('paid', 'cancelled');
CREATE TRIGGER trg_import_jobs_final BEFORE UPDATE ON public.import_jobs
    FOR EACH ROW EXECUTE FUNCTION app.freeze_when_status('completed', 'cancelled');

-- Lines freeze with their parent
CREATE TRIGGER trg_purchase_invoice_lines_final BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_invoice_lines
    FOR EACH ROW EXECUTE FUNCTION app.freeze_lines_when_parent_status('purchase_invoices', 'invoice_id', 'approved', 'rejected');
CREATE TRIGGER trg_purchase_order_lines_final BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_order_lines
    FOR EACH ROW EXECUTE FUNCTION app.freeze_lines_when_parent_status('purchase_orders', 'po_id', 'partially_received', 'received', 'cancelled');
CREATE TRIGGER trg_quotation_lines_final BEFORE INSERT OR UPDATE OR DELETE ON public.quotation_lines
    FOR EACH ROW EXECUTE FUNCTION app.freeze_lines_when_parent_status('quotations', 'quotation_id', 'accepted', 'expired', 'cancelled');
CREATE TRIGGER trg_sales_order_lines_final BEFORE INSERT OR UPDATE OR DELETE ON public.sales_order_lines
    FOR EACH ROW EXECUTE FUNCTION app.freeze_lines_when_parent_status('sales_orders', 'order_id', 'partially_delivered', 'delivered', 'cancelled');
CREATE TRIGGER trg_stock_transfer_lines_final BEFORE INSERT OR UPDATE OR DELETE ON public.stock_transfer_lines
    FOR EACH ROW EXECUTE FUNCTION app.freeze_lines_when_parent_status('stock_transfers', 'transfer_id', 'received', 'partially_received', 'cancelled');
CREATE TRIGGER trg_stock_count_lines_final BEFORE INSERT OR UPDATE OR DELETE ON public.stock_count_lines
    FOR EACH ROW EXECUTE FUNCTION app.freeze_lines_when_parent_status('stock_counts', 'count_id', 'posted', 'cancelled');


-- =============================================================================
-- 19. VIEWS (security_invoker: the caller's grants and RLS apply)
-- =============================================================================
-- Rule: balances that must never go wrong are TABLES kept by triggers
-- (stock_levels, cash_balances, store_credit_balances). Everything that is
-- derived for screens and reports is a VIEW over the ledgers, never a stored column.
-- A reversed payment (and its reversal) is ignored everywhere.

-- Allocations of payments that were not reversed.
CREATE VIEW public.v_effective_allocations WITH (security_invoker = true) AS
SELECT pa.*, p.direction, p.method, p.customer_id, p.paid_at, p.business_date, p.branch_id
FROM public.payment_allocations pa
JOIN public.payments p ON p.id = pa.payment_id
WHERE p.reverses_payment_id IS NULL
  AND NOT EXISTS (SELECT 1 FROM public.payments r WHERE r.reverses_payment_id = p.id);

-- I01 / I06
-- Sellable stock only; damaged stock is shown next to it.
CREATE VIEW public.v_stock_available WITH (security_invoker = true) AS
SELECT sl.organization_id, sl.branch_id, sl.product_id,
       sl.on_hand, sl.reserved, sl.on_hand - sl.reserved AS available,
       COALESCE(d.on_hand, 0) AS damaged,
       p.min_stock,
       (sl.on_hand - sl.reserved) <= p.min_stock AS is_low_stock
FROM public.stock_levels sl
JOIN public.products p ON p.id = sl.product_id
LEFT JOIN public.stock_levels d
       ON d.product_id = sl.product_id AND d.branch_id = sl.branch_id
      AND d.organization_id = sl.organization_id AND d.stock_state = 'damaged'
WHERE sl.stock_state = 'sellable';

-- I03. Sent but not yet received, per destination branch.
CREATE VIEW public.v_stock_in_transit WITH (security_invoker = true) AS
SELECT t.organization_id, t.to_branch_id AS branch_id, l.product_id,
       SUM(l.qty_sent)::integer AS in_transit
FROM public.stock_transfers t
JOIN public.stock_transfer_lines l ON l.transfer_id = t.id
WHERE t.status = 'sent'
GROUP BY t.organization_id, t.to_branch_id, l.product_id;

-- I04. Full life of a serialized unit.
CREATE VIEW public.v_unit_history WITH (security_invoker = true) AS
SELECT m.organization_id, m.unit_id, u.serial, m.product_id, m.branch_id, m.type,
       m.quantity, m.unit_cost, m.source_type, m.source_id, m.business_date, m.created_at, m.created_by
FROM public.stock_movements m
JOIN public.units u ON u.id = m.unit_id
WHERE m.unit_id IS NOT NULL;

-- K01. Every account with its balance (0 if it never moved).
CREATE VIEW public.v_cash_balances WITH (security_invoker = true) AS
SELECT a.organization_id, a.id AS cash_account_id, a.branch_id, a.name, a.kind, a.employee_id,
       a.is_active, COALESCE(b.balance, 0)::numeric(18,2) AS balance
FROM public.cash_accounts a
LEFT JOIN public.cash_balances b ON b.cash_account_id = a.id;

-- K02. Expected cash = this shift's drawer movements (the opening float is
-- posted as a float_in movement). Cash left from earlier shifts doesn't count.
CREATE VIEW public.v_shift_expected_cash WITH (security_invoker = true) AS
SELECT s.organization_id, s.id AS shift_id, s.branch_id, s.employee_id, s.drawer_account_id,
       s.status, s.opening_float,
       COALESCE(SUM(m.amount) FILTER (WHERE m.amount > 0), 0)::numeric(18,2) AS cash_in,
       COALESCE(-SUM(m.amount) FILTER (WHERE m.amount < 0), 0)::numeric(18,2) AS cash_out,
       CASE WHEN s.status = 'open' THEN COALESCE(SUM(m.amount), 0) ELSE s.expected_cash END::numeric(18,2) AS expected_cash,
       s.counted_cash,
       (s.counted_cash - s.expected_cash)::numeric(18,2) AS difference
FROM public.shifts s
LEFT JOIN public.cash_movements m ON m.shift_id = s.id AND m.cash_account_id = s.drawer_account_id
GROUP BY s.organization_id, s.id, s.branch_id, s.employee_id, s.drawer_account_id, s.status,
         s.opening_float, s.expected_cash, s.counted_cash;

-- U03. Approved invoices: paid and returned-for-credit come from the ledgers.
CREATE VIEW public.v_purchase_invoice_balances WITH (security_invoker = true) AS
SELECT pi.organization_id, pi.id AS purchase_invoice_id, pi.supplier_id, pi.branch_id,
       pi.invoice_date, pi.total,
       COALESCE(pay.paid, 0)::numeric(18,2)     AS paid,
       COALESCE(ret.credited, 0)::numeric(18,2) AS returned_credit,
       (pi.total - COALESCE(pay.paid, 0) - COALESCE(ret.credited, 0))::numeric(18,2) AS outstanding
FROM public.purchase_invoices pi
LEFT JOIN (SELECT a.purchase_invoice_id, SUM(a.amount) AS paid
           FROM public.supplier_payment_allocations a
           JOIN public.supplier_payments sp ON sp.id = a.supplier_payment_id
           WHERE sp.reverses_payment_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM public.supplier_payments r WHERE r.reverses_payment_id = sp.id)
           GROUP BY a.purchase_invoice_id) pay ON pay.purchase_invoice_id = pi.id
LEFT JOIN (SELECT purchase_invoice_id, SUM(total) AS credited
           FROM public.purchase_returns WHERE refund_mode = 'supplier_credit'
           GROUP BY purchase_invoice_id) ret ON ret.purchase_invoice_id = pi.id
WHERE pi.status = 'approved';

-- U01. What we owe each supplier (unallocated payments count too).
CREATE VIEW public.v_supplier_balances WITH (security_invoker = true) AS
SELECT s.organization_id, s.id AS supplier_id, s.name,
       COALESCE(inv.invoiced, 0)::numeric(18,2) AS invoiced,
       COALESCE(ret.credited, 0)::numeric(18,2) AS returned_credit,
       COALESCE(pay.paid, 0)::numeric(18,2)     AS paid,
       (COALESCE(inv.invoiced, 0) - COALESCE(ret.credited, 0) - COALESCE(pay.paid, 0))::numeric(18,2) AS balance
FROM public.suppliers s
LEFT JOIN (SELECT supplier_id, SUM(total) AS invoiced FROM public.purchase_invoices
           WHERE status = 'approved' GROUP BY supplier_id) inv ON inv.supplier_id = s.id
LEFT JOIN (SELECT supplier_id, SUM(total) AS credited FROM public.purchase_returns
           WHERE refund_mode = 'supplier_credit' GROUP BY supplier_id) ret ON ret.supplier_id = s.id
LEFT JOIN (SELECT sp.supplier_id, SUM(sp.amount) AS paid FROM public.supplier_payments sp
           WHERE sp.reverses_payment_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM public.supplier_payments r WHERE r.reverses_payment_id = sp.id)
           GROUP BY sp.supplier_id) pay ON pay.supplier_id = s.id;

-- U05. Received quantity per PO line (approved invoices only).
CREATE VIEW public.v_po_line_received WITH (security_invoker = true) AS
SELECT pol.organization_id, pol.id AS po_line_id, pol.po_id, pol.product_id, pol.quantity,
       COALESCE(SUM(pil.quantity) FILTER (WHERE pi.status = 'approved'), 0)::integer AS received,
       (pol.quantity - COALESCE(SUM(pil.quantity) FILTER (WHERE pi.status = 'approved'), 0))::integer AS remaining
FROM public.purchase_order_lines pol
LEFT JOIN public.purchase_invoice_lines pil ON pil.po_line_id = pol.id
LEFT JOIN public.purchase_invoices pi ON pi.id = pil.invoice_id
GROUP BY pol.organization_id, pol.id, pol.po_id, pol.product_id, pol.quantity;

-- S01 / S02. How a POS sale was settled: payments + financed by a contract.
-- Delivery sales are settled at ORDER level (deposits and an order contract
-- cover all of the order's sales): see v_order_balances; unpaid is NULL here.
CREATE VIEW public.v_sale_balances WITH (security_invoker = true) AS
SELECT s.organization_id, s.id AS sale_id, s.branch_id, s.customer_id, s.kind, s.order_id, s.total,
       COALESCE(pa.paid, 0)::numeric(18,2)         AS paid,
       COALESCE(c.financed_amount, 0)::numeric(18,2) AS financed,
       COALESCE(r.returned, 0)::numeric(18,2)      AS returned,
       CASE WHEN s.kind = 'delivery' THEN NULL
            ELSE (s.total - COALESCE(pa.paid, 0) - COALESCE(c.financed_amount, 0)) END::numeric(18,2) AS unpaid
FROM public.sales s
LEFT JOIN (SELECT sale_id, SUM(amount) AS paid FROM public.v_effective_allocations
           WHERE sale_id IS NOT NULL AND direction = 'in' GROUP BY sale_id) pa ON pa.sale_id = s.id
LEFT JOIN public.contracts c ON c.sale_id = s.id
LEFT JOIN (SELECT sale_id, SUM(total) AS returned FROM public.sales_returns GROUP BY sale_id) r ON r.sale_id = s.id;

-- S10 / S11. An order's money: deposits and an order contract against the order
-- total. Delivered = value of the sales issued by its deliveries.
CREATE VIEW public.v_order_balances WITH (security_invoker = true) AS
SELECT o.organization_id, o.id AS order_id, o.branch_id, o.customer_id, o.status, o.total,
       COALESCE(pa.paid, 0)::numeric(18,2)            AS deposits_paid,
       COALESCE(c.financed_amount, 0)::numeric(18,2)  AS financed,
       COALESCE(ds.delivered_value, 0)::numeric(18,2) AS delivered_value,
       (o.total - COALESCE(pa.paid, 0) - COALESCE(c.financed_amount, 0))::numeric(18,2) AS unpaid
FROM public.sales_orders o
LEFT JOIN (SELECT order_id, SUM(CASE WHEN direction = 'in' THEN amount ELSE -amount END) AS paid
           FROM public.v_effective_allocations WHERE order_id IS NOT NULL GROUP BY order_id) pa ON pa.order_id = o.id
LEFT JOIN public.contracts c ON c.order_id = o.id
LEFT JOIN (SELECT order_id, SUM(total) AS delivered_value FROM public.sales
           WHERE kind = 'delivery' GROUP BY order_id) ds ON ds.order_id = o.id;

-- S10 / S11. Ordered vs delivered vs reserved per order line.
CREATE VIEW public.v_order_line_fulfilment WITH (security_invoker = true) AS
SELECT ol.organization_id, ol.id AS order_line_id, ol.order_id, ol.product_id, ol.quantity, ol.fulfilment,
       COALESCE(d.delivered, 0)::integer AS delivered,
       COALESCE(r.reserved, 0)::integer  AS reserved,
       (ol.quantity - COALESCE(d.delivered, 0))::integer AS remaining
FROM public.sales_order_lines ol
LEFT JOIN (SELECT dl.order_line_id, SUM(dl.quantity) AS delivered
           FROM public.delivery_lines dl JOIN public.deliveries dv ON dv.id = dl.delivery_id
           WHERE dv.status = 'delivered' GROUP BY dl.order_line_id) d ON d.order_line_id = ol.id
LEFT JOIN (SELECT order_line_id, SUM(quantity) AS reserved
           FROM public.stock_reservations WHERE status = 'active' GROUP BY order_line_id) r ON r.order_line_id = ol.id;

-- N03 / N04. Every schedule line with what is paid, fees due and its status
-- (in the shop's timezone).
CREATE VIEW public.v_schedule_line_status WITH (security_invoker = true) AS
WITH paid AS (
    SELECT schedule_line_id,
           SUM(amount) AS paid, SUM(principal_amount) AS paid_principal, SUM(profit_amount) AS paid_profit
    FROM public.v_effective_allocations WHERE schedule_line_id IS NOT NULL
    GROUP BY schedule_line_id
), fees AS (
    SELECT ch.schedule_line_id,
           SUM(ch.amount) AS charged,
           SUM(COALESCE(w.waived, 0)) AS waived,
           SUM(COALESCE(fp.paid, 0)) AS fees_paid
    FROM public.charges ch
    LEFT JOIN (SELECT charge_id, SUM(amount) AS waived FROM public.charge_waivers GROUP BY charge_id) w ON w.charge_id = ch.id
    LEFT JOIN (SELECT charge_id, SUM(amount) AS paid FROM public.v_effective_allocations
               WHERE charge_id IS NOT NULL GROUP BY charge_id) fp ON fp.charge_id = ch.id
    GROUP BY ch.schedule_line_id
)
SELECT sl.organization_id, sl.id AS schedule_line_id, sl.contract_id, sl.version, sl.seq,
       sl.due_date, sl.principal, sl.profit, sl.amount, sl.superseded,
       COALESCE(p.paid, 0)::numeric(18,2)           AS paid,
       COALESCE(p.paid_principal, 0)::numeric(18,2) AS paid_principal,
       COALESCE(p.paid_profit, 0)::numeric(18,2)    AS paid_profit,
       (sl.amount - COALESCE(p.paid, 0))::numeric(18,2) AS remaining,
       (sl.principal - COALESCE(p.paid_principal, 0))::numeric(18,2) AS principal_remaining,
       (COALESCE(f.charged, 0) - COALESCE(f.waived, 0) - COALESCE(f.fees_paid, 0))::numeric(18,2) AS fees_due,
       GREATEST((now() AT TIME ZONE o.timezone)::date - sl.due_date, 0) AS days_late,
       CASE
           WHEN sl.superseded THEN 'superseded'
           WHEN sl.amount - COALESCE(p.paid, 0) <= 0 THEN 'paid'
           WHEN c.status NOT IN ('active', 'rescheduled') THEN 'closed'     -- written off / returned / settled
           WHEN sl.due_date < (now() AT TIME ZONE o.timezone)::date THEN 'overdue'
           WHEN COALESCE(p.paid, 0) > 0 THEN 'partly_paid'
           WHEN sl.due_date = (now() AT TIME ZONE o.timezone)::date THEN 'due'
           ELSE 'upcoming'
       END AS status
FROM public.schedule_lines sl
JOIN public.contracts c ON c.id = sl.contract_id
JOIN public.organizations o ON o.id = sl.organization_id
LEFT JOIN paid p ON p.schedule_line_id = sl.id
LEFT JOIN fees f ON f.schedule_line_id = sl.id;

-- N02 / R02. One row per contract. Remaining counts the current schedule only;
-- paid counts every version.
CREATE VIEW public.v_contract_balances WITH (security_invoker = true) AS
SELECT c.organization_id, c.id AS contract_id, c.number, c.customer_id, c.branch_id, c.status,
       c.total_payable, c.financed_amount, c.markup_amount,
       COALESCE(SUM(ls.paid), 0)::numeric(18,2)           AS paid,
       COALESCE(SUM(ls.paid_principal), 0)::numeric(18,2) AS paid_principal,
       COALESCE(SUM(ls.paid_profit), 0)::numeric(18,2)    AS paid_profit,
       COALESCE(SUM(ls.remaining) FILTER (WHERE NOT ls.superseded), 0)::numeric(18,2)           AS remaining,
       COALESCE(SUM(ls.principal_remaining) FILTER (WHERE NOT ls.superseded), 0)::numeric(18,2) AS principal_outstanding,
       COALESCE(SUM(ls.fees_due), 0)::numeric(18,2) AS fees_due,
       COUNT(*) FILTER (WHERE ls.status = 'overdue')::integer AS overdue_lines,
       COALESCE(SUM(ls.remaining) FILTER (WHERE ls.status = 'overdue'), 0)::numeric(18,2) AS overdue_amount,
       MAX(ls.days_late) FILTER (WHERE ls.status = 'overdue') AS max_days_late,
       MIN(ls.due_date) FILTER (WHERE ls.status IN ('overdue', 'partly_paid', 'due', 'upcoming')) AS next_due_date
FROM public.contracts c
LEFT JOIN public.v_schedule_line_status ls ON ls.contract_id = c.id
GROUP BY c.organization_id, c.id, c.number, c.customer_id, c.branch_id, c.status,
         c.total_payable, c.financed_amount, c.markup_amount;

-- R03. Exposure = unpaid principal of open contracts.
CREATE VIEW public.v_customer_exposure WITH (security_invoker = true) AS
SELECT cu.organization_id, cu.id AS customer_id, cu.credit_limit, cu.status,
       COALESCE(SUM(cb.principal_outstanding) FILTER (WHERE cb.status IN ('active', 'rescheduled')), 0)::numeric(18,2) AS exposure,
       (cu.credit_limit - COALESCE(SUM(cb.principal_outstanding) FILTER (WHERE cb.status IN ('active', 'rescheduled')), 0))::numeric(18,2) AS available_credit,
       COALESCE(SUM(cb.overdue_amount) FILTER (WHERE cb.status IN ('active', 'rescheduled')), 0)::numeric(18,2) AS overdue_amount,
       COALESCE(SUM(cb.fees_due), 0)::numeric(18,2) AS fees_due,
       COUNT(cb.contract_id) FILTER (WHERE cb.status IN ('active', 'rescheduled'))::integer AS open_contracts,
       COALESCE(scb.balance, 0)::numeric(18,2) AS store_credit
FROM public.customers cu
LEFT JOIN public.v_contract_balances cb ON cb.customer_id = cu.id
LEFT JOIN public.store_credit_balances scb ON scb.customer_id = cu.id
GROUP BY cu.organization_id, cu.id, cu.credit_limit, cu.status, scb.balance;

-- D03. Overdue amounts by age bucket, per contract.
CREATE VIEW public.v_receivables_aging WITH (security_invoker = true) AS
SELECT ls.organization_id, c.branch_id, c.customer_id, ls.contract_id,
       COALESCE(SUM(ls.remaining) FILTER (WHERE ls.status IN ('upcoming', 'due', 'partly_paid')), 0)::numeric(18,2) AS not_yet_due,
       COALESCE(SUM(ls.remaining) FILTER (WHERE ls.status = 'overdue' AND ls.days_late BETWEEN 1 AND 30), 0)::numeric(18,2)  AS late_1_30,
       COALESCE(SUM(ls.remaining) FILTER (WHERE ls.status = 'overdue' AND ls.days_late BETWEEN 31 AND 60), 0)::numeric(18,2) AS late_31_60,
       COALESCE(SUM(ls.remaining) FILTER (WHERE ls.status = 'overdue' AND ls.days_late BETWEEN 61 AND 90), 0)::numeric(18,2) AS late_61_90,
       COALESCE(SUM(ls.remaining) FILTER (WHERE ls.status = 'overdue' AND ls.days_late > 90), 0)::numeric(18,2)              AS late_90_plus,
       COALESCE(SUM(ls.fees_due), 0)::numeric(18,2) AS fees_due
FROM public.v_schedule_line_status ls
JOIN public.contracts c ON c.id = ls.contract_id
WHERE NOT ls.superseded AND c.status IN ('active', 'rescheduled')
GROUP BY ls.organization_id, c.branch_id, c.customer_id, ls.contract_id;


-- =============================================================================
-- 20. ROW LEVEL SECURITY
-- =============================================================================
-- RLS on every table. authenticated reads its own org only. No write policies
-- exist and no write grants exist: writes go through SECURITY DEFINER functions.

DO $$
DECLARE t text;
BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    END LOOP;

    FOR t IN
        SELECT c.table_name FROM information_schema.columns c
        JOIN information_schema.tables tb ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name
        WHERE c.table_schema = 'public' AND c.column_name = 'organization_id' AND tb.table_type = 'BASE TABLE'
          AND c.table_name NOT IN ('jobs', 'audit_log', 'import_jobs')
    LOOP
        EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                        USING (organization_id = (SELECT app.current_org_id()))',
                       t || '_tenant_read', t);
    END LOOP;
END $$;

CREATE POLICY organizations_tenant_read ON public.organizations
    FOR SELECT TO authenticated
    USING (id = (SELECT app.current_org_id()) OR (SELECT app.is_super_admin()));

-- jsonb snapshots can hold personal data: readable only with the permission.
CREATE POLICY audit_log_tenant_read ON public.audit_log
    FOR SELECT TO authenticated
    USING (organization_id = (SELECT app.current_org_id()) AND (SELECT app.has_permission('audit.view')));
CREATE POLICY import_jobs_tenant_read ON public.import_jobs
    FOR SELECT TO authenticated
    USING (organization_id = (SELECT app.current_org_id())
           AND ((SELECT app.has_permission('import.data')) OR (SELECT app.has_permission('export.data'))));

CREATE POLICY plans_read            ON public.plans            FOR SELECT TO authenticated USING (true);
CREATE POLICY permissions_read      ON public.permissions      FOR SELECT TO authenticated USING (true);
CREATE POLICY role_permissions_read ON public.role_permissions FOR SELECT TO authenticated USING (true);
CREATE POLICY super_admins_self_read ON public.super_admins
    FOR SELECT TO authenticated USING (auth_user_id = (SELECT auth.uid()));
-- jobs, login_attempts: no policy = service role only.


-- =============================================================================
-- 21. GRANTS: deny by default, then grant exactly what is used
-- =============================================================================

REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app    FROM PUBLIC, anon, authenticated;

GRANT ALL ON ALL TABLES    IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app    TO service_role;

-- authenticated: SELECT only. PII and secrets are never granted (also fiscal_submissions.payload):
--   employees/customers/guarantors.national_id  -> read through a customer.view_pii function (R01)
--   invites.token_hash, eta_settings.client_secret_vault_id
DO $$
DECLARE
    r record;
    v_hidden text[] := ARRAY['national_id', 'token_hash', 'client_secret_vault_id'];
    v_cols text;
    v_has_hidden boolean;
BEGIN
    FOR r IN
        SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relkind IN ('r', 'v')
          AND c.relname NOT IN ('jobs', 'login_attempts', 'super_admins')
    LOOP
        -- hidden: PII/secret columns anywhere, plus the ETA payload (buyer IDs)
        SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum)
                   FILTER (WHERE NOT (a.attname = ANY (v_hidden)
                                      OR (r.relname = 'fiscal_submissions' AND a.attname = 'payload'))),
               bool_or(a.attname = ANY (v_hidden) OR (r.relname = 'fiscal_submissions' AND a.attname = 'payload'))
          INTO v_cols, v_has_hidden
        FROM pg_attribute a
        WHERE a.attrelid = format('public.%I', r.relname)::regclass
          AND a.attnum > 0 AND NOT a.attisdropped;
        IF v_has_hidden THEN
            EXECUTE format('GRANT SELECT (%s) ON public.%I TO authenticated', v_cols, r.relname);
        ELSE
            EXECUTE format('GRANT SELECT ON public.%I TO authenticated', r.relname);
        END IF;
    END LOOP;
END $$;

GRANT SELECT (auth_user_id, full_name, email, is_active) ON public.super_admins TO authenticated;

-- Helpers used inside RLS policies (they run with the caller's rights).
GRANT EXECUTE ON FUNCTION app.current_org_id(), app.is_super_admin(), app.has_permission(text) TO authenticated;

-- New objects get nothing automatically. Each slice grants EXECUTE on its own
-- write functions to authenticated, explicitly.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES    FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE ALL ON FUNCTIONS FROM PUBLIC;


-- =============================================================================
-- 22. STORAGE BUCKET (F14): private; no storage policies = service role only
-- =============================================================================

DO $$
BEGIN
    IF to_regclass('storage.buckets') IS NOT NULL THEN
        BEGIN
            INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
            VALUES ('tenant-files', 'tenant-files', false, 10485760,
                    ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf', 'text/csv',
                          'application/json', 'application/zip',
                          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
            ON CONFLICT (id) DO NOTHING;
        EXCEPTION WHEN others THEN
            RAISE WARNING 'baseline: could not create bucket tenant-files (%). Create it as PRIVATE in the dashboard.', SQLERRM;
        END;
    END IF;
END $$;


-- =============================================================================
-- 23. SEED: plans, permissions, role defaults
-- =============================================================================
-- Prices and limits are placeholders: change them in a later migration before launch.

INSERT INTO public.plans (key, name, description, price_monthly, max_branches, max_users, max_devices, modules, display_order) VALUES
    ('starter',    'Starter',    'One branch, cash sales.',                         500,  1,  5,  2, '{pos,inventory,purchasing,cash,eta}', 1),
    ('retail',     'Retail',     'Cash and in-house installments, collections.',   1200,  3, 15,  6, '{pos,inventory,purchasing,cash,eta,installments,customers}', 2),
    ('retail_pro', 'Retail Pro', 'Multi-branch, serials, delivery, legal, reports.', 2000, 5, 30, 12, '{pos,inventory,purchasing,cash,eta,installments,customers,serials,delivery,legal,reports}', 3),
    ('enterprise', 'Enterprise', 'Every V1 module.',                               4000, NULL, NULL, NULL, '{pos,inventory,purchasing,cash,eta,installments,customers,serials,delivery,legal,reports,import_export}', 4);

-- F06 keys. Must match the shared contracts list (F03). Add new keys with INSERTs.
INSERT INTO public.permissions (key, module, description) VALUES
    -- organization and people
    ('org.settings_manage',      'org',        'Edit shop settings, receipt, tax defaults, installment policy'),
    ('org.profile_manage',       'org',        'Edit legal and financing profile'),
    ('branch.manage',            'org',        'Create and edit branches'),
    ('device.manage',            'org',        'Register POS devices'),
    ('employee.manage',          'org',        'Invite, edit, deactivate employees; set roles, branches and permissions'),
    ('audit.view',               'org',        'Read the audit log'),
    -- catalog and stock
    ('catalog.manage',           'catalog',    'Create and edit categories, products, tax classes'),
    ('catalog.price_change',     'catalog',    'Change product prices'),
    ('label.print',              'catalog',    'Print barcode labels'),
    ('stock.view',               'stock',      'See stock levels and movements'),
    ('stock.adjust',             'stock',      'Post stock adjustments'),
    ('stock.count',              'stock',      'Run and post stock counts'),
    ('stock.transfer_send',      'stock',      'Send branch transfers'),
    ('stock.transfer_receive',   'stock',      'Receive branch transfers'),
    -- purchasing
    ('supplier.manage',          'purchasing', 'Create and edit suppliers'),
    ('purchase.order_manage',    'purchasing', 'Create and send purchase orders'),
    ('purchase.invoice_create',  'purchasing', 'Enter purchase invoices'),
    ('purchase.invoice_approve', 'purchasing', 'Approve purchase invoices (posts stock and cost)'),
    ('purchase.return_create',   'purchasing', 'Return goods to suppliers'),
    ('supplier.payment_create',  'purchasing', 'Pay suppliers'),
    -- cash
    ('cash.view',                'cash',       'See vaults, banks, wallets and balances'),
    ('cash.account_manage',      'cash',       'Create and edit cash accounts'),
    ('cash.transfer',            'cash',       'Move money between accounts'),
    ('cash.adjust',              'cash',       'Post cash adjustments'),
    ('shift.operate',            'cash',       'Open and close own shift'),
    ('expense.create',           'cash',       'Record expenses'),
    ('day.close',                'cash',       'Close the business day'),
    ('day.reopen',               'cash',       'Reopen a closed day'),
    -- customers and credit
    ('customer.create',          'customers',  'Create customers'),
    ('customer.edit',            'customers',  'Edit customers'),
    ('customer.view_pii',        'customers',  'See national IDs and ID photos'),
    ('guarantor.manage',         'customers',  'Add and edit guarantors'),
    ('credit.approve',           'customers',  'Set credit limits and approve credit exceptions'),
    ('survey.assign',            'customers',  'Assign field surveys'),
    ('survey.submit',            'customers',  'Fill and submit field surveys'),
    ('survey.decide',            'customers',  'Approve or reject surveys'),
    -- sales
    ('sale.create',              'sales',      'Make sales at the POS'),
    ('sale.void',                'sales',      'Void a same-day sale'),
    ('price.override',           'sales',      'Sell below or above the list price'),
    ('discount.above_cap',       'sales',      'Give discounts above the role cap'),
    ('refund.create',            'sales',      'Process returns and refunds'),
    ('quotation.manage',         'sales',      'Create and send quotations'),
    ('order.manage',             'sales',      'Create sales orders and take deposits'),
    ('order.cancel',             'sales',      'Cancel sales orders'),
    ('delivery.manage',          'sales',      'Schedule and complete deliveries'),
    ('warranty.manage',          'sales',      'Open and resolve warranty claims'),
    -- installments
    ('installment.create',       'installments', 'Make installment sales'),
    ('collection.create',        'installments', 'Take installment payments'),
    ('collector.settle',         'installments', 'Settle collector wallets into the vault'),
    ('charge.waive',             'installments', 'Waive late fees'),
    ('schedule.change',          'installments', 'Reschedule contracts'),
    ('contract.settle_early',    'installments', 'Settle contracts early'),
    ('contract.write_off',       'installments', 'Write off contracts'),
    -- tax, reports, data, legal
    ('fiscal.view',              'tax',        'See ETA submission status'),
    ('fiscal.retry',             'tax',        'Retry failed ETA submissions'),
    ('report.view',              'reports',    'Operational reports'),
    ('report.financial',         'reports',    'Margins, valuation, tax and receivables reports'),
    ('export.data',              'data',       'Export shop data'),
    ('import.data',              'data',       'Import data and opening balances'),
    ('legal.view',               'legal',      'See legal cases'),
    ('legal.manage',             'legal',      'Open and update legal cases');

-- Role defaults (OWNER has everything without rows). Owners adjust per employee.
INSERT INTO public.role_permissions (role, permission_key)
SELECT 'BRANCH_MANAGER'::public.employee_role, key FROM public.permissions
WHERE key NOT IN ('org.settings_manage', 'org.profile_manage', 'branch.manage', 'employee.manage',
                  'day.reopen', 'contract.write_off', 'export.data', 'import.data',
                  'cash.account_manage', 'legal.manage');

INSERT INTO public.role_permissions (role, permission_key)
SELECT r.role::public.employee_role, r.key
FROM (VALUES
    ('CASHIER', 'sale.create'), ('CASHIER', 'quotation.manage'), ('CASHIER', 'order.manage'),
    ('CASHIER', 'customer.create'), ('CASHIER', 'installment.create'), ('CASHIER', 'collection.create'),
    ('CASHIER', 'shift.operate'), ('CASHIER', 'stock.view'), ('CASHIER', 'label.print'),
    ('CASHIER', 'warranty.manage'),

    ('WAREHOUSE', 'stock.view'), ('WAREHOUSE', 'stock.count'), ('WAREHOUSE', 'stock.transfer_send'),
    ('WAREHOUSE', 'stock.transfer_receive'), ('WAREHOUSE', 'purchase.order_manage'),
    ('WAREHOUSE', 'purchase.invoice_create'), ('WAREHOUSE', 'delivery.manage'), ('WAREHOUSE', 'label.print'),

    ('COLLECTOR', 'collection.create'), ('COLLECTOR', 'survey.submit'),

    ('ACCOUNTANT', 'cash.view'), ('ACCOUNTANT', 'cash.transfer'), ('ACCOUNTANT', 'expense.create'),
    ('ACCOUNTANT', 'supplier.payment_create'), ('ACCOUNTANT', 'collector.settle'), ('ACCOUNTANT', 'day.close'),
    ('ACCOUNTANT', 'fiscal.view'), ('ACCOUNTANT', 'fiscal.retry'), ('ACCOUNTANT', 'report.view'),
    ('ACCOUNTANT', 'report.financial'), ('ACCOUNTANT', 'export.data'), ('ACCOUNTANT', 'audit.view'),
    ('ACCOUNTANT', 'stock.view'),

    ('LAWYER', 'legal.view'), ('LAWYER', 'legal.manage'), ('LAWYER', 'customer.view_pii')
) AS r(role, key);


-- =============================================================================
-- 24. SELF-CHECK: abort everything if the rules above are not exactly true
-- =============================================================================

DO $$
DECLARE v_bad text;
BEGIN
    -- anon: no privilege on anything in public
    SELECT string_agg(c.relname, ', ') INTO v_bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'v', 'm', 'S')
      AND (CASE WHEN c.relkind = 'S' THEN has_sequence_privilege('anon', c.oid, 'USAGE, SELECT, UPDATE')
                ELSE has_table_privilege('anon', c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
                     OR has_any_column_privilege('anon', c.oid, 'SELECT, INSERT, UPDATE, REFERENCES') END);
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'self-check: anon has privileges on %', v_bad; END IF;

    -- authenticated: no write privilege anywhere
    SELECT string_agg(c.relname, ', ') INTO v_bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'v', 'm')
      AND (has_table_privilege('authenticated', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
           OR has_any_column_privilege('authenticated', c.oid, 'INSERT, UPDATE, REFERENCES'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'self-check: authenticated can write to %', v_bad; END IF;

    -- authenticated: PII and secrets unreadable
    SELECT string_agg(c.relname || '.' || a.attname, ', ') INTO v_bad
    FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND a.attnum > 0 AND NOT a.attisdropped
      AND (a.attname IN ('national_id', 'token_hash', 'client_secret_vault_id')
           OR (c.relname = 'fiscal_submissions' AND a.attname = 'payload'))
      AND has_column_privilege('authenticated', c.oid, a.attnum, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'self-check: authenticated can read %', v_bad; END IF;

    -- service-only tables
    IF has_table_privilege('authenticated', 'public.jobs', 'SELECT')
       OR has_table_privilege('authenticated', 'public.login_attempts', 'SELECT') THEN
        RAISE EXCEPTION 'self-check: authenticated can read jobs/login_attempts';
    END IF;

    -- EXECUTE: anon nothing; authenticated only the two RLS helpers
    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public', 'app')
      AND (has_function_privilege('anon', p.oid, 'EXECUTE')
           OR (has_function_privilege('authenticated', p.oid, 'EXECUTE')
               AND p.oid NOT IN ('app.current_org_id()'::regprocedure, 'app.is_super_admin()'::regprocedure,
                                 'app.has_permission(text)'::regprocedure)));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'self-check: wrong EXECUTE grants on %', v_bad; END IF;

    -- RLS on every table; a read policy on every tenant table
    SELECT string_agg(tablename, ', ') INTO v_bad FROM pg_tables
    WHERE schemaname = 'public' AND NOT rowsecurity;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'self-check: RLS off on %', v_bad; END IF;

    SELECT string_agg(c.table_name, ', ') INTO v_bad
    FROM information_schema.columns c
    JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE c.table_schema = 'public' AND c.column_name = 'organization_id' AND t.table_type = 'BASE TABLE'
      AND c.table_name <> 'jobs'
      AND NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = c.table_name);
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'self-check: no tenant policy on %', v_bad; END IF;

    -- every view runs as invoker
    SELECT string_agg(c.relname, ', ') INTO v_bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'v'
      AND NOT ('security_invoker=true' = ANY (COALESCE(c.reloptions, '{}')));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'self-check: view without security_invoker: %', v_bad; END IF;

    -- every function has a fixed search_path
    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public', 'app')
      AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig, '{}')) cfg WHERE cfg LIKE 'search_path=%');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'self-check: mutable search_path on %', v_bad; END IF;

    -- every tenant table with an id has UNIQUE (id, organization_id)
    SELECT string_agg(c.relname, ', ') INTO v_bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname NOT IN ('organizations', 'jobs', 'audit_log')   -- audit_log: bigint id, never referenced
      AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'organization_id')
      AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'id')
      AND NOT EXISTS (
          SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'u'
            AND (SELECT array_agg(a.attname::text ORDER BY a.attname) FROM pg_attribute a
                 WHERE a.attrelid = c.oid AND a.attnum = ANY (k.conkey)) = ARRAY['id', 'organization_id']);
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'self-check: missing UNIQUE (id, organization_id) on %', v_bad; END IF;

    -- every FK to a tenant table includes organization_id (no cross-shop links)
    SELECT string_agg(k.conname, ', ') INTO v_bad
    FROM pg_constraint k
    JOIN pg_namespace n ON n.oid = (SELECT relnamespace FROM pg_class WHERE oid = k.conrelid)
    WHERE n.nspname = 'public' AND k.contype = 'f'
      AND k.confrelid <> 'public.organizations'::regclass
      AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = k.confrelid AND a.attname = 'organization_id')
      AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                      WHERE a.attrelid = k.confrelid AND a.attname = 'organization_id' AND a.attnum = ANY (k.confkey));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'self-check: FK without organization_id: %', v_bad; END IF;

    -- no cascading or nulling deletes
    SELECT string_agg(k.conname, ', ') INTO v_bad
    FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND k.contype = 'f' AND k.confdeltype NOT IN ('a', 'r');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'self-check: FK with CASCADE/SET NULL: %', v_bad; END IF;

    -- every tenant table is linked to organizations
    SELECT string_agg(c.relname, ', ') INTO v_bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname <> 'organizations'
      AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'organization_id')
      AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'f'
                        AND k.confrelid = 'public.organizations'::regclass);
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'self-check: no FK to organizations on %', v_bad; END IF;

    RAISE NOTICE 'baseline: schema created and self-check passed';
END $$;

COMMIT;
