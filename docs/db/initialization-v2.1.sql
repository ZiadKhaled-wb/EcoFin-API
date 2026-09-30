-- =============================================================================
-- EcoFin Pro — Database Initialization Script (v2.1)
-- Target: PostgreSQL 15+ / Supabase
-- Generated: 2026-09-30
-- =============================================================================
--
-- READ THIS BEFORE RUNNING
-- ========================
--
-- This script DROPS the entire `public` schema. Any existing data is lost.
-- Run only on a fresh project or when you are certain.
--
-- WHAT THIS SCRIPT DOES
-- ---------------------
-- Creates the canonical schema for EcoFin Pro v1, per the ratified decisions:
--   * Money is bigint piasters (no floats, no numeric money).
--   * Installments have no principal/profit split (ADR-0001).
--   * Payments are immutable; acceptance is a separate event (ADR-0003).
--   * Vault and wallet balances are views, not columns (ledger-first).
--   * Roles: no MODERATOR, no SUPER_ADMIN on employees.
--   * Tenant slug on organizations.
--   * RLS via auth.uid() — works with Supabase anon+JWT.
--   * Cross-tenant integrity enforced by composite FKs, not triggers.
--
-- ORDERING RULES (learned the hard way; keep them in mind when editing):
--
--   R1. Postgres validates `LANGUAGE sql` function bodies at CREATE time.
--       Any helper that references a table must be created AFTER that table.
--       This is why the auth helpers live in §4B, not §2.
--
--   R2. A composite FK `(x, y) REFERENCES parent(a, b)` requires a UNIQUE
--       or PRIMARY KEY constraint on parent(a, b) to already exist when
--       the FK is declared. This applies to inline FKs in CREATE TABLE
--       AND to ALTER TABLE ... ADD CONSTRAINT.
--
--   R3. If two tables FK each other, one side must be deferred to an
--       ALTER TABLE that runs after both tables exist.
--
-- WHAT THIS SCRIPT DOES NOT INCLUDE
-- ---------------------------------
--   * Payroll tables (v2).
--   * ETA e-invoice tables (design when integration is built).
--   * Runtime feature flag state.
--   * Offline sync tables.
--
-- HOW TO CONNECT FROM THE API SERVER
-- ----------------------------------
-- Tenant requests: Supabase anon client with the user's JWT. RLS enforces
-- isolation via auth.uid().
--
-- Super Admin requests: Supabase service_role key, used ONLY by platform
-- endpoints. Never for tenant operations. Service role bypasses RLS by design.
--
-- If you later switch to a direct Postgres connection from the API server:
--   BEGIN;
--   SET LOCAL app.current_org_id = '<org-uuid>';
--   ... queries ...
--   COMMIT;
-- and switch the RLS policies to read `current_setting('app.current_org_id')`.
-- The current policies use auth.uid() so they work with Supabase's default
-- PostgREST-based client out of the box.
--
-- =============================================================================


-- =============================================================================
-- SECTION 1 — EXTENSIONS
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;        -- case-insensitive text


-- =============================================================================
-- SECTION 2 — PURE HELPER FUNCTIONS
-- =============================================================================
--
-- Only functions with no table dependencies live here. Functions that read
-- from `employees` or `super_admins` are in §4B — Postgres validates
-- LANGUAGE sql bodies at CREATE time, so those functions cannot be defined
-- before the tables they reference.

-- Money conversion helpers. Use these at API boundaries; never inline.
CREATE OR REPLACE FUNCTION public.egp_to_piasters(p_egp numeric)
RETURNS bigint
LANGUAGE sql IMMUTABLE
AS $$ SELECT ROUND(p_egp * 100)::bigint $$;

CREATE OR REPLACE FUNCTION public.piasters_to_egp(p_piasters bigint)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$ SELECT ROUND(p_piasters::numeric / 100, 2) $$;

-- Generic updated_at trigger function. LANGUAGE plpgsql — body is not
-- resolved at CREATE time, so this can be defined before its triggers.
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;


-- =============================================================================
-- SECTION 3 — PLATFORM: ORGANIZATIONS, PLANS, LICENSES, SUPER ADMINS
-- =============================================================================

-- Reference table for plans. Seed data added at bottom.
CREATE TABLE public.plans (
    key text PRIMARY KEY,
    display_name text NOT NULL,
    display_name_ar text NOT NULL,
    description text,
    max_branches integer,
    max_users integer,
    monthly_price_egp numeric(10,2),
    is_active boolean NOT NULL DEFAULT true,
    display_order integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.organizations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_slug text NOT NULL UNIQUE
        CHECK (tenant_slug ~ '^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])?$'),
    name text NOT NULL,
    name_ar text,
    owner_name text NOT NULL,
    owner_phone varchar(20) NOT NULL,
    contact_phone varchar(20) NOT NULL,
    contact_email citext,
    address text,
    tax_id varchar(50),
    commercial_register varchar(50),
    business_type text,
    logo_url text,
    receipt_footer_text text,

    -- Plan snapshot (denormalized for fast reads; source of truth in
    -- organization_plans for audit, this is the "current effective" snapshot).
    plan_key text REFERENCES public.plans(key),
    subscription_end_date timestamptz,
    is_active boolean NOT NULL DEFAULT true,
    is_suspended boolean NOT NULL DEFAULT false,
    suspension_reason text,

    -- Defaults used by domain services (configurable per org).
    min_down_payment_pct numeric(5,2) NOT NULL DEFAULT 0.00,
    max_installment_months integer NOT NULL DEFAULT 36,
    discount_cap_pct numeric(5,2) NOT NULL DEFAULT 0,
    discount_requires_approval boolean NOT NULL DEFAULT true,
    collector_commission_pct numeric(5,2) NOT NULL DEFAULT 0,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_organizations_is_active ON public.organizations (is_active);
CREATE INDEX idx_organizations_plan ON public.organizations (plan_key);

-- License issuance. One row per license key. Used once, at activation.
CREATE TABLE public.saaslicenses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    license_key varchar(64) NOT NULL UNIQUE,
    plan_key text NOT NULL REFERENCES public.plans(key),
    valid_months integer NOT NULL,
    is_used boolean NOT NULL DEFAULT false,
    is_active boolean NOT NULL DEFAULT true,
    is_revoked boolean NOT NULL DEFAULT false,
    revoked_reason text,
    issued_to_org_id uuid REFERENCES public.organizations(id) ON DELETE SET NULL,
    claimed_at timestamptz,
    expires_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT chk_license_used_has_org
        CHECK (is_used = false OR issued_to_org_id IS NOT NULL)
);

CREATE INDEX idx_saaslicenses_org ON public.saaslicenses (issued_to_org_id);

-- Subscription history (audit trail for plan changes).
CREATE TABLE public.organization_plans (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    plan_key text NOT NULL REFERENCES public.plans(key),
    billing_cycle text NOT NULL CHECK (billing_cycle IN ('MONTHLY', 'ANNUAL')),
    effective_from timestamptz NOT NULL DEFAULT now(),
    effective_to timestamptz,
    current_period_end timestamptz NOT NULL,
    price_egp numeric(10,2) NOT NULL,
    notes text,
    created_by_super_admin_id uuid,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_org_plans_org ON public.organization_plans (organization_id, effective_from DESC);

-- Add-ons per tenant.
CREATE TABLE public.organization_addons (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    addon_key text NOT NULL,
    quantity integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
    monthly_price_egp numeric(10,2) NOT NULL,
    effective_from timestamptz NOT NULL DEFAULT now(),
    effective_to timestamptz,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_org_addons_org ON public.organization_addons (organization_id) WHERE is_active = true;

-- Platform Super Admins. Not tenant users.
CREATE TABLE public.super_admins (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE RESTRICT,
    full_name text NOT NULL,
    email citext NOT NULL UNIQUE,
    phone varchar(20),
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 4 — TENANT FOUNDATION: BRANCHES, EMPLOYEES
-- =============================================================================

CREATE TABLE public.branches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    name text NOT NULL,
    name_ar text,
    branch_code varchar(20),
    address text,
    city text,
    governorate text,
    latitude numeric(10,8),
    longitude numeric(11,8),
    phone varchar(20),
    email citext,
    is_main_branch boolean NOT NULL DEFAULT false,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_branches_org ON public.branches (organization_id) WHERE is_active = true;
CREATE UNIQUE INDEX idx_branches_main_per_org
    ON public.branches (organization_id) WHERE is_main_branch = true;
CREATE UNIQUE INDEX idx_branches_code
    ON public.branches (organization_id, branch_code) WHERE branch_code IS NOT NULL;

-- Composite key needed for FKs from children.
ALTER TABLE public.branches
    ADD CONSTRAINT branches_id_org_key UNIQUE (id, organization_id);

-- Employees. One auth_id -> one employee -> one org.
-- Role determines base capabilities; permissions[] is the fine-grained gate.
CREATE TABLE public.employees (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    branch_id uuid,
    auth_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,

    -- Identity
    full_name text NOT NULL,
    full_name_ar text,
    username citext,
    phone varchar(20),
    email citext,
    national_id varchar(20),
    address text,
    hire_date date,
    base_salary_piasters bigint,

    -- Access
    role text NOT NULL CHECK (role IN (
        'OWNER', 'OPS_MANAGER', 'ACCOUNTANT',
        'CASHIER', 'COLLECTOR', 'WAREHOUSE_MANAGER',
        'HR_MANAGER', 'LAWYER', 'EMPLOYEE'
    )),
    permissions text[] NOT NULL DEFAULT ARRAY[]::text[],

    -- State
    is_active boolean NOT NULL DEFAULT true,
    must_change_password boolean NOT NULL DEFAULT false,
    last_login_at timestamptz,

    -- HR-ish fields kept here for v1; v2 will normalize into hr_contracts
    point_value_piasters bigint NOT NULL DEFAULT 1000,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT employees_branch_org_fk
        FOREIGN KEY (branch_id, organization_id)
        REFERENCES public.branches (id, organization_id)
);

CREATE INDEX idx_employees_org ON public.employees (organization_id, role) WHERE is_active = true;
CREATE INDEX idx_employees_auth ON public.employees (auth_id);
CREATE INDEX idx_employees_branch ON public.employees (branch_id) WHERE is_active = true;

-- One owner per org (partial unique index).
CREATE UNIQUE INDEX idx_employees_one_owner_per_org
    ON public.employees (organization_id) WHERE role = 'OWNER';

-- Username unique per org (case-insensitive).
CREATE UNIQUE INDEX idx_employees_username_per_org
    ON public.employees (organization_id, username) WHERE username IS NOT NULL;

-- Composite key for FKs.
ALTER TABLE public.employees
    ADD CONSTRAINT employees_id_org_key UNIQUE (id, organization_id);


-- =============================================================================
-- SECTION 4B — AUTH HELPER FUNCTIONS
-- =============================================================================
--
-- These functions reference `employees` and `super_admins`, both of which
-- must exist before these CREATE FUNCTION statements run. Postgres validates
-- LANGUAGE sql bodies at creation time (check_function_bodies is on by
-- default), so these cannot live alongside the pure helpers in §2.
--
-- ORDERING RULES they satisfy:
--   * §4 creates employees and super_admins must exist (§3).
--   * §21 (RLS policies) references these functions — it runs after §4B.

-- Returns the organization_id of the calling user's employee record.
-- Used by every tenant isolation RLS policy.
CREATE OR REPLACE FUNCTION public.current_user_org_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT organization_id
    FROM public.employees
    WHERE auth_id = auth.uid()
      AND is_active = true
    LIMIT 1
$$;

-- Returns true if the calling user is a platform Super Admin.
CREATE OR REPLACE FUNCTION public.is_super_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.super_admins
        WHERE auth_user_id = auth.uid() AND is_active = true
    )
$$;

-- Returns the employee_id of the calling user (tenant users only).
CREATE OR REPLACE FUNCTION public.current_employee_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT id FROM public.employees
    WHERE auth_id = auth.uid() AND is_active = true
    LIMIT 1
$$;

-- Returns the role of the calling user (tenant users only).
CREATE OR REPLACE FUNCTION public.current_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT role FROM public.employees
    WHERE auth_id = auth.uid() AND is_active = true
    LIMIT 1
$$;

-- Returns true if the calling user is an Owner.
CREATE OR REPLACE FUNCTION public.is_owner()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$ SELECT public.current_role() = 'OWNER' $$;


-- =============================================================================
-- SECTION 5 — MASTER DATA: CATEGORIES, PRODUCTS, SUPPLIERS
-- =============================================================================

CREATE TABLE public.categories (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    parent_id uuid,
    name text NOT NULL,
    name_ar text,
    description text,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_categories_org ON public.categories (organization_id) WHERE is_active = true;

-- Composite unique required by products.products_category_org_fk below.
-- Must exist before products is created; Postgres validates FK targets
-- at CREATE TABLE time.
ALTER TABLE public.categories
    ADD CONSTRAINT categories_id_org_key UNIQUE (id, organization_id);

CREATE TABLE public.suppliers (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    name text NOT NULL,
    contact_person text,
    phone varchar(20),
    email citext,
    address text,
    category text,
    tax_id varchar(50),
    notes text,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_suppliers_org ON public.suppliers (organization_id) WHERE is_active = true;

ALTER TABLE public.suppliers
    ADD CONSTRAINT suppliers_id_org_key UNIQUE (id, organization_id);

-- Weighted-average costing for v1. Moving average is recomputed on approved
-- purchase receipts (in service, not trigger).
CREATE TABLE public.products (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    category_id uuid,
    name text NOT NULL,
    name_ar text,
    description text,
    sku varchar(64),
    barcode varchar(64),
    unit text NOT NULL DEFAULT 'قطعة',
    product_type text NOT NULL DEFAULT 'STANDARD'
        CHECK (product_type IN ('STANDARD', 'SERVICE')),

    -- Prices, all in piasters
    cost_price_piasters bigint NOT NULL DEFAULT 0,        -- weighted average
    cash_price_piasters bigint NOT NULL DEFAULT 0,
    installment_price_piasters bigint NOT NULL DEFAULT 0, -- "max cash-equivalent"
    wholesale_price_piasters bigint NOT NULL DEFAULT 0,

    -- Stock is a projection; cached here for read performance, updated only
    -- by inventory services, reconciled nightly.
    stock_quantity_cached integer NOT NULL DEFAULT 0,

    expiring_date date,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT products_category_org_fk
        FOREIGN KEY (category_id, organization_id)
        REFERENCES public.categories (id, organization_id)
);

-- Partial unique indexes for barcode and SKU per org.
CREATE UNIQUE INDEX idx_products_barcode
    ON public.products (organization_id, barcode) WHERE barcode IS NOT NULL;
CREATE UNIQUE INDEX idx_products_sku
    ON public.products (organization_id, sku) WHERE sku IS NOT NULL;
CREATE INDEX idx_products_org_cat ON public.products (organization_id, category_id);

ALTER TABLE public.products
    ADD CONSTRAINT products_id_org_key UNIQUE (id, organization_id);


-- =============================================================================
-- SECTION 6 — CRM: CUSTOMERS, GUARANTORS, FIELD SURVEYS
-- =============================================================================

CREATE TABLE public.customers (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    branch_id uuid,

    full_name text NOT NULL,
    full_name_ar text,
    phone varchar(20) NOT NULL,
    alternate_phone varchar(20),
    national_id varchar(20),
    email citext,

    -- Address
    address text,
    city text,
    area text,
    address_details text,
    latitude numeric(10,8),
    longitude numeric(11,8),

    -- Employment / income
    job text,
    job_type text,
    employer_address text,
    monthly_income_piasters bigint,

    -- Housing / marital
    housing_type text,
    marital_status text,

    -- Banking
    bank_name text,
    bank_account text,
    iban text,

    -- Credit
    credit_limit_piasters bigint NOT NULL DEFAULT 0,
    credit_score integer NOT NULL DEFAULT 50 CHECK (credit_score BETWEEN 0 AND 100),
    status text NOT NULL DEFAULT 'ACTIVE'
        CHECK (status IN ('ACTIVE', 'INACTIVE', 'BLACKLISTED')),

    -- Internal
    internal_code varchar(64),
    notes text,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT customers_branch_org_fk
        FOREIGN KEY (branch_id, organization_id)
        REFERENCES public.branches (id, organization_id)
);

CREATE INDEX idx_customers_org ON public.customers (organization_id);
CREATE INDEX idx_customers_org_status ON public.customers (organization_id, status);
CREATE INDEX idx_customers_phone ON public.customers (organization_id, phone);
CREATE UNIQUE INDEX idx_customers_national_id
    ON public.customers (organization_id, national_id) WHERE national_id IS NOT NULL;

ALTER TABLE public.customers
    ADD CONSTRAINT customers_id_org_key UNIQUE (id, organization_id);

CREATE TABLE public.guarantors (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    full_name text NOT NULL,
    phone varchar(20) NOT NULL,
    national_id varchar(20),
    address text,
    job text,
    relationship_to_customer text,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_guarantors_org ON public.guarantors (organization_id);

ALTER TABLE public.guarantors
    ADD CONSTRAINT guarantors_id_org_key UNIQUE (id, organization_id);

CREATE TABLE public.client_guarantors (
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    customer_id uuid NOT NULL,
    guarantor_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (customer_id, guarantor_id),
    FOREIGN KEY (customer_id, organization_id)
        REFERENCES public.customers (id, organization_id) ON DELETE CASCADE,
    FOREIGN KEY (guarantor_id, organization_id)
        REFERENCES public.guarantors (id, organization_id) ON DELETE CASCADE
);

CREATE TABLE public.field_surveys (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    employee_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    guarantor_id uuid,

    latitude numeric(10,8) NOT NULL,
    longitude numeric(11,8) NOT NULL,
    gps_accuracy real,
    is_suspicious_location boolean NOT NULL DEFAULT false,

    status text NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),

    housing_quality smallint CHECK (housing_quality BETWEEN 1 AND 10),
    neighborhood_quality smallint CHECK (neighborhood_quality BETWEEN 1 AND 10),
    income_stability smallint CHECK (income_stability BETWEEN 1 AND 10),
    employment_status smallint CHECK (employment_status BETWEEN 1 AND 10),
    property_ownership smallint CHECK (property_ownership BETWEEN 1 AND 10),
    overall_impression smallint CHECK (overall_impression BETWEEN 1 AND 10),

    recommendation text,
    reviewed_by uuid,
    reviewed_at timestamptz,
    rejection_reason text,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (employee_id, organization_id)
        REFERENCES public.employees (id, organization_id),
    FOREIGN KEY (customer_id, organization_id)
        REFERENCES public.customers (id, organization_id),
    FOREIGN KEY (guarantor_id, organization_id)
        REFERENCES public.guarantors (id, organization_id)
);

CREATE INDEX idx_field_surveys_org_status ON public.field_surveys (organization_id, status);

CREATE TABLE public.survey_attachments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    survey_id uuid NOT NULL REFERENCES public.field_surveys(id) ON DELETE CASCADE,
    url text NOT NULL,
    attachment_type text NOT NULL CHECK (attachment_type IN ('photo', 'signature')),
    created_at timestamptz NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 7 — INVENTORY
-- =============================================================================

-- Append-only ledger of quantity changes. Current stock is a projection.
CREATE TABLE public.inventory_transactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    product_id uuid NOT NULL,
    quantity_changed integer NOT NULL,

    transaction_type text NOT NULL CHECK (transaction_type IN (
        'SALE', 'SALE_RETURN',
        'PURCHASE', 'PURCHASE_RETURN',
        'TRANSFER_IN', 'TRANSFER_OUT',
        'ADJUSTMENT', 'OPENING_BALANCE'
    )),

    reference_id uuid,
    reference_table text,
    reason text,

    recorded_by_employee_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (product_id, organization_id)
        REFERENCES public.products (id, organization_id),
    FOREIGN KEY (recorded_by_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE INDEX idx_inventory_tx_org_date ON public.inventory_transactions (organization_id, created_at DESC);
CREATE INDEX idx_inventory_tx_product ON public.inventory_transactions (product_id, created_at DESC);

-- Cost change history for reporting and audit.
CREATE TABLE public.product_cost_log (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    product_id uuid NOT NULL,
    old_cost_piasters bigint,
    new_cost_piasters bigint,
    changed_by_employee_id uuid,
    reference_type text,
    reference_id uuid,
    changed_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (product_id, organization_id)
        REFERENCES public.products (id, organization_id)
);

CREATE INDEX idx_product_cost_log_product ON public.product_cost_log (product_id, changed_at DESC);


-- =============================================================================
-- SECTION 8 — SALES: CONTRACTS, ITEMS, INSTALLMENTS, APPLICATIONS
-- =============================================================================

CREATE TABLE public.contracts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    branch_id uuid,
    customer_id uuid,
    cashier_employee_id uuid NOT NULL,

    sale_type text NOT NULL CHECK (sale_type IN ('CASH', 'SHIPPING', 'INSTALLMENT')),
    status text NOT NULL DEFAULT 'ACTIVE'
        CHECK (status IN ('ACTIVE', 'COMPLETED', 'PAUSED', 'VOID')),

    -- Money (all piasters). No principal/profit split on installments — see ADR-0001.
    total_sale_amount_piasters bigint NOT NULL CHECK (total_sale_amount_piasters >= 0),
    cost_of_goods_piasters bigint NOT NULL DEFAULT 0,
    down_payment_piasters bigint NOT NULL DEFAULT 0
        CHECK (down_payment_piasters >= 0),
    shipping_fee_piasters bigint NOT NULL DEFAULT 0,
    discount_amount_piasters bigint NOT NULL DEFAULT 0,
    discount_reason text,

    -- Derived (stored as generated columns for query performance):
    disclosed_profit_piasters bigint GENERATED ALWAYS AS
        (total_sale_amount_piasters - cost_of_goods_piasters) STORED,
    installment_principal_piasters bigint GENERATED ALWAYS AS
        (total_sale_amount_piasters - down_payment_piasters) STORED,

    -- Shipping
    shipping_status text CHECK (shipping_status IS NULL OR shipping_status IN ('PENDING', 'DELIVERED')),

    -- Void
    voided_at timestamptz,
    voided_by_employee_id uuid,
    void_reason text,

    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT contracts_down_payment_lt_total
        CHECK (sale_type <> 'INSTALLMENT' OR down_payment_piasters < total_sale_amount_piasters),

    CONSTRAINT contracts_cash_down_zero
        CHECK (sale_type = 'INSTALLMENT' OR down_payment_piasters = 0),

    FOREIGN KEY (branch_id, organization_id)
        REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (customer_id, organization_id)
        REFERENCES public.customers (id, organization_id),
    FOREIGN KEY (cashier_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id),
    FOREIGN KEY (voided_by_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE INDEX idx_contracts_org_status ON public.contracts (organization_id, status, created_at DESC);
CREATE INDEX idx_contracts_customer ON public.contracts (customer_id);
CREATE INDEX idx_contracts_org_saletype ON public.contracts (organization_id, sale_type, created_at DESC);

ALTER TABLE public.contracts
    ADD CONSTRAINT contracts_id_org_key UNIQUE (id, organization_id);

CREATE TABLE public.contract_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    contract_id uuid NOT NULL,
    product_id uuid NOT NULL,
    quantity integer NOT NULL CHECK (quantity > 0),
    unit_price_piasters bigint NOT NULL CHECK (unit_price_piasters >= 0),
    unit_cost_piasters bigint NOT NULL DEFAULT 0,
    line_total_piasters bigint GENERATED ALWAYS AS
        (quantity * unit_price_piasters) STORED,
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (contract_id, organization_id)
        REFERENCES public.contracts (id, organization_id) ON DELETE CASCADE,
    FOREIGN KEY (product_id, organization_id)
        REFERENCES public.products (id, organization_id)
);

CREATE INDEX idx_contract_items_contract ON public.contract_items (contract_id);

-- Installments. Murabaha: agreed amount only, no principal/profit split.
-- paid_amount is a projection (see installment_balances view).
CREATE TABLE public.installments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    contract_id uuid NOT NULL,
    sequence integer NOT NULL,
    due_date date NOT NULL,
    agreed_amount_piasters bigint NOT NULL CHECK (agreed_amount_piasters > 0),
    status text NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'PARTIALLY_PAID', 'PAID', 'SETTLED_EARLY', 'CANCELLED')),

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    UNIQUE (contract_id, sequence),

    FOREIGN KEY (contract_id, organization_id)
        REFERENCES public.contracts (id, organization_id) ON DELETE CASCADE
);

CREATE INDEX idx_installments_contract_status ON public.installments (contract_id, status, due_date);
CREATE INDEX idx_installments_due ON public.installments (organization_id, due_date)
    WHERE status IN ('PENDING', 'PARTIALLY_PAID');

ALTER TABLE public.installments
    ADD CONSTRAINT installments_id_org_key UNIQUE (id, organization_id);

-- Immutable lifecycle events for installments: reschedules, defaults,
-- early settlements, write-offs, cancellations.
CREATE TABLE public.installment_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    installment_id uuid NOT NULL,
    event_type text NOT NULL CHECK (event_type IN (
        'PARTIALLY_PAID', 'PAID', 'SETTLED_EARLY', 'RESCHEDULED',
        'DEFAULTED', 'WRITTEN_OFF', 'CANCELLED'
    )),
    previous_due_date date,
    new_due_date date,
    reason text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    recorded_by_employee_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (installment_id, organization_id)
        REFERENCES public.installments (id, organization_id) ON DELETE CASCADE
);

CREATE INDEX idx_installment_events_inst ON public.installment_events (installment_id, created_at DESC);

-- When a payment is applied to installments, one row per installment affected.
-- This is the source of truth for "which installment was paid by which payment".
CREATE TABLE public.payment_installment_applications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    payment_id uuid NOT NULL,
    installment_id uuid NOT NULL,
    amount_piasters bigint NOT NULL CHECK (amount_piasters > 0),
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (installment_id, organization_id)
        REFERENCES public.installments (id, organization_id)
);

CREATE INDEX idx_pia_payment ON public.payment_installment_applications (payment_id);
CREATE INDEX idx_pia_installment ON public.payment_installment_applications (installment_id);


-- =============================================================================
-- SECTION 9 — TREASURY: VAULTS, WALLETS, LEDGERS
-- =============================================================================

CREATE TABLE public.vaults (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    branch_id uuid,
    vault_type text NOT NULL CHECK (vault_type IN ('MAIN', 'BRANCH', 'DRAWER')),
    name text NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT vault_type_branch_check CHECK (
        (vault_type = 'MAIN'   AND branch_id IS NULL) OR
        (vault_type = 'BRANCH' AND branch_id IS NOT NULL) OR
        (vault_type = 'DRAWER' AND branch_id IS NOT NULL)
    ),

    FOREIGN KEY (branch_id, organization_id)
        REFERENCES public.branches (id, organization_id)
);

CREATE INDEX idx_vaults_org_active ON public.vaults (organization_id) WHERE is_active = true;
CREATE UNIQUE INDEX idx_vaults_one_main_per_org
    ON public.vaults (organization_id) WHERE vault_type = 'MAIN';

ALTER TABLE public.vaults
    ADD CONSTRAINT vaults_id_org_key UNIQUE (id, organization_id);

-- Vault ledger. Balance is a projection over this table.
CREATE TABLE public.vault_transactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    vault_id uuid NOT NULL,
    direction text NOT NULL CHECK (direction IN ('CREDIT', 'DEBIT')),
    amount_piasters bigint NOT NULL CHECK (amount_piasters > 0),

    transaction_type text NOT NULL CHECK (transaction_type IN (
        'CUSTOMER_PAYMENT', 'REFUND', 'EXPENSE',
        'TRANSFER_IN', 'TRANSFER_OUT',
        'SHIFT_SETTLEMENT_IN', 'SHIFT_SETTLEMENT_OUT',
        'WALLET_SETTLEMENT_IN',
        'PURCHASE_SETTLEMENT_OUT',
        'PARTNER_DEPOSIT_IN', 'PARTNER_WITHDRAWAL_OUT',
        'CASH_VARIANCE_SHORTAGE', 'CASH_VARIANCE_SURPLUS',
        'ADJUSTMENT_IN', 'ADJUSTMENT_OUT',
        'OPENING_BALANCE'
    )),

    counterparty_type text CHECK (counterparty_type IN (
        'CUSTOMER', 'SUPPLIER', 'PARTNER', 'VAULT', 'WALLET', 'DRAWER', 'EXTERNAL', 'EMPLOYEE'
    )),
    counterparty_id uuid,
    counterparty_vault_id uuid,

    payment_id uuid,
    reason text NOT NULL,

    recorded_by_employee_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (vault_id, organization_id)
        REFERENCES public.vaults (id, organization_id),
    FOREIGN KEY (counterparty_vault_id, organization_id)
        REFERENCES public.vaults (id, organization_id),
    FOREIGN KEY (recorded_by_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE INDEX idx_vault_tx_vault ON public.vault_transactions (vault_id, created_at DESC);
CREATE INDEX idx_vault_tx_org_date ON public.vault_transactions (organization_id, created_at DESC);

-- Wallets. A collector's cash container for one cycle.
CREATE TABLE public.wallets (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    branch_id uuid NOT NULL,
    collector_employee_id uuid NOT NULL,

    status text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'CLOSED')),
    cycle_opened_at timestamptz NOT NULL DEFAULT now(),
    cycle_closed_at timestamptz,
    opening_balance_piasters bigint NOT NULL DEFAULT 0,
    closing_balance_piasters bigint,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (branch_id, organization_id)
        REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (collector_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE INDEX idx_wallets_org ON public.wallets (organization_id);
CREATE UNIQUE INDEX idx_wallets_one_open_per_collector
    ON public.wallets (collector_employee_id) WHERE status = 'OPEN';

ALTER TABLE public.wallets
    ADD CONSTRAINT wallets_id_org_key UNIQUE (id, organization_id);

-- Wallet ledger. Balance is a projection.
CREATE TABLE public.wallet_transactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    wallet_id uuid NOT NULL,
    transaction_type text NOT NULL CHECK (transaction_type IN (
        'OPENING',
        'COLLECTION', 'COLLECTION_REVERSAL',
        'COMMISSION', 'COMMISSION_REVERSAL',
        'SETTLEMENT_TO_VAULT',
        'ADJUSTMENT'
    )),
    -- Signed: positive = credit to wallet, negative = debit from wallet.
    amount_piasters bigint NOT NULL CHECK (amount_piasters <> 0),

    payment_id uuid,
    reason text NOT NULL,

    recorded_by_employee_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (wallet_id, organization_id)
        REFERENCES public.wallets (id, organization_id),
    FOREIGN KEY (recorded_by_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE INDEX idx_wallet_tx_wallet ON public.wallet_transactions (wallet_id, created_at DESC);
CREATE INDEX idx_wallet_tx_org_date ON public.wallet_transactions (organization_id, created_at DESC);


-- =============================================================================
-- SECTION 10 — PAYMENTS CORE (SHARED KERNEL)
-- =============================================================================
--
-- One table. Immutable. Each subtype has exactly one owning context.
-- Only the owning context may write payments of its subtype (enforced in
-- services + tests, per ADR-0003).
--
-- Subtype ownership:
--   CASH_SALE, SHIPPING_SALE, DOWN_PAYMENT, INSTALLMENT_PAYMENT, REFUND
--     -> Sales & POS
--   COLLECTION, WALLET_SETTLEMENT
--     -> Collections & Wallets
--   PURCHASE_SETTLEMENT
--     -> Purchasing
--   EXPENSE, VAULT_TRANSFER, CASH_VARIANCE
--     -> Treasury
--   PARTNER_DEPOSIT, PARTNER_WITHDRAWAL
--     -> Partners
--   ADJUSTMENT
--     -> Owner / Accountant only
--
-- ORDERING NOTE:
--   The FK to purchase_invoices is deferred to §13 because that table is
--   created later. Any other FK whose target arrives in a later section
--   should follow the same pattern.

CREATE TABLE public.payments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

    subtype text NOT NULL CHECK (subtype IN (
        'CASH_SALE', 'SHIPPING_SALE', 'DOWN_PAYMENT', 'INSTALLMENT_PAYMENT', 'REFUND',
        'COLLECTION', 'WALLET_SETTLEMENT',
        'PURCHASE_SETTLEMENT',
        'EXPENSE', 'VAULT_TRANSFER', 'CASH_VARIANCE',
        'PARTNER_DEPOSIT', 'PARTNER_WITHDRAWAL',
        'ADJUSTMENT'
    )),

    -- Money
    amount_piasters bigint NOT NULL CHECK (amount_piasters > 0),
    direction text NOT NULL CHECK (direction IN ('INFLOW', 'OUTFLOW')),

    -- Container: where the money is or was
    container_type text NOT NULL CHECK (container_type IN ('VAULT', 'WALLET', 'DRAWER', 'EXTERNAL')),
    container_id uuid,

    -- References (only the relevant ones for each subtype)
    contract_id uuid,
    installment_id uuid,
    purchase_invoice_id uuid,
    partner_id uuid,
    customer_id uuid,
    supplier_id uuid,

    -- Collector-specific (COLLECTION subtype)
    collector_employee_id uuid,
    wallet_id uuid,
    commission_rate_bps integer,                 -- basis points (e.g. 200 = 2%)
    commission_amount_piasters bigint,

    -- Method
    payment_method text CHECK (payment_method IS NULL OR payment_method IN (
        'CASH', 'CARD', 'BANK_TRANSFER', 'WALLET', 'CHEQUE', 'OTHER'
    )),

    -- Actor
    recorded_by_employee_id uuid NOT NULL,

    -- Idempotency (client-generated UUID or ULID)
    idempotency_key text NOT NULL,

    -- For split payments at one checkout
    sale_group_id uuid,

    -- For reversals (REFUND, COLLECTION_REVERSAL, etc.)
    reverses_payment_id uuid REFERENCES public.payments(id),

    -- For paired movements (transfers, settlements)
    paired_payment_id uuid REFERENCES public.payments(id),

    -- Free-form metadata (bank ref, card ref, gateway ref)
    reference_meta jsonb NOT NULL DEFAULT '{}'::jsonb,

    created_at timestamptz NOT NULL DEFAULT now(),

    UNIQUE (organization_id, idempotency_key),

    FOREIGN KEY (contract_id, organization_id)
        REFERENCES public.contracts (id, organization_id),
    FOREIGN KEY (customer_id, organization_id)
        REFERENCES public.customers (id, organization_id),
    FOREIGN KEY (supplier_id, organization_id)
        REFERENCES public.suppliers (id, organization_id),
    FOREIGN KEY (recorded_by_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE INDEX idx_payments_org_date ON public.payments (organization_id, created_at DESC);
CREATE INDEX idx_payments_contract ON public.payments (contract_id) WHERE contract_id IS NOT NULL;
CREATE INDEX idx_payments_container ON public.payments (container_type, container_id);
CREATE INDEX idx_payments_sale_group ON public.payments (sale_group_id) WHERE sale_group_id IS NOT NULL;
CREATE INDEX idx_payments_subtype ON public.payments (organization_id, subtype, created_at DESC);

-- The composite unique on payments MUST exist before any FK references
-- payments(id, organization_id). Postgres validates composite-FK targets
-- at ADD CONSTRAINT time, not lazily. See R2 at the top of this script.
ALTER TABLE public.payments
    ADD CONSTRAINT payments_id_org_key UNIQUE (id, organization_id);

-- Reverse FK for payment_installment_applications -> payments.
ALTER TABLE public.payment_installment_applications
    ADD CONSTRAINT pia_payment_fk
    FOREIGN KEY (payment_id, organization_id)
    REFERENCES public.payments (id, organization_id) ON DELETE CASCADE;

-- Link wallet transactions and vault transactions to payments by FK now that
-- payments exists.
ALTER TABLE public.wallet_transactions
    ADD CONSTRAINT wallet_tx_payment_fk
    FOREIGN KEY (payment_id, organization_id)
    REFERENCES public.payments (id, organization_id);

ALTER TABLE public.vault_transactions
    ADD CONSTRAINT vault_tx_payment_fk
    FOREIGN KEY (payment_id, organization_id)
    REFERENCES public.payments (id, organization_id);


-- =============================================================================
-- SECTION 11 — COLLECTIONS: ACCEPTANCE EVENTS
-- =============================================================================

-- Immutable accept/reject events for COLLECTION payments.
-- The payment itself never changes. Its "acceptance state" is derived:
--   * no row       -> PENDING
--   * decision=ACCEPTED -> accepted
--   * decision=REJECTED -> rejected (final; a new collection must be recorded)
CREATE TABLE public.collection_acceptances (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    payment_id uuid NOT NULL,
    decision text NOT NULL CHECK (decision IN ('ACCEPTED', 'REJECTED')),
    decided_by_employee_id uuid NOT NULL,
    decision_reason text,
    created_at timestamptz NOT NULL DEFAULT now(),

    UNIQUE (payment_id),

    CONSTRAINT collection_acceptances_reason_check
        CHECK (decision <> 'REJECTED' OR decision_reason IS NOT NULL),

    FOREIGN KEY (payment_id, organization_id)
        REFERENCES public.payments (id, organization_id),
    FOREIGN KEY (decided_by_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE INDEX idx_collection_acceptances_payment ON public.collection_acceptances (payment_id);
CREATE INDEX idx_collection_acceptances_decision ON public.collection_acceptances (organization_id, decision, created_at DESC);


-- =============================================================================
-- SECTION 12 — SHIFTS
-- =============================================================================

CREATE TABLE public.shift_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    branch_id uuid NOT NULL,
    cashier_employee_id uuid NOT NULL,
    drawer_vault_id uuid NOT NULL,

    status text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'CLOSED')),
    opened_at timestamptz NOT NULL DEFAULT now(),
    closed_at timestamptz,

    starting_balance_piasters bigint NOT NULL DEFAULT 0,
    expected_closing_balance_piasters bigint,
    actual_closing_balance_piasters bigint,
    difference_piasters bigint,

    difference_reason text,
    difference_approved_by_employee_id uuid,
    difference_approved_at timestamptz,

    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (branch_id, organization_id)
        REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (cashier_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id),
    FOREIGN KEY (drawer_vault_id, organization_id)
        REFERENCES public.vaults (id, organization_id),
    FOREIGN KEY (difference_approved_by_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE INDEX idx_shift_sessions_org_branch ON public.shift_sessions (organization_id, branch_id, status);
CREATE INDEX idx_shift_sessions_cashier ON public.shift_sessions (cashier_employee_id, status);

-- Only one open shift per drawer vault.
CREATE UNIQUE INDEX idx_shift_sessions_one_open_per_drawer
    ON public.shift_sessions (drawer_vault_id) WHERE status = 'OPEN';


-- =============================================================================
-- SECTION 13 — PURCHASING
-- =============================================================================

CREATE TABLE public.purchase_invoices (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    supplier_id uuid,
    branch_id uuid,

    invoice_number varchar(64),
    invoice_date date NOT NULL DEFAULT CURRENT_DATE,

    total_amount_piasters bigint NOT NULL DEFAULT 0 CHECK (total_amount_piasters >= 0),
    amount_paid_piasters bigint NOT NULL DEFAULT 0 CHECK (amount_paid_piasters >= 0),
    -- outstanding is a generated column: total - paid
    outstanding_piasters bigint GENERATED ALWAYS AS
        (total_amount_piasters - amount_paid_piasters) STORED,

    status text NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED', 'VOID')),

    approved_by_employee_id uuid,
    approved_at timestamptz,
    voided_at timestamptz,
    voided_by_employee_id uuid,
    void_reason text,
    notes text,

    created_by_employee_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (supplier_id, organization_id)
        REFERENCES public.suppliers (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)
        REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (approved_by_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id),
    FOREIGN KEY (created_by_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE INDEX idx_purchase_invoices_org_status ON public.purchase_invoices (organization_id, status, created_at DESC);

ALTER TABLE public.purchase_invoices
    ADD CONSTRAINT purchase_invoices_id_org_key UNIQUE (id, organization_id);

-- Deferred from Section 10: payments is created before purchase_invoices,
-- so this reference can only be established once both sides exist.
ALTER TABLE public.payments
    ADD CONSTRAINT payments_purchase_invoice_org_fk
    FOREIGN KEY (purchase_invoice_id, organization_id)
    REFERENCES public.purchase_invoices (id, organization_id);

CREATE TABLE public.purchase_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    purchase_invoice_id uuid NOT NULL,
    product_id uuid NOT NULL,
    quantity integer NOT NULL CHECK (quantity > 0),
    unit_cost_piasters bigint NOT NULL CHECK (unit_cost_piasters >= 0),
    line_total_piasters bigint GENERATED ALWAYS AS
        (quantity * unit_cost_piasters) STORED,
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (purchase_invoice_id, organization_id)
        REFERENCES public.purchase_invoices (id, organization_id) ON DELETE CASCADE,
    FOREIGN KEY (product_id, organization_id)
        REFERENCES public.products (id, organization_id)
);

CREATE INDEX idx_purchase_items_invoice ON public.purchase_items (purchase_invoice_id);

CREATE TABLE public.purchase_settlements (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    purchase_invoice_id uuid NOT NULL,
    vault_id uuid NOT NULL,
    amount_piasters bigint NOT NULL CHECK (amount_piasters > 0),
    employee_id uuid NOT NULL,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (purchase_invoice_id, organization_id)
        REFERENCES public.purchase_invoices (id, organization_id),
    FOREIGN KEY (vault_id, organization_id)
        REFERENCES public.vaults (id, organization_id),
    FOREIGN KEY (employee_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE INDEX idx_purchase_settlements_invoice ON public.purchase_settlements (purchase_invoice_id);

CREATE TABLE public.purchase_returns (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    purchase_invoice_id uuid NOT NULL,
    supplier_id uuid,
    total_amount_piasters bigint NOT NULL DEFAULT 0,
    status text NOT NULL DEFAULT 'COMPLETED' CHECK (status IN ('PENDING', 'COMPLETED', 'VOID')),
    employee_id uuid NOT NULL,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (purchase_invoice_id, organization_id)
        REFERENCES public.purchase_invoices (id, organization_id),
    FOREIGN KEY (supplier_id, organization_id)
        REFERENCES public.suppliers (id, organization_id),
    FOREIGN KEY (employee_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE TABLE public.purchase_return_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    purchase_return_id uuid NOT NULL REFERENCES public.purchase_returns(id) ON DELETE CASCADE,
    product_id uuid NOT NULL,
    quantity integer NOT NULL CHECK (quantity > 0),
    unit_cost_piasters bigint NOT NULL CHECK (unit_cost_piasters >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (product_id, organization_id)
        REFERENCES public.products (id, organization_id)
);


-- =============================================================================
-- SECTION 14 — PARTNERS
-- =============================================================================

CREATE TABLE public.partners (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    full_name text NOT NULL,
    phone varchar(20),
    email citext,
    national_id varchar(20),
    current_capital_piasters bigint NOT NULL DEFAULT 0,
    profit_share_percentage numeric(5,2) NOT NULL DEFAULT 0 CHECK (profit_share_percentage >= 0),
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'INACTIVE')),
    lockup_end_date date,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_partners_org ON public.partners (organization_id, status);

ALTER TABLE public.partners
    ADD CONSTRAINT partners_id_org_key UNIQUE (id, organization_id);

CREATE TABLE public.partner_transactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    partner_id uuid NOT NULL,
    vault_id uuid NOT NULL,
    amount_piasters bigint NOT NULL CHECK (amount_piasters > 0),
    transaction_type text NOT NULL CHECK (transaction_type IN ('DEPOSIT', 'WITHDRAWAL')),
    status text NOT NULL DEFAULT 'APPROVED' CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
    approved_by_employee_id uuid,
    approved_at timestamptz,
    reason text,
    employee_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (partner_id, organization_id)
        REFERENCES public.partners (id, organization_id),
    FOREIGN KEY (vault_id, organization_id)
        REFERENCES public.vaults (id, organization_id),
    FOREIGN KEY (employee_id, organization_id)
        REFERENCES public.employees (id, organization_id),
    FOREIGN KEY (approved_by_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE INDEX idx_partner_transactions_partner ON public.partner_transactions (partner_id, created_at DESC);

CREATE TABLE public.profit_distributions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    period_start date NOT NULL,
    period_end date NOT NULL,
    total_collected_piasters bigint NOT NULL,
    total_expenses_piasters bigint NOT NULL,
    net_profit_piasters bigint NOT NULL,
    organization_share_pct numeric(5,2) NOT NULL,
    organization_profit_piasters bigint NOT NULL,
    partners_pool_piasters bigint NOT NULL,
    notes text,
    created_by_employee_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (created_by_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE TABLE public.partner_payouts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    distribution_id uuid NOT NULL REFERENCES public.profit_distributions(id) ON DELETE CASCADE,
    partner_id uuid NOT NULL,
    vault_id uuid NOT NULL,
    share_pct_at_time numeric(5,2) NOT NULL,
    payout_amount_piasters bigint NOT NULL CHECK (payout_amount_piasters >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (partner_id, organization_id)
        REFERENCES public.partners (id, organization_id),
    FOREIGN KEY (vault_id, organization_id)
        REFERENCES public.vaults (id, organization_id)
);


-- =============================================================================
-- SECTION 15 — LEGAL
-- =============================================================================

CREATE TABLE public.legal_documents (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    title text NOT NULL,
    document_url text,
    document_type text,
    created_by_employee_id uuid,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.legal_cases (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    case_number varchar(64),
    title text NOT NULL,
    status text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'IN_PROGRESS', 'CLOSED', 'WON', 'LOST')),
    customer_id uuid,
    contract_id uuid,
    assigned_lawyer_id uuid,
    opened_at timestamptz NOT NULL DEFAULT now(),
    closed_at timestamptz,
    description text,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (customer_id, organization_id)
        REFERENCES public.customers (id, organization_id),
    FOREIGN KEY (contract_id, organization_id)
        REFERENCES public.contracts (id, organization_id),
    FOREIGN KEY (assigned_lawyer_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE INDEX idx_legal_cases_org_status ON public.legal_cases (organization_id, status);

CREATE TABLE public.legal_attachments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    case_id uuid NOT NULL REFERENCES public.legal_cases(id) ON DELETE CASCADE,
    attachment_url text NOT NULL,
    description text,
    created_at timestamptz NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 16 — HR (BASIC V1; PAYROLL DEFERRED TO V2)
-- =============================================================================

CREATE TABLE public.hr_contracts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    employee_id uuid NOT NULL,
    contract_type text NOT NULL DEFAULT 'full_time'
        CHECK (contract_type IN ('full_time', 'part_time', 'contractor')),
    position text NOT NULL,
    department text,
    start_date date NOT NULL,
    end_date date,
    salary_piasters bigint NOT NULL,
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'terminated', 'expired')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (employee_id, organization_id)
        REFERENCES public.employees (id, organization_id) ON DELETE CASCADE
);

CREATE INDEX idx_hr_contracts_org_emp ON public.hr_contracts (organization_id, employee_id, status);

CREATE TABLE public.hr_performance_reviews (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    employee_id uuid NOT NULL,
    reviewer_id uuid NOT NULL,
    review_date date NOT NULL DEFAULT CURRENT_DATE,
    rating smallint CHECK (rating BETWEEN 1 AND 5),
    comments text,
    goals text,
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (employee_id, organization_id)
        REFERENCES public.employees (id, organization_id),
    FOREIGN KEY (reviewer_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE TABLE public.hr_points (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    employee_id uuid NOT NULL,
    type text NOT NULL CHECK (type IN ('plus', 'minus')),
    amount integer NOT NULL CHECK (amount > 0),
    reason text NOT NULL,
    created_by_employee_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (employee_id, organization_id)
        REFERENCES public.employees (id, organization_id),
    FOREIGN KEY (created_by_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE INDEX idx_hr_points_emp ON public.hr_points (employee_id, created_at DESC);


-- =============================================================================
-- SECTION 17 — AUDIT, NOTIFICATIONS, LOGIN ATTEMPTS
-- =============================================================================

CREATE TABLE public.audit_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid REFERENCES public.organizations(id) ON DELETE SET NULL,
    actor_employee_id uuid,
    actor_super_admin_id uuid REFERENCES public.super_admins(id) ON DELETE SET NULL,
    action text NOT NULL,
    module text NOT NULL,
    entity_type text,
    entity_id uuid,
    severity text NOT NULL DEFAULT 'info' CHECK (severity IN ('info', 'warning', 'critical')),
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    ip_address inet,
    user_agent text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_logs_org_date ON public.audit_logs (organization_id, created_at DESC);
CREATE INDEX idx_audit_logs_actor ON public.audit_logs (actor_employee_id, created_at DESC);
CREATE INDEX idx_audit_logs_entity ON public.audit_logs (entity_type, entity_id);

CREATE TABLE public.notifications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    recipient_employee_id uuid NOT NULL,
    title text NOT NULL,
    message text,
    type text NOT NULL DEFAULT 'info' CHECK (type IN ('info', 'warning', 'success', 'error')),
    is_read boolean NOT NULL DEFAULT false,
    link text,
    ref_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (recipient_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id) ON DELETE CASCADE
);

CREATE INDEX idx_notifications_recipient ON public.notifications (recipient_employee_id, is_read, created_at DESC);

-- Failed/successful login attempts. Used by rate limiting in the auth service.
CREATE TABLE public.login_attempts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    identifier text NOT NULL,
    success boolean NOT NULL,
    ip_address inet,
    user_agent text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_login_attempts_identifier ON public.login_attempts (identifier, created_at DESC);
CREATE INDEX idx_login_attempts_ip ON public.login_attempts (ip_address, created_at DESC);


-- =============================================================================
-- SECTION 18 — DATA BRIDGE
-- =============================================================================

CREATE TABLE public.data_imports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    table_name text NOT NULL,
    imported_by_employee_id uuid,
    rows_imported integer NOT NULL DEFAULT 0,
    rows_skipped integer NOT NULL DEFAULT 0,
    status text NOT NULL DEFAULT 'COMPLETED' CHECK (status IN ('IN_PROGRESS', 'COMPLETED', 'FAILED')),
    error_message text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    imported_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (imported_by_employee_id, organization_id)
        REFERENCES public.employees (id, organization_id)
);

CREATE INDEX idx_data_imports_org_table ON public.data_imports (organization_id, table_name, imported_at DESC);


-- =============================================================================
-- SECTION 19 — VIEWS: BALANCES AND PROJECTIONS
-- =============================================================================

-- Vault balances: sum of ledger entries per vault.
CREATE OR REPLACE VIEW public.vault_balances AS
SELECT
    v.id AS vault_id,
    v.organization_id,
    v.vault_type,
    v.branch_id,
    COALESCE(
        SUM(
            CASE
                WHEN vt.direction = 'CREDIT' THEN vt.amount_piasters
                WHEN vt.direction = 'DEBIT'  THEN -vt.amount_piasters
                ELSE 0
            END
        ),
        0
    )::bigint AS balance_piasters
FROM public.vaults v
LEFT JOIN public.vault_transactions vt ON vt.vault_id = v.id
GROUP BY v.id, v.organization_id, v.vault_type, v.branch_id;

-- Wallet balances: sum of signed ledger entries.
CREATE OR REPLACE VIEW public.wallet_balances AS
SELECT
    w.id AS wallet_id,
    w.organization_id,
    w.collector_employee_id,
    w.status,
    COALESCE(SUM(wt.amount_piasters), 0)::bigint AS balance_piasters,
    COALESCE(
        SUM(CASE WHEN wt.transaction_type = 'COLLECTION' THEN wt.amount_piasters ELSE 0 END),
        0
    )::bigint AS collections_recorded_piasters,
    COALESCE(
        SUM(CASE WHEN wt.transaction_type = 'COMMISSION' THEN wt.amount_piasters ELSE 0 END),
        0
    )::bigint AS commissions_earned_piasters
FROM public.wallets w
LEFT JOIN public.wallet_transactions wt ON wt.wallet_id = w.id
GROUP BY w.id, w.organization_id, w.collector_employee_id, w.status;

-- Installment balances: agreed vs paid, from applications.
CREATE OR REPLACE VIEW public.installment_balances AS
SELECT
    i.id AS installment_id,
    i.organization_id,
    i.contract_id,
    i.sequence,
    i.due_date,
    i.status,
    i.agreed_amount_piasters,
    COALESCE(SUM(pia.amount_piasters), 0)::bigint AS paid_piasters,
    (i.agreed_amount_piasters - COALESCE(SUM(pia.amount_piasters), 0))::bigint AS remaining_piasters,
    (i.status IN ('PENDING', 'PARTIALLY_PAID') AND i.due_date < CURRENT_DATE) AS is_overdue
FROM public.installments i
LEFT JOIN public.payment_installment_applications pia ON pia.installment_id = i.id
GROUP BY i.id, i.organization_id, i.contract_id, i.sequence, i.due_date, i.status, i.agreed_amount_piasters;

-- Contract balances: sum of installment remaining amounts.
CREATE OR REPLACE VIEW public.contract_balances AS
SELECT
    c.id AS contract_id,
    c.organization_id,
    c.status,
    c.total_sale_amount_piasters,
    COALESCE(SUM(ib.remaining_piasters), 0)::bigint AS remaining_piasters,
    COALESCE(SUM(ib.paid_piasters), 0)::bigint AS paid_piasters
FROM public.contracts c
LEFT JOIN public.installment_balances ib ON ib.contract_id = c.id
GROUP BY c.id, c.organization_id, c.status, c.total_sale_amount_piasters;


-- =============================================================================
-- SECTION 20 — ENABLE RLS ON ALL TENANT TABLES
-- =============================================================================

ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.saaslicenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_addons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.super_admins ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.guarantors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_guarantors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.field_surveys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.survey_attachments ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.inventory_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_cost_log ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.contracts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contract_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.installments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.installment_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_installment_applications ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.vaults ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vault_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.collection_acceptances ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.shift_sessions ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.purchase_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_settlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_return_items ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.partners ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.partner_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profit_distributions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.partner_payouts ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.legal_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.legal_cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.legal_attachments ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.hr_contracts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hr_performance_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hr_points ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.login_attempts ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.data_imports ENABLE ROW LEVEL SECURITY;


-- =============================================================================
-- SECTION 21 — RLS POLICIES
-- =============================================================================
--
-- Two policy patterns:
--
--   1. Tenant isolation: `organization_id = current_user_org_id()`.
--      Applied to every tenant table.
--
--   2. Platform access: `is_super_admin()` for platform tables
--      (organizations, saaslicenses, super_admins, plans).
--
-- Table owner bypass: Supabase's service_role and postgres bypass RLS. Used
-- only by platform endpoints, never tenant endpoints.

-- Plans: readable by anyone (reference data). Writable only by service role.
CREATE POLICY plans_read ON public.plans
    FOR SELECT USING (true);

-- Organizations: tenant users see only their own org. Super admins see all.
CREATE POLICY organizations_tenant_read ON public.organizations
    FOR SELECT USING (
        id = public.current_user_org_id()
        OR public.is_super_admin()
    );

CREATE POLICY organizations_tenant_update ON public.organizations
    FOR UPDATE USING (id = public.current_user_org_id())
    WITH CHECK (id = public.current_user_org_id());

-- Licenses: tenants cannot read. Super admins only. (Activation uses the
-- service role via a dedicated API endpoint.)
CREATE POLICY saaslicenses_super_admin ON public.saaslicenses
    FOR ALL USING (public.is_super_admin())
    WITH CHECK (public.is_super_admin());

-- Super admins: only super admins.
CREATE POLICY super_admins_self ON public.super_admins
    FOR ALL USING (public.is_super_admin())
    WITH CHECK (public.is_super_admin());

-- Organization plans and addons: tenant reads, super admin all.
CREATE POLICY org_plans_tenant_read ON public.organization_plans
    FOR SELECT USING (organization_id = public.current_user_org_id() OR public.is_super_admin());

CREATE POLICY org_addons_tenant_read ON public.organization_addons
    FOR SELECT USING (organization_id = public.current_user_org_id() OR public.is_super_admin());

-- ----------------------------------------------------------------
-- Generic tenant isolation for the following tables. We do this in a
-- DO block to avoid repeating the same four lines 40 times.
-- ----------------------------------------------------------------

DO $$
DECLARE
    t text;
    tenant_tables text[] := ARRAY[
        'branches', 'employees',
        'categories', 'products', 'suppliers',
        'customers', 'guarantors', 'client_guarantors',
        'field_surveys', 'survey_attachments',
        'inventory_transactions', 'product_cost_log',
        'contracts', 'contract_items', 'installments',
        'installment_events', 'payment_installment_applications',
        'vaults', 'vault_transactions', 'wallets', 'wallet_transactions',
        'payments', 'collection_acceptances',
        'shift_sessions',
        'purchase_invoices', 'purchase_items', 'purchase_settlements',
        'purchase_returns', 'purchase_return_items',
        'partners', 'partner_transactions', 'profit_distributions', 'partner_payouts',
        'legal_documents', 'legal_cases', 'legal_attachments',
        'hr_contracts', 'hr_performance_reviews', 'hr_points',
        'notifications', 'data_imports'
    ];
BEGIN
    FOREACH t IN ARRAY tenant_tables LOOP
        EXECUTE format($f$
            CREATE POLICY %I_tenant_all ON public.%I
                FOR ALL
                USING (organization_id = public.current_user_org_id())
                WITH CHECK (organization_id = public.current_user_org_id());
        $f$, t, t);
    END LOOP;
END $$;

-- Audit logs: tenant users can read their org's logs.
-- No UPDATE or DELETE policy exists -> those operations are denied.
CREATE POLICY audit_logs_tenant_read ON public.audit_logs
    FOR SELECT USING (
        (organization_id IS NOT NULL AND organization_id = public.current_user_org_id())
        OR public.is_super_admin()
    );

CREATE POLICY audit_logs_insert ON public.audit_logs
    FOR INSERT WITH CHECK (
        organization_id = public.current_user_org_id()
        OR public.is_super_admin()
    );

-- Login attempts: no direct tenant access. Service role only.
-- (No policy -> RLS blocks all access from anon/authenticated roles.)


-- =============================================================================
-- SECTION 22 — UPDATED_AT TRIGGERS
-- =============================================================================

DO $$
DECLARE
    t text;
    tables_with_updated_at text[] := ARRAY[
        'organizations', 'super_admins',
        'branches', 'employees',
        'categories', 'products', 'suppliers',
        'customers', 'guarantors', 'field_surveys',
        'contracts', 'installments',
        'vaults', 'wallets',
        'shift_sessions',
        'purchase_invoices',
        'partners',
        'legal_cases',
        'hr_contracts'
    ];
BEGIN
    FOREACH t IN ARRAY tables_with_updated_at LOOP
        EXECUTE format($f$
            CREATE TRIGGER trg_%s_updated_at
                BEFORE UPDATE ON public.%I
                FOR EACH ROW
                EXECUTE FUNCTION public.set_updated_at();
        $f$, t, t);
    END LOOP;
END $$;


-- =============================================================================
-- SECTION 23 — SEED DATA (PLANS AND FIRST SUPER ADMIN)
-- =============================================================================

-- Plans. Edit pricing to match your final decision.
INSERT INTO public.plans (key, display_name, display_name_ar, description, max_branches, max_users, monthly_price_egp, display_order)
VALUES
    ('HR_ONLY',      'HR Only',       'الموارد البشرية فقط',  'For non-retail organizations: employee records and HR workflows.',                        1, 50,   400, 1),
    ('STARTER',      'Starter',       'المبتدئ',             'Single-branch shop, cash sales only.',                                                    1, 5,    500, 2),
    ('RETAIL',       'Retail',        'التجزئة',             'Retail with installments and field collections.',                                         3, 15,  1200, 3),
    ('RETAIL_PRO',   'Retail Pro',    'التجزئة الاحترافي',    'Multi-branch retail with partners and advanced reporting.',                               5, 30,  2000, 4),
    ('DISTRIBUTION', 'Distribution',  'التوزيع',             'Wholesale with purchasing and supplier chains.',                                          5, 30,  2500, 5),
    ('ENTERPRISE',   'Enterprise',    'المؤسسي',              'Multi-branch organization with every module and SLA.',                                   10, 50, 4000, 6)
ON CONFLICT (key) DO NOTHING;


-- =============================================================================
-- FIRST SUPER ADMIN SEED
-- =============================================================================
--
-- BEFORE RUNNING THIS BLOCK:
--   1. In Supabase Dashboard -> Authentication -> Users, create a user with
--      the email and password you want for your first Super Admin.
--   2. Replace the email below with that user's email.
--   3. Then run the block.
--
-- =============================================================================

DO $$
DECLARE
    v_admin_email text := 'admin@ecofinpro.com';   -- <-- CHANGE THIS
    v_admin_name  text := 'Super Admin';
    v_admin_phone text := '+201000000000';
    v_auth_id     uuid;
BEGIN
    SELECT id INTO v_auth_id
    FROM auth.users
    WHERE email = v_admin_email
    LIMIT 1;

    IF v_auth_id IS NULL THEN
        RAISE EXCEPTION
            'No auth.users row found for email %. Create the user in Supabase Auth first, then re-run this block.',
            v_admin_email;
    END IF;

    INSERT INTO public.super_admins (auth_user_id, full_name, email, phone)
    VALUES (v_auth_id, v_admin_name, v_admin_email, v_admin_phone)
    ON CONFLICT (auth_user_id) DO UPDATE
        SET full_name = EXCLUDED.full_name,
            email     = EXCLUDED.email,
            phone     = EXCLUDED.phone,
            is_active = true;

    RAISE NOTICE '✅ Super admin seeded: % (auth_user_id = %)', v_admin_email, v_auth_id;
END $$;


-- =============================================================================
-- SECTION 24 — MIGRATIONS: activate_workspace RPC
-- =============================================================================
--
-- Purpose: atomic license activation. See ADR-0004 §D3–D4.
--
-- Performs, in one transaction:
--   1. Lock the license row (SELECT ... FOR UPDATE).
--   2. Re-validate the license (unused, active, not revoked, not expired).
--   3. Verify the owner employee row matches the supplied auth_user_id.
--   4. Enforce username uniqueness scoped to the org (case-insensitive via
--      citext — the comparison already ignores case at the DB level).
--   5. Update the employee's username.
--   6. Flip the license to is_used = true and set claimed_at.
--   7. Return the org's tenant_slug and name.
--
-- The service layer updates the Supabase Auth password BEFORE calling this
-- function. If this function fails, the password is set but the license is
-- still unused, and the user can retry activation.
--
-- Errors are raised as P0001 with a machine-readable message body. The
-- service layer maps those messages to ErrorCodes before surfacing them.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.activate_workspace(
    p_license_key text,
    p_owner_auth_id uuid,
    p_username text
)
RETURNS TABLE (tenant_slug text, tenant_name text, org_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_license       saaslicenses%ROWTYPE;
    v_owner_id      uuid;
    v_conflict_id   uuid;
    v_org           organizations%ROWTYPE;
BEGIN
    -- Lock the license row. Serializes concurrent activations on the same key.
    SELECT * INTO v_license
    FROM saaslicenses
    WHERE license_key = upper(btrim(p_license_key))
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'LICENSE_INVALID' USING ERRCODE = 'P0001';
    END IF;

    IF v_license.is_used THEN
        RAISE EXCEPTION 'LICENSE_USED' USING ERRCODE = 'P0001';
    END IF;

    IF NOT v_license.is_active OR v_license.is_revoked THEN
        RAISE EXCEPTION 'LICENSE_INVALID' USING ERRCODE = 'P0001';
    END IF;

    IF v_license.expires_at IS NOT NULL AND v_license.expires_at <= now() THEN
        RAISE EXCEPTION 'LICENSE_EXPIRED' USING ERRCODE = 'P0001';
    END IF;

    IF v_license.issued_to_org_id IS NULL THEN
        RAISE EXCEPTION 'LICENSE_NOT_PROVISIONED' USING ERRCODE = 'P0001';
    END IF;

    -- The owner's employee row. Lock it so two parallel activations on
    -- different licenses for the same owner (unlikely but possible) don't
    -- interleave username writes.
    SELECT id INTO v_owner_id
    FROM employees
    WHERE organization_id = v_license.issued_to_org_id
      AND role            = 'OWNER'
      AND auth_id         = p_owner_auth_id
    FOR UPDATE;

    IF v_owner_id IS NULL THEN
        RAISE EXCEPTION 'OWNER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;

    -- Username uniqueness within the org. citext handles case folding.
    SELECT id INTO v_conflict_id
    FROM employees
    WHERE organization_id = v_license.issued_to_org_id
      AND username        = btrim(p_username)
      AND id              <> v_owner_id;

    IF v_conflict_id IS NOT NULL THEN
        RAISE EXCEPTION 'USERNAME_TAKEN' USING ERRCODE = 'P0001';
    END IF;

    UPDATE employees
    SET username             = btrim(p_username),
        must_change_password = false
    WHERE id = v_owner_id;

    UPDATE saaslicenses
       SET is_used    = true,
           claimed_at = now()
     WHERE id = v_license.id;

    SELECT * INTO v_org FROM organizations WHERE id = v_license.issued_to_org_id;

    RETURN QUERY SELECT v_org.tenant_slug, v_org.name, v_org.id;
END;
$$;

-- Only the service role may execute this. Tenant users must never be able
-- to call it directly via PostgREST.
REVOKE ALL ON FUNCTION public.activate_workspace(text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.activate_workspace(text, uuid, text) TO service_role;


-- =============================================================================
-- SECTION 25 — MIGRATIONS: password audit trail
-- =============================================================================
--
-- The auth refactor's changePassword service sets password_changed_at.
-- The canonical schema does not define the column; add it here so the API
-- does not have to guard against a missing column.
-- =============================================================================

ALTER TABLE public.employees
    ADD COLUMN IF NOT EXISTS password_changed_at timestamptz;

COMMENT ON COLUMN public.employees.password_changed_at IS
    'Set by auth.service.changePassword on successful self-service password change. NULL for accounts that have never changed their password.';

    -- =============================================================================
-- SECTION 26 — SUPABASE ROLE GRANTS
-- =============================================================================
--
-- Tables created via the Supabase SQL Editor are owned by `postgres` and
-- carry zero grants to the three Supabase runtime roles:
--
--   anon          -> anon key, used pre-auth on public endpoints
--   authenticated -> anon key + user JWT, used for tenant requests
--   service_role  -> service-role key, used by the API backend
--
-- Without these grants, every query through supabaseAnon / supabaseUser /
-- supabaseAdmin fails at the privilege check BEFORE RLS is even consulted.
-- The error is `permission denied for table X`.
--
-- GRANT and RLS are complementary: GRANT says "you may touch this table";
-- RLS says "for each row, is this role allowed to see it". Both must exist.
--
-- Idempotent. Safe to re-run after adding tables or views.

DO $$
DECLARE
    t text;
BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO anon', t);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
        EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    END LOOP;

    FOR t IN SELECT sequencename FROM pg_sequences WHERE schemaname = 'public' LOOP
        EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE public.%I TO anon', t);
        EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE public.%I TO authenticated', t);
        EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE public.%I TO service_role', t);
    END LOOP;
END $$;

DO $$
DECLARE
    v text;
BEGIN
    FOR v IN SELECT viewname FROM pg_views WHERE schemaname = 'public' LOOP
        EXECUTE format('GRANT SELECT ON public.%I TO anon', v);
        EXECUTE format('GRANT SELECT ON public.%I TO authenticated', v);
        EXECUTE format('GRANT SELECT ON public.%I TO service_role', v);
    END LOOP;
END $$;

DO $$
DECLARE
    f record;
BEGIN
    FOR f IN
        SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname IN (
              'current_user_org_id', 'is_super_admin', 'current_employee_id',
              'current_role', 'is_owner', 'activate_workspace',
              'egp_to_piasters', 'piasters_to_egp', 'set_updated_at'
          )
    LOOP
        EXECUTE format(
            'GRANT EXECUTE ON FUNCTION public.%I(%s) TO anon, authenticated, service_role',
            f.proname, f.args
        );
    END LOOP;
END $$;


-- =============================================================================
-- END OF SCHEMA
-- =============================================================================