// GENERATED FILE - DO NOT EDIT BY HAND.
// Source: local database (supabase/migrations), schema "public".
// Regenerate after a migration change: npm run db:reset && npm run db:types

export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[];

export type Database = {
  public: {
    Tables: {
      approvals: {
        Row: {
          amount: number | null;
          branch_id: string | null;
          created_at: string;
          created_by: string | null;
          decided_at: string | null;
          decided_by: string | null;
          decision_note: string | null;
          entity_id: string | null;
          entity_type: string;
          id: string;
          kind: Database['public']['Enums']['approval_kind'];
          organization_id: string;
          payload: NonNullable<Json>;
          reason: string | null;
          requested_by: string;
          status: Database['public']['Enums']['approval_status'];
          updated_at: string;
        };
        Insert: {
          amount?: number | null;
          branch_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          decided_at?: string | null;
          decided_by?: string | null;
          decision_note?: string | null;
          entity_id?: string | null;
          entity_type: string;
          id?: string;
          kind: Database['public']['Enums']['approval_kind'];
          organization_id: string;
          payload?: NonNullable<Json>;
          reason?: string | null;
          requested_by: string;
          status?: Database['public']['Enums']['approval_status'];
          updated_at?: string;
        };
        Update: {
          amount?: number | null;
          branch_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          decided_at?: string | null;
          decided_by?: string | null;
          decision_note?: string | null;
          entity_id?: string | null;
          entity_type?: string;
          id?: string;
          kind?: Database['public']['Enums']['approval_kind'];
          organization_id?: string;
          payload?: NonNullable<Json>;
          reason?: string | null;
          requested_by?: string;
          status?: Database['public']['Enums']['approval_status'];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'approvals_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'approvals_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'approvals_decided_by_fk';
            columns: ['decided_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'approvals_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'approvals_requested_by_fk';
            columns: ['requested_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      audit_log: {
        Row: {
          action: string;
          after: Json | null;
          before: Json | null;
          branch_id: string | null;
          created_at: string;
          device_id: string | null;
          employee_id: string | null;
          entity_id: string | null;
          entity_type: string | null;
          id: number;
          ip: unknown;
          organization_id: string;
          reason: string | null;
          request_id: string | null;
          severity: Database['public']['Enums']['audit_severity'];
          super_admin_id: string | null;
          user_agent: string | null;
        };
        Insert: {
          action: string;
          after?: Json | null;
          before?: Json | null;
          branch_id?: string | null;
          created_at?: string;
          device_id?: string | null;
          employee_id?: string | null;
          entity_id?: string | null;
          entity_type?: string | null;
          id?: never;
          ip?: unknown;
          organization_id: string;
          reason?: string | null;
          request_id?: string | null;
          severity?: Database['public']['Enums']['audit_severity'];
          super_admin_id?: string | null;
          user_agent?: string | null;
        };
        Update: {
          action?: string;
          after?: Json | null;
          before?: Json | null;
          branch_id?: string | null;
          created_at?: string;
          device_id?: string | null;
          employee_id?: string | null;
          entity_id?: string | null;
          entity_type?: string | null;
          id?: never;
          ip?: unknown;
          organization_id?: string;
          reason?: string | null;
          request_id?: string | null;
          severity?: Database['public']['Enums']['audit_severity'];
          super_admin_id?: string | null;
          user_agent?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'audit_log_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'audit_log_device_id_organization_id_fkey';
            columns: ['device_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'devices';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'audit_log_employee_id_organization_id_fkey';
            columns: ['employee_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'audit_log_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'audit_log_super_admin_id_fkey';
            columns: ['super_admin_id'];
            isOneToOne: false;
            referencedRelation: 'super_admins';
            referencedColumns: ['auth_user_id'];
          },
        ];
      };
      branches: {
        Row: {
          address: string | null;
          archived_at: string | null;
          city: string | null;
          code: string;
          created_at: string;
          created_by: string | null;
          default_cash_account_id: string | null;
          eta_branch_code: string | null;
          governorate: string | null;
          id: string;
          is_active: boolean;
          is_main: boolean;
          name: string;
          organization_id: string;
          phone: string | null;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          address?: string | null;
          archived_at?: string | null;
          city?: string | null;
          code: string;
          created_at?: string;
          created_by?: string | null;
          default_cash_account_id?: string | null;
          eta_branch_code?: string | null;
          governorate?: string | null;
          id?: string;
          is_active?: boolean;
          is_main?: boolean;
          name: string;
          organization_id: string;
          phone?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          address?: string | null;
          archived_at?: string | null;
          city?: string | null;
          code?: string;
          created_at?: string;
          created_by?: string | null;
          default_cash_account_id?: string | null;
          eta_branch_code?: string | null;
          governorate?: string | null;
          id?: string;
          is_active?: boolean;
          is_main?: boolean;
          name?: string;
          organization_id?: string;
          phone?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'branches_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'branches_default_cash_account_fk';
            columns: ['default_cash_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'cash_accounts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'branches_default_cash_account_fk';
            columns: ['default_cash_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_cash_balances';
            referencedColumns: ['cash_account_id', 'organization_id'];
          },
          {
            foreignKeyName: 'branches_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'branches_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      cash_accounts: {
        Row: {
          archived_at: string | null;
          branch_id: string | null;
          created_at: string;
          created_by: string | null;
          employee_id: string | null;
          id: string;
          is_active: boolean;
          kind: Database['public']['Enums']['cash_account_kind'];
          name: string;
          organization_id: string;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          archived_at?: string | null;
          branch_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          employee_id?: string | null;
          id?: string;
          is_active?: boolean;
          kind: Database['public']['Enums']['cash_account_kind'];
          name: string;
          organization_id: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          archived_at?: string | null;
          branch_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          employee_id?: string | null;
          id?: string;
          is_active?: boolean;
          kind?: Database['public']['Enums']['cash_account_kind'];
          name?: string;
          organization_id?: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'cash_accounts_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_accounts_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_accounts_employee_id_organization_id_fkey';
            columns: ['employee_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_accounts_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'cash_accounts_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      cash_balances: {
        Row: {
          allow_negative: boolean;
          balance: number;
          cash_account_id: string;
          organization_id: string;
          updated_at: string;
        };
        Insert: {
          allow_negative?: boolean;
          balance?: number;
          cash_account_id: string;
          organization_id: string;
          updated_at?: string;
        };
        Update: {
          allow_negative?: boolean;
          balance?: number;
          cash_account_id?: string;
          organization_id?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'cash_balances_cash_account_id_organization_id_fkey';
            columns: ['cash_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'cash_accounts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_balances_cash_account_id_organization_id_fkey';
            columns: ['cash_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_cash_balances';
            referencedColumns: ['cash_account_id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_balances_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      cash_movements: {
        Row: {
          amount: number;
          branch_id: string;
          business_date: string;
          cash_account_id: string;
          created_at: string;
          created_by: string | null;
          id: string;
          note: string | null;
          organization_id: string;
          reverses_movement_id: string | null;
          shift_id: string | null;
          source_id: string;
          source_type: Database['public']['Enums']['doc_type'];
          type: Database['public']['Enums']['cash_movement_type'];
        };
        Insert: {
          amount: number;
          branch_id: string;
          business_date: string;
          cash_account_id: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          note?: string | null;
          organization_id: string;
          reverses_movement_id?: string | null;
          shift_id?: string | null;
          source_id: string;
          source_type: Database['public']['Enums']['doc_type'];
          type: Database['public']['Enums']['cash_movement_type'];
        };
        Update: {
          amount?: number;
          branch_id?: string;
          business_date?: string;
          cash_account_id?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          note?: string | null;
          organization_id?: string;
          reverses_movement_id?: string | null;
          shift_id?: string | null;
          source_id?: string;
          source_type?: Database['public']['Enums']['doc_type'];
          type?: Database['public']['Enums']['cash_movement_type'];
        };
        Relationships: [
          {
            foreignKeyName: 'cash_movements_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_movements_cash_account_id_organization_id_fkey';
            columns: ['cash_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'cash_accounts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_movements_cash_account_id_organization_id_fkey';
            columns: ['cash_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_cash_balances';
            referencedColumns: ['cash_account_id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_movements_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_movements_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'cash_movements_reverses_movement_id_organization_id_fkey';
            columns: ['reverses_movement_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'cash_movements';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_movements_shift_id_organization_id_fkey';
            columns: ['shift_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'shifts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_movements_shift_id_organization_id_fkey';
            columns: ['shift_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_shift_expected_cash';
            referencedColumns: ['shift_id', 'organization_id'];
          },
        ];
      };
      cash_transfers: {
        Row: {
          amount: number;
          business_date: string;
          created_at: string;
          created_by: string | null;
          from_account_id: string;
          id: string;
          idempotency_key: string;
          kind: Database['public']['Enums']['cash_transfer_kind'];
          number: string;
          organization_id: string;
          reason: string | null;
          shortage_amount: number;
          to_account_id: string;
        };
        Insert: {
          amount: number;
          business_date: string;
          created_at?: string;
          created_by?: string | null;
          from_account_id: string;
          id?: string;
          idempotency_key: string;
          kind?: Database['public']['Enums']['cash_transfer_kind'];
          number: string;
          organization_id: string;
          reason?: string | null;
          shortage_amount?: number;
          to_account_id: string;
        };
        Update: {
          amount?: number;
          business_date?: string;
          created_at?: string;
          created_by?: string | null;
          from_account_id?: string;
          id?: string;
          idempotency_key?: string;
          kind?: Database['public']['Enums']['cash_transfer_kind'];
          number?: string;
          organization_id?: string;
          reason?: string | null;
          shortage_amount?: number;
          to_account_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'cash_transfers_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_transfers_from_account_id_organization_id_fkey';
            columns: ['from_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'cash_accounts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_transfers_from_account_id_organization_id_fkey';
            columns: ['from_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_cash_balances';
            referencedColumns: ['cash_account_id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_transfers_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'cash_transfers_to_account_id_organization_id_fkey';
            columns: ['to_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'cash_accounts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_transfers_to_account_id_organization_id_fkey';
            columns: ['to_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_cash_balances';
            referencedColumns: ['cash_account_id', 'organization_id'];
          },
        ];
      };
      categories: {
        Row: {
          archived_at: string | null;
          created_at: string;
          created_by: string | null;
          id: string;
          name: string;
          organization_id: string;
          parent_id: string | null;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          archived_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          name: string;
          organization_id: string;
          parent_id?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          archived_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          name?: string;
          organization_id?: string;
          parent_id?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'categories_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'categories_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'categories_parent_id_organization_id_fkey';
            columns: ['parent_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'categories';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'categories_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      charge_waivers: {
        Row: {
          amount: number;
          approval_id: string | null;
          approved_by: string;
          charge_id: string;
          created_at: string;
          created_by: string | null;
          id: string;
          idempotency_key: string;
          organization_id: string;
          reason: string;
        };
        Insert: {
          amount: number;
          approval_id?: string | null;
          approved_by: string;
          charge_id: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key: string;
          organization_id: string;
          reason: string;
        };
        Update: {
          amount?: number;
          approval_id?: string | null;
          approved_by?: string;
          charge_id?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key?: string;
          organization_id?: string;
          reason?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'charge_waivers_approval_id_organization_id_fkey';
            columns: ['approval_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'approvals';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'charge_waivers_approved_by_fk';
            columns: ['approved_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'charge_waivers_charge_id_organization_id_fkey';
            columns: ['charge_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'charges';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'charge_waivers_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'charge_waivers_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      charges: {
        Row: {
          amount: number;
          assessed_on: string;
          contract_id: string;
          created_at: string;
          created_by: string | null;
          id: string;
          kind: Database['public']['Enums']['charge_kind'];
          organization_id: string;
          schedule_line_id: string;
        };
        Insert: {
          amount: number;
          assessed_on: string;
          contract_id: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          kind?: Database['public']['Enums']['charge_kind'];
          organization_id: string;
          schedule_line_id: string;
        };
        Update: {
          amount?: number;
          assessed_on?: string;
          contract_id?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          kind?: Database['public']['Enums']['charge_kind'];
          organization_id?: string;
          schedule_line_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'charges_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'charges_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'charges_schedule_line_id_contract_id_organization_id_fkey';
            columns: ['schedule_line_id', 'contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'schedule_lines';
            referencedColumns: ['id', 'contract_id', 'organization_id'];
          },
          {
            foreignKeyName: 'charges_schedule_line_id_contract_id_organization_id_fkey';
            columns: ['schedule_line_id', 'contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_schedule_line_status';
            referencedColumns: ['schedule_line_id', 'contract_id', 'organization_id'];
          },
        ];
      };
      collector_commissions: {
        Row: {
          amount: number;
          created_at: string;
          created_by: string | null;
          employee_id: string;
          id: string;
          organization_id: string;
          paid_at: string | null;
          paid_by_expense_id: string | null;
          payment_id: string;
          status: Database['public']['Enums']['commission_status'];
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          amount: number;
          created_at?: string;
          created_by?: string | null;
          employee_id: string;
          id?: string;
          organization_id: string;
          paid_at?: string | null;
          paid_by_expense_id?: string | null;
          payment_id: string;
          status?: Database['public']['Enums']['commission_status'];
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          amount?: number;
          created_at?: string;
          created_by?: string | null;
          employee_id?: string;
          id?: string;
          organization_id?: string;
          paid_at?: string | null;
          paid_by_expense_id?: string | null;
          payment_id?: string;
          status?: Database['public']['Enums']['commission_status'];
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'collector_commissions_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'collector_commissions_employee_id_organization_id_fkey';
            columns: ['employee_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'collector_commissions_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'collector_commissions_paid_by_expense_id_organization_id_fkey';
            columns: ['paid_by_expense_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'expenses';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'collector_commissions_payment_id_organization_id_fkey';
            columns: ['payment_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'payments';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'collector_commissions_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      contract_changes: {
        Row: {
          amount: number | null;
          approval_id: string | null;
          approved_by: string | null;
          contract_id: string;
          created_at: string;
          created_by: string | null;
          id: string;
          idempotency_key: string;
          kind: Database['public']['Enums']['change_kind'];
          new_version: number | null;
          old_version: number;
          organization_id: string;
          profit_waived: number;
          reason: string;
          sales_return_id: string | null;
        };
        Insert: {
          amount?: number | null;
          approval_id?: string | null;
          approved_by?: string | null;
          contract_id: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key: string;
          kind: Database['public']['Enums']['change_kind'];
          new_version?: number | null;
          old_version: number;
          organization_id: string;
          profit_waived?: number;
          reason: string;
          sales_return_id?: string | null;
        };
        Update: {
          amount?: number | null;
          approval_id?: string | null;
          approved_by?: string | null;
          contract_id?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key?: string;
          kind?: Database['public']['Enums']['change_kind'];
          new_version?: number | null;
          old_version?: number;
          organization_id?: string;
          profit_waived?: number;
          reason?: string;
          sales_return_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'contract_changes_approval_id_organization_id_fkey';
            columns: ['approval_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'approvals';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contract_changes_approved_by_fk';
            columns: ['approved_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contract_changes_contract_id_organization_id_fkey';
            columns: ['contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'contracts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contract_changes_contract_id_organization_id_fkey';
            columns: ['contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_contract_balances';
            referencedColumns: ['contract_id', 'organization_id'];
          },
          {
            foreignKeyName: 'contract_changes_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contract_changes_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'contract_changes_sales_return_id_organization_id_fkey';
            columns: ['sales_return_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_returns';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      contract_guarantors: {
        Row: {
          contract_id: string;
          created_at: string;
          created_by: string | null;
          guarantor_id: string;
          organization_id: string;
        };
        Insert: {
          contract_id: string;
          created_at?: string;
          created_by?: string | null;
          guarantor_id: string;
          organization_id: string;
        };
        Update: {
          contract_id?: string;
          created_at?: string;
          created_by?: string | null;
          guarantor_id?: string;
          organization_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'contract_guarantors_contract_id_organization_id_fkey';
            columns: ['contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'contracts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contract_guarantors_contract_id_organization_id_fkey';
            columns: ['contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_contract_balances';
            referencedColumns: ['contract_id', 'organization_id'];
          },
          {
            foreignKeyName: 'contract_guarantors_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contract_guarantors_guarantor_id_organization_id_fkey';
            columns: ['guarantor_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'guarantors';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contract_guarantors_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      contracts: {
        Row: {
          branch_id: string;
          cash_price: number;
          closed_at: string | null;
          created_at: string;
          created_by: string | null;
          credit_approval_id: string | null;
          creditor: Database['public']['Enums']['creditor_model'];
          current_version: number;
          customer_id: string;
          down_payment: number;
          financed_amount: number;
          first_due_date: string;
          frequency: Database['public']['Enums']['installment_frequency'];
          id: string;
          idempotency_key: string;
          installments_count: number;
          is_migrated: boolean;
          markup_amount: number;
          markup_pct: number;
          migration_batch_id: string | null;
          number: string;
          order_id: string | null;
          organization_id: string;
          policy_id: string;
          sale_id: string | null;
          status: Database['public']['Enums']['contract_status'];
          total_payable: number;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          branch_id: string;
          cash_price: number;
          closed_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          credit_approval_id?: string | null;
          creditor: Database['public']['Enums']['creditor_model'];
          current_version?: number;
          customer_id: string;
          down_payment?: number;
          financed_amount: number;
          first_due_date: string;
          frequency: Database['public']['Enums']['installment_frequency'];
          id?: string;
          idempotency_key: string;
          installments_count: number;
          is_migrated?: boolean;
          markup_amount: number;
          markup_pct: number;
          migration_batch_id?: string | null;
          number: string;
          order_id?: string | null;
          organization_id: string;
          policy_id: string;
          sale_id?: string | null;
          status?: Database['public']['Enums']['contract_status'];
          total_payable: number;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          branch_id?: string;
          cash_price?: number;
          closed_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          credit_approval_id?: string | null;
          creditor?: Database['public']['Enums']['creditor_model'];
          current_version?: number;
          customer_id?: string;
          down_payment?: number;
          financed_amount?: number;
          first_due_date?: string;
          frequency?: Database['public']['Enums']['installment_frequency'];
          id?: string;
          idempotency_key?: string;
          installments_count?: number;
          is_migrated?: boolean;
          markup_amount?: number;
          markup_pct?: number;
          migration_batch_id?: string | null;
          number?: string;
          order_id?: string | null;
          organization_id?: string;
          policy_id?: string;
          sale_id?: string | null;
          status?: Database['public']['Enums']['contract_status'];
          total_payable?: number;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'contracts_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contracts_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contracts_credit_approval_id_organization_id_fkey';
            columns: ['credit_approval_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'approvals';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contracts_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contracts_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_customer_exposure';
            referencedColumns: ['customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'contracts_migration_batch_id_organization_id_fkey';
            columns: ['migration_batch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'import_jobs';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contracts_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_orders';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contracts_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_order_balances';
            referencedColumns: ['order_id', 'organization_id'];
          },
          {
            foreignKeyName: 'contracts_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'contracts_policy_id_organization_id_fkey';
            columns: ['policy_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'installment_policies';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contracts_sale_id_organization_id_fkey';
            columns: ['sale_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contracts_sale_id_organization_id_fkey';
            columns: ['sale_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_sale_balances';
            referencedColumns: ['sale_id', 'organization_id'];
          },
          {
            foreignKeyName: 'contracts_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      customer_guarantors: {
        Row: {
          created_at: string;
          created_by: string | null;
          customer_id: string;
          guarantor_id: string;
          organization_id: string;
          relation: string | null;
        };
        Insert: {
          created_at?: string;
          created_by?: string | null;
          customer_id: string;
          guarantor_id: string;
          organization_id: string;
          relation?: string | null;
        };
        Update: {
          created_at?: string;
          created_by?: string | null;
          customer_id?: string;
          guarantor_id?: string;
          organization_id?: string;
          relation?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'customer_guarantors_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'customer_guarantors_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'customer_guarantors_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_customer_exposure';
            referencedColumns: ['customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'customer_guarantors_guarantor_id_organization_id_fkey';
            columns: ['guarantor_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'guarantors';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'customer_guarantors_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      customers: {
        Row: {
          address: string | null;
          archived_at: string | null;
          birth_date: string | null;
          city: string | null;
          created_at: string;
          created_by: string | null;
          credit_limit: number;
          employer: string | null;
          full_name: string;
          gender: string | null;
          id: string;
          id_file_id: string | null;
          is_business: boolean;
          job: string | null;
          monthly_income: number | null;
          national_id: string | null;
          notes: string | null;
          organization_id: string;
          phones: string[];
          status: Database['public']['Enums']['customer_status'];
          tax_registration_no: string | null;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          address?: string | null;
          archived_at?: string | null;
          birth_date?: string | null;
          city?: string | null;
          created_at?: string;
          created_by?: string | null;
          credit_limit?: number;
          employer?: string | null;
          full_name: string;
          gender?: string | null;
          id?: string;
          id_file_id?: string | null;
          is_business?: boolean;
          job?: string | null;
          monthly_income?: number | null;
          national_id?: string | null;
          notes?: string | null;
          organization_id: string;
          phones?: string[];
          status?: Database['public']['Enums']['customer_status'];
          tax_registration_no?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          address?: string | null;
          archived_at?: string | null;
          birth_date?: string | null;
          city?: string | null;
          created_at?: string;
          created_by?: string | null;
          credit_limit?: number;
          employer?: string | null;
          full_name?: string;
          gender?: string | null;
          id?: string;
          id_file_id?: string | null;
          is_business?: boolean;
          job?: string | null;
          monthly_income?: number | null;
          national_id?: string | null;
          notes?: string | null;
          organization_id?: string;
          phones?: string[];
          status?: Database['public']['Enums']['customer_status'];
          tax_registration_no?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'customers_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'customers_id_file_id_organization_id_fkey';
            columns: ['id_file_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'files';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'customers_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'customers_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      day_closes: {
        Row: {
          branch_id: string;
          business_date: string;
          closed_at: string;
          closed_by: string;
          created_at: string;
          created_by: string | null;
          id: string;
          issues: NonNullable<Json>;
          organization_id: string;
          reopen_reason: string | null;
          reopened_at: string | null;
          reopened_by: string | null;
          status: Database['public']['Enums']['day_close_status'];
          totals: NonNullable<Json>;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          branch_id: string;
          business_date: string;
          closed_at?: string;
          closed_by: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          issues?: NonNullable<Json>;
          organization_id: string;
          reopen_reason?: string | null;
          reopened_at?: string | null;
          reopened_by?: string | null;
          status?: Database['public']['Enums']['day_close_status'];
          totals?: NonNullable<Json>;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          branch_id?: string;
          business_date?: string;
          closed_at?: string;
          closed_by?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          issues?: NonNullable<Json>;
          organization_id?: string;
          reopen_reason?: string | null;
          reopened_at?: string | null;
          reopened_by?: string | null;
          status?: Database['public']['Enums']['day_close_status'];
          totals?: NonNullable<Json>;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'day_closes_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'day_closes_closed_by_fk';
            columns: ['closed_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'day_closes_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'day_closes_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'day_closes_reopened_by_fk';
            columns: ['reopened_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'day_closes_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      deliveries: {
        Row: {
          address: string;
          branch_id: string;
          created_at: string;
          created_by: string | null;
          delivered_at: string | null;
          driver_employee_id: string | null;
          failed_reason: string | null;
          id: string;
          idempotency_key: string;
          number: string;
          order_id: string;
          organization_id: string;
          proof_file_id: string | null;
          scheduled_date: string;
          status: Database['public']['Enums']['delivery_status'];
          time_window: string | null;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          address: string;
          branch_id: string;
          created_at?: string;
          created_by?: string | null;
          delivered_at?: string | null;
          driver_employee_id?: string | null;
          failed_reason?: string | null;
          id?: string;
          idempotency_key: string;
          number: string;
          order_id: string;
          organization_id: string;
          proof_file_id?: string | null;
          scheduled_date: string;
          status?: Database['public']['Enums']['delivery_status'];
          time_window?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          address?: string;
          branch_id?: string;
          created_at?: string;
          created_by?: string | null;
          delivered_at?: string | null;
          driver_employee_id?: string | null;
          failed_reason?: string | null;
          id?: string;
          idempotency_key?: string;
          number?: string;
          order_id?: string;
          organization_id?: string;
          proof_file_id?: string | null;
          scheduled_date?: string;
          status?: Database['public']['Enums']['delivery_status'];
          time_window?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'deliveries_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'deliveries_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'deliveries_driver_employee_id_organization_id_fkey';
            columns: ['driver_employee_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'deliveries_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_orders';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'deliveries_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_order_balances';
            referencedColumns: ['order_id', 'organization_id'];
          },
          {
            foreignKeyName: 'deliveries_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'deliveries_proof_file_id_organization_id_fkey';
            columns: ['proof_file_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'files';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'deliveries_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      delivery_lines: {
        Row: {
          created_at: string;
          created_by: string | null;
          delivery_id: string;
          id: string;
          order_line_id: string;
          organization_id: string;
          quantity: number;
          unit_id: string | null;
        };
        Insert: {
          created_at?: string;
          created_by?: string | null;
          delivery_id: string;
          id?: string;
          order_line_id: string;
          organization_id: string;
          quantity: number;
          unit_id?: string | null;
        };
        Update: {
          created_at?: string;
          created_by?: string | null;
          delivery_id?: string;
          id?: string;
          order_line_id?: string;
          organization_id?: string;
          quantity?: number;
          unit_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'delivery_lines_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'delivery_lines_delivery_id_organization_id_fkey';
            columns: ['delivery_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'deliveries';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'delivery_lines_order_line_id_organization_id_fkey';
            columns: ['order_line_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_order_lines';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'delivery_lines_order_line_id_organization_id_fkey';
            columns: ['order_line_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_order_line_fulfilment';
            referencedColumns: ['order_line_id', 'organization_id'];
          },
          {
            foreignKeyName: 'delivery_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'delivery_lines_unit_id_organization_id_fkey';
            columns: ['unit_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'units';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      devices: {
        Row: {
          archived_at: string | null;
          branch_id: string;
          created_at: string;
          created_by: string | null;
          eta_os_version: string | null;
          eta_serial: string | null;
          eta_status: Database['public']['Enums']['device_status'];
          id: string;
          is_active: boolean;
          last_seen_at: string | null;
          name: string;
          organization_id: string;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          archived_at?: string | null;
          branch_id: string;
          created_at?: string;
          created_by?: string | null;
          eta_os_version?: string | null;
          eta_serial?: string | null;
          eta_status?: Database['public']['Enums']['device_status'];
          id?: string;
          is_active?: boolean;
          last_seen_at?: string | null;
          name: string;
          organization_id: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          archived_at?: string | null;
          branch_id?: string;
          created_at?: string;
          created_by?: string | null;
          eta_os_version?: string | null;
          eta_serial?: string | null;
          eta_status?: Database['public']['Enums']['device_status'];
          id?: string;
          is_active?: boolean;
          last_seen_at?: string | null;
          name?: string;
          organization_id?: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'devices_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'devices_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'devices_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'devices_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      document_counters: {
        Row: {
          branch_id: string;
          doc_type: Database['public']['Enums']['doc_type'];
          next_value: number;
          organization_id: string;
          period_year: number;
        };
        Insert: {
          branch_id: string;
          doc_type: Database['public']['Enums']['doc_type'];
          next_value?: number;
          organization_id: string;
          period_year: number;
        };
        Update: {
          branch_id?: string;
          doc_type?: Database['public']['Enums']['doc_type'];
          next_value?: number;
          organization_id?: string;
          period_year?: number;
        };
        Relationships: [
          {
            foreignKeyName: 'document_counters_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'document_counters_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      employee_branches: {
        Row: {
          branch_id: string;
          created_at: string;
          created_by: string | null;
          employee_id: string;
          organization_id: string;
        };
        Insert: {
          branch_id: string;
          created_at?: string;
          created_by?: string | null;
          employee_id: string;
          organization_id: string;
        };
        Update: {
          branch_id?: string;
          created_at?: string;
          created_by?: string | null;
          employee_id?: string;
          organization_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'employee_branches_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'employee_branches_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'employee_branches_employee_id_organization_id_fkey';
            columns: ['employee_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'employee_branches_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      employee_permission_overrides: {
        Row: {
          created_at: string;
          created_by: string | null;
          employee_id: string;
          granted: boolean;
          organization_id: string;
          permission_key: string;
        };
        Insert: {
          created_at?: string;
          created_by?: string | null;
          employee_id: string;
          granted: boolean;
          organization_id: string;
          permission_key: string;
        };
        Update: {
          created_at?: string;
          created_by?: string | null;
          employee_id?: string;
          granted?: boolean;
          organization_id?: string;
          permission_key?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'employee_permission_overrides_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'employee_permission_overrides_employee_id_organization_id_fkey';
            columns: ['employee_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'employee_permission_overrides_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'employee_permission_overrides_permission_key_fkey';
            columns: ['permission_key'];
            isOneToOne: false;
            referencedRelation: 'permissions';
            referencedColumns: ['key'];
          },
        ];
      };
      employees: {
        Row: {
          archived_at: string | null;
          auth_user_id: string | null;
          created_at: string;
          created_by: string | null;
          default_branch_id: string | null;
          email: string | null;
          full_name: string;
          id: string;
          is_active: boolean;
          last_login_at: string | null;
          must_change_password: boolean;
          national_id: string | null;
          organization_id: string;
          phone: string | null;
          role: Database['public']['Enums']['employee_role'];
          updated_at: string;
          updated_by: string | null;
          username: string | null;
        };
        Insert: {
          archived_at?: string | null;
          auth_user_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          default_branch_id?: string | null;
          email?: string | null;
          full_name: string;
          id?: string;
          is_active?: boolean;
          last_login_at?: string | null;
          must_change_password?: boolean;
          national_id?: string | null;
          organization_id: string;
          phone?: string | null;
          role: Database['public']['Enums']['employee_role'];
          updated_at?: string;
          updated_by?: string | null;
          username?: string | null;
        };
        Update: {
          archived_at?: string | null;
          auth_user_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          default_branch_id?: string | null;
          email?: string | null;
          full_name?: string;
          id?: string;
          is_active?: boolean;
          last_login_at?: string | null;
          must_change_password?: boolean;
          national_id?: string | null;
          organization_id?: string;
          phone?: string | null;
          role?: Database['public']['Enums']['employee_role'];
          updated_at?: string;
          updated_by?: string | null;
          username?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'employees_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'employees_default_branch_id_organization_id_fkey';
            columns: ['default_branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'employees_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'employees_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      eta_settings: {
        Row: {
          activity_code: string | null;
          client_id: string | null;
          client_secret_vault_id: string | null;
          environment: Database['public']['Enums']['eta_environment'];
          is_enabled: boolean;
          organization_id: string;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          activity_code?: string | null;
          client_id?: string | null;
          client_secret_vault_id?: string | null;
          environment?: Database['public']['Enums']['eta_environment'];
          is_enabled?: boolean;
          organization_id: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          activity_code?: string | null;
          client_id?: string | null;
          client_secret_vault_id?: string | null;
          environment?: Database['public']['Enums']['eta_environment'];
          is_enabled?: boolean;
          organization_id?: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'eta_settings_org_fk';
            columns: ['organization_id'];
            isOneToOne: true;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'eta_settings_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      expense_categories: {
        Row: {
          archived_at: string | null;
          created_at: string;
          created_by: string | null;
          id: string;
          name: string;
          organization_id: string;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          archived_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          name: string;
          organization_id: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          archived_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          name?: string;
          organization_id?: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'expense_categories_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'expense_categories_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'expense_categories_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      expenses: {
        Row: {
          amount: number;
          branch_id: string;
          business_date: string;
          cash_account_id: string;
          category_id: string;
          created_at: string;
          created_by: string | null;
          id: string;
          idempotency_key: string;
          note: string | null;
          number: string;
          organization_id: string;
          receipt_file_id: string | null;
          reverses_expense_id: string | null;
          shift_id: string | null;
        };
        Insert: {
          amount: number;
          branch_id: string;
          business_date: string;
          cash_account_id: string;
          category_id: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key: string;
          note?: string | null;
          number: string;
          organization_id: string;
          receipt_file_id?: string | null;
          reverses_expense_id?: string | null;
          shift_id?: string | null;
        };
        Update: {
          amount?: number;
          branch_id?: string;
          business_date?: string;
          cash_account_id?: string;
          category_id?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key?: string;
          note?: string | null;
          number?: string;
          organization_id?: string;
          receipt_file_id?: string | null;
          reverses_expense_id?: string | null;
          shift_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'expenses_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'expenses_cash_account_id_organization_id_fkey';
            columns: ['cash_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'cash_accounts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'expenses_cash_account_id_organization_id_fkey';
            columns: ['cash_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_cash_balances';
            referencedColumns: ['cash_account_id', 'organization_id'];
          },
          {
            foreignKeyName: 'expenses_category_id_organization_id_fkey';
            columns: ['category_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'expense_categories';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'expenses_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'expenses_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'expenses_receipt_file_id_organization_id_fkey';
            columns: ['receipt_file_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'files';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'expenses_reverses_expense_id_organization_id_fkey';
            columns: ['reverses_expense_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'expenses';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'expenses_shift_id_organization_id_fkey';
            columns: ['shift_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'shifts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'expenses_shift_id_organization_id_fkey';
            columns: ['shift_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_shift_expected_cash';
            referencedColumns: ['shift_id', 'organization_id'];
          },
        ];
      };
      field_surveys: {
        Row: {
          assigned_to: string;
          created_at: string;
          created_by: string | null;
          customer_id: string;
          decided_at: string | null;
          decided_by: string | null;
          gps_accuracy_m: number | null;
          id: string;
          lat: number | null;
          lng: number | null;
          notes: string | null;
          organization_id: string;
          scores: NonNullable<Json>;
          status: Database['public']['Enums']['survey_status'];
          submitted_at: string | null;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          assigned_to: string;
          created_at?: string;
          created_by?: string | null;
          customer_id: string;
          decided_at?: string | null;
          decided_by?: string | null;
          gps_accuracy_m?: number | null;
          id?: string;
          lat?: number | null;
          lng?: number | null;
          notes?: string | null;
          organization_id: string;
          scores?: NonNullable<Json>;
          status?: Database['public']['Enums']['survey_status'];
          submitted_at?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          assigned_to?: string;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string;
          decided_at?: string | null;
          decided_by?: string | null;
          gps_accuracy_m?: number | null;
          id?: string;
          lat?: number | null;
          lng?: number | null;
          notes?: string | null;
          organization_id?: string;
          scores?: NonNullable<Json>;
          status?: Database['public']['Enums']['survey_status'];
          submitted_at?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'field_surveys_assigned_to_organization_id_fkey';
            columns: ['assigned_to', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'field_surveys_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'field_surveys_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'field_surveys_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_customer_exposure';
            referencedColumns: ['customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'field_surveys_decided_by_fk';
            columns: ['decided_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'field_surveys_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'field_surveys_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      files: {
        Row: {
          bucket: string;
          created_at: string;
          created_by: string | null;
          entity_id: string | null;
          entity_type: string | null;
          id: string;
          mime: string;
          organization_id: string;
          original_name: string | null;
          path: string;
          purpose: Database['public']['Enums']['file_purpose'];
          sha256: string | null;
          size_bytes: number;
        };
        Insert: {
          bucket?: string;
          created_at?: string;
          created_by?: string | null;
          entity_id?: string | null;
          entity_type?: string | null;
          id?: string;
          mime: string;
          organization_id: string;
          original_name?: string | null;
          path: string;
          purpose: Database['public']['Enums']['file_purpose'];
          sha256?: string | null;
          size_bytes: number;
        };
        Update: {
          bucket?: string;
          created_at?: string;
          created_by?: string | null;
          entity_id?: string | null;
          entity_type?: string | null;
          id?: string;
          mime?: string;
          organization_id?: string;
          original_name?: string | null;
          path?: string;
          purpose?: Database['public']['Enums']['file_purpose'];
          sha256?: string | null;
          size_bytes?: number;
        };
        Relationships: [
          {
            foreignKeyName: 'files_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'files_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      fiscal_submissions: {
        Row: {
          accepted_at: string | null;
          attempts: number;
          branch_id: string;
          created_at: string;
          created_by: string | null;
          device_id: string | null;
          doc_type: Database['public']['Enums']['fiscal_doc_type'];
          environment: Database['public']['Enums']['eta_environment'];
          eta_long_id: string | null;
          eta_uuid: string | null;
          id: string;
          internal_id: string;
          last_error: string | null;
          next_retry_at: string | null;
          organization_id: string;
          payload: Json | null;
          qr_payload: string | null;
          return_id: string | null;
          sale_id: string | null;
          status: Database['public']['Enums']['fiscal_status'];
          submitted_at: string | null;
          updated_at: string;
        };
        Insert: {
          accepted_at?: string | null;
          attempts?: number;
          branch_id: string;
          created_at?: string;
          created_by?: string | null;
          device_id?: string | null;
          doc_type: Database['public']['Enums']['fiscal_doc_type'];
          environment: Database['public']['Enums']['eta_environment'];
          eta_long_id?: string | null;
          eta_uuid?: string | null;
          id?: string;
          internal_id: string;
          last_error?: string | null;
          next_retry_at?: string | null;
          organization_id: string;
          payload?: Json | null;
          qr_payload?: string | null;
          return_id?: string | null;
          sale_id?: string | null;
          status?: Database['public']['Enums']['fiscal_status'];
          submitted_at?: string | null;
          updated_at?: string;
        };
        Update: {
          accepted_at?: string | null;
          attempts?: number;
          branch_id?: string;
          created_at?: string;
          created_by?: string | null;
          device_id?: string | null;
          doc_type?: Database['public']['Enums']['fiscal_doc_type'];
          environment?: Database['public']['Enums']['eta_environment'];
          eta_long_id?: string | null;
          eta_uuid?: string | null;
          id?: string;
          internal_id?: string;
          last_error?: string | null;
          next_retry_at?: string | null;
          organization_id?: string;
          payload?: Json | null;
          qr_payload?: string | null;
          return_id?: string | null;
          sale_id?: string | null;
          status?: Database['public']['Enums']['fiscal_status'];
          submitted_at?: string | null;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'fiscal_submissions_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'fiscal_submissions_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'fiscal_submissions_device_id_organization_id_fkey';
            columns: ['device_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'devices';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'fiscal_submissions_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'fiscal_submissions_return_id_organization_id_fkey';
            columns: ['return_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_returns';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'fiscal_submissions_sale_id_organization_id_fkey';
            columns: ['sale_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'fiscal_submissions_sale_id_organization_id_fkey';
            columns: ['sale_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_sale_balances';
            referencedColumns: ['sale_id', 'organization_id'];
          },
        ];
      };
      guarantors: {
        Row: {
          address: string | null;
          archived_at: string | null;
          created_at: string;
          created_by: string | null;
          customer_id: string | null;
          full_name: string;
          id: string;
          job: string | null;
          monthly_income: number | null;
          national_id: string | null;
          organization_id: string;
          phone: string | null;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          address?: string | null;
          archived_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string | null;
          full_name: string;
          id?: string;
          job?: string | null;
          monthly_income?: number | null;
          national_id?: string | null;
          organization_id: string;
          phone?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          address?: string | null;
          archived_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string | null;
          full_name?: string;
          id?: string;
          job?: string | null;
          monthly_income?: number | null;
          national_id?: string | null;
          organization_id?: string;
          phone?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'guarantors_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'guarantors_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'guarantors_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_customer_exposure';
            referencedColumns: ['customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'guarantors_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'guarantors_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      import_jobs: {
        Row: {
          created_at: string;
          created_by: string | null;
          dry_run: boolean;
          file_id: string | null;
          finished_at: string | null;
          id: string;
          kind: Database['public']['Enums']['import_kind'];
          organization_id: string;
          report: NonNullable<Json>;
          result_file_id: string | null;
          rows_failed: number;
          rows_ok: number;
          rows_total: number;
          status: Database['public']['Enums']['import_status'];
          updated_at: string;
        };
        Insert: {
          created_at?: string;
          created_by?: string | null;
          dry_run?: boolean;
          file_id?: string | null;
          finished_at?: string | null;
          id?: string;
          kind: Database['public']['Enums']['import_kind'];
          organization_id: string;
          report?: NonNullable<Json>;
          result_file_id?: string | null;
          rows_failed?: number;
          rows_ok?: number;
          rows_total?: number;
          status?: Database['public']['Enums']['import_status'];
          updated_at?: string;
        };
        Update: {
          created_at?: string;
          created_by?: string | null;
          dry_run?: boolean;
          file_id?: string | null;
          finished_at?: string | null;
          id?: string;
          kind?: Database['public']['Enums']['import_kind'];
          organization_id?: string;
          report?: NonNullable<Json>;
          result_file_id?: string | null;
          rows_failed?: number;
          rows_ok?: number;
          rows_total?: number;
          status?: Database['public']['Enums']['import_status'];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'import_jobs_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'import_jobs_file_id_organization_id_fkey';
            columns: ['file_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'files';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'import_jobs_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'import_jobs_result_file_id_organization_id_fkey';
            columns: ['result_file_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'files';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      installment_policies: {
        Row: {
          allowed_frequencies: Database['public']['Enums']['installment_frequency'][];
          amount_tiers: NonNullable<Json>;
          created_at: string;
          created_by: string | null;
          down_payment_rules: NonNullable<Json>;
          early_settlement_pct: number | null;
          early_settlement_rule: Database['public']['Enums']['early_settlement_rule'];
          effective_from: string;
          grace_days: number;
          guarantor_required_above: number | null;
          id: string;
          late_fee_cap: number | null;
          late_fee_recurring: boolean;
          late_fee_type: Database['public']['Enums']['late_fee_type'];
          late_fee_value: number;
          markup_tiers: NonNullable<Json>;
          max_down_payment_pct: number | null;
          max_months: number;
          min_down_payment_pct: number;
          min_installment: number;
          min_installment_by_frequency: NonNullable<Json>;
          min_sale_amount: number;
          organization_id: string;
          rounding_step: number;
          survey_required_above: number | null;
          version: number;
        };
        Insert: {
          allowed_frequencies?: Database['public']['Enums']['installment_frequency'][];
          amount_tiers?: NonNullable<Json>;
          created_at?: string;
          created_by?: string | null;
          down_payment_rules?: NonNullable<Json>;
          early_settlement_pct?: number | null;
          early_settlement_rule?: Database['public']['Enums']['early_settlement_rule'];
          effective_from?: string;
          grace_days?: number;
          guarantor_required_above?: number | null;
          id?: string;
          late_fee_cap?: number | null;
          late_fee_recurring?: boolean;
          late_fee_type?: Database['public']['Enums']['late_fee_type'];
          late_fee_value?: number;
          markup_tiers: NonNullable<Json>;
          max_down_payment_pct?: number | null;
          max_months: number;
          min_down_payment_pct?: number;
          min_installment?: number;
          min_installment_by_frequency?: NonNullable<Json>;
          min_sale_amount?: number;
          organization_id: string;
          rounding_step?: number;
          survey_required_above?: number | null;
          version: number;
        };
        Update: {
          allowed_frequencies?: Database['public']['Enums']['installment_frequency'][];
          amount_tiers?: NonNullable<Json>;
          created_at?: string;
          created_by?: string | null;
          down_payment_rules?: NonNullable<Json>;
          early_settlement_pct?: number | null;
          early_settlement_rule?: Database['public']['Enums']['early_settlement_rule'];
          effective_from?: string;
          grace_days?: number;
          guarantor_required_above?: number | null;
          id?: string;
          late_fee_cap?: number | null;
          late_fee_recurring?: boolean;
          late_fee_type?: Database['public']['Enums']['late_fee_type'];
          late_fee_value?: number;
          markup_tiers?: NonNullable<Json>;
          max_down_payment_pct?: number | null;
          max_months?: number;
          min_down_payment_pct?: number;
          min_installment?: number;
          min_installment_by_frequency?: NonNullable<Json>;
          min_sale_amount?: number;
          organization_id?: string;
          rounding_step?: number;
          survey_required_above?: number | null;
          version?: number;
        };
        Relationships: [
          {
            foreignKeyName: 'installment_policies_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'installment_policies_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      invites: {
        Row: {
          accepted_at: string | null;
          created_at: string;
          email: string;
          employee_id: string;
          expires_at: string;
          id: string;
          invited_by: string | null;
          organization_id: string;
          revoked_at: string | null;
          token_hash: string;
        };
        Insert: {
          accepted_at?: string | null;
          created_at?: string;
          email: string;
          employee_id: string;
          expires_at: string;
          id?: string;
          invited_by?: string | null;
          organization_id: string;
          revoked_at?: string | null;
          token_hash: string;
        };
        Update: {
          accepted_at?: string | null;
          created_at?: string;
          email?: string;
          employee_id?: string;
          expires_at?: string;
          id?: string;
          invited_by?: string | null;
          organization_id?: string;
          revoked_at?: string | null;
          token_hash?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'invites_employee_id_organization_id_fkey';
            columns: ['employee_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'invites_invited_by_fk';
            columns: ['invited_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'invites_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      jobs: {
        Row: {
          attempts: number;
          created_at: string;
          dedupe_key: string | null;
          finished_at: string | null;
          id: string;
          job_type: string;
          last_error: string | null;
          locked_at: string | null;
          locked_by: string | null;
          max_attempts: number;
          organization_id: string | null;
          payload: NonNullable<Json>;
          run_at: string;
          status: Database['public']['Enums']['job_status'];
        };
        Insert: {
          attempts?: number;
          created_at?: string;
          dedupe_key?: string | null;
          finished_at?: string | null;
          id?: string;
          job_type: string;
          last_error?: string | null;
          locked_at?: string | null;
          locked_by?: string | null;
          max_attempts?: number;
          organization_id?: string | null;
          payload?: NonNullable<Json>;
          run_at?: string;
          status?: Database['public']['Enums']['job_status'];
        };
        Update: {
          attempts?: number;
          created_at?: string;
          dedupe_key?: string | null;
          finished_at?: string | null;
          id?: string;
          job_type?: string;
          last_error?: string | null;
          locked_at?: string | null;
          locked_by?: string | null;
          max_attempts?: number;
          organization_id?: string | null;
          payload?: NonNullable<Json>;
          run_at?: string;
          status?: Database['public']['Enums']['job_status'];
        };
        Relationships: [
          {
            foreignKeyName: 'jobs_organization_id_fkey';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      legal_case_notes: {
        Row: {
          case_id: string;
          created_at: string;
          created_by: string | null;
          id: string;
          note: string;
          organization_id: string;
        };
        Insert: {
          case_id: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          note: string;
          organization_id: string;
        };
        Update: {
          case_id?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          note?: string;
          organization_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'legal_case_notes_case_id_organization_id_fkey';
            columns: ['case_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'legal_cases';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'legal_case_notes_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'legal_case_notes_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      legal_cases: {
        Row: {
          case_number: string | null;
          case_type: string | null;
          claim_amount: number | null;
          closed_at: string | null;
          contract_id: string;
          court: string | null;
          created_at: string;
          created_by: string | null;
          customer_id: string;
          id: string;
          idempotency_key: string;
          lawyer_employee_id: string | null;
          next_hearing_date: string | null;
          number: string;
          organization_id: string;
          outcome: string | null;
          status: Database['public']['Enums']['legal_status'];
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          case_number?: string | null;
          case_type?: string | null;
          claim_amount?: number | null;
          closed_at?: string | null;
          contract_id: string;
          court?: string | null;
          created_at?: string;
          created_by?: string | null;
          customer_id: string;
          id?: string;
          idempotency_key: string;
          lawyer_employee_id?: string | null;
          next_hearing_date?: string | null;
          number: string;
          organization_id: string;
          outcome?: string | null;
          status?: Database['public']['Enums']['legal_status'];
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          case_number?: string | null;
          case_type?: string | null;
          claim_amount?: number | null;
          closed_at?: string | null;
          contract_id?: string;
          court?: string | null;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string;
          id?: string;
          idempotency_key?: string;
          lawyer_employee_id?: string | null;
          next_hearing_date?: string | null;
          number?: string;
          organization_id?: string;
          outcome?: string | null;
          status?: Database['public']['Enums']['legal_status'];
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'legal_cases_contract_id_customer_id_organization_id_fkey';
            columns: ['contract_id', 'customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'contracts';
            referencedColumns: ['id', 'customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'legal_cases_contract_id_customer_id_organization_id_fkey';
            columns: ['contract_id', 'customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_contract_balances';
            referencedColumns: ['contract_id', 'customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'legal_cases_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'legal_cases_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'legal_cases_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_customer_exposure';
            referencedColumns: ['customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'legal_cases_lawyer_employee_id_organization_id_fkey';
            columns: ['lawyer_employee_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'legal_cases_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'legal_cases_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      legal_hearings: {
        Row: {
          case_id: string;
          created_at: string;
          created_by: string | null;
          hearing_date: string;
          id: string;
          notes: string | null;
          organization_id: string;
          outcome: string | null;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          case_id: string;
          created_at?: string;
          created_by?: string | null;
          hearing_date: string;
          id?: string;
          notes?: string | null;
          organization_id: string;
          outcome?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          case_id?: string;
          created_at?: string;
          created_by?: string | null;
          hearing_date?: string;
          id?: string;
          notes?: string | null;
          organization_id?: string;
          outcome?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'legal_hearings_case_id_organization_id_fkey';
            columns: ['case_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'legal_cases';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'legal_hearings_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'legal_hearings_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'legal_hearings_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      login_attempts: {
        Row: {
          created_at: string;
          id: number;
          identifier: string;
          ip: unknown;
          success: boolean;
          tenant_slug: string | null;
          user_agent: string | null;
        };
        Insert: {
          created_at?: string;
          id?: never;
          identifier: string;
          ip?: unknown;
          success: boolean;
          tenant_slug?: string | null;
          user_agent?: string | null;
        };
        Update: {
          created_at?: string;
          id?: never;
          identifier?: string;
          ip?: unknown;
          success?: boolean;
          tenant_slug?: string | null;
          user_agent?: string | null;
        };
        Relationships: [];
      };
      org_settings: {
        Row: {
          allow_negative_bank: boolean;
          collector_commission_pct: number;
          credit_limit_income_multiple: number | null;
          credit_min_score: number;
          credit_score_weights: NonNullable<Json>;
          currency: string;
          customer_ban_days: number;
          default_tax_class_id: string | null;
          delivery_fee_tax_class_id: string | null;
          deposit_vat_timing: string;
          discount_caps: NonNullable<Json>;
          global_min_stock: number;
          installment_markup_vat: string;
          legal_referral_days: NonNullable<Json>;
          organization_id: string;
          overdue_warning_interval_days: number;
          prices_include_vat: boolean;
          purchase_approval_threshold: number | null;
          receipt_fields: NonNullable<Json>;
          receipt_footer: string | null;
          receipt_header: string | null;
          receipt_width_mm: number;
          return_policy_days: number;
          theme_color: string;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          allow_negative_bank?: boolean;
          collector_commission_pct?: number;
          credit_limit_income_multiple?: number | null;
          credit_min_score?: number;
          credit_score_weights?: NonNullable<Json>;
          currency?: string;
          customer_ban_days?: number;
          default_tax_class_id?: string | null;
          delivery_fee_tax_class_id?: string | null;
          deposit_vat_timing?: string;
          discount_caps?: NonNullable<Json>;
          global_min_stock?: number;
          installment_markup_vat?: string;
          legal_referral_days?: NonNullable<Json>;
          organization_id: string;
          overdue_warning_interval_days?: number;
          prices_include_vat?: boolean;
          purchase_approval_threshold?: number | null;
          receipt_fields?: NonNullable<Json>;
          receipt_footer?: string | null;
          receipt_header?: string | null;
          receipt_width_mm?: number;
          return_policy_days?: number;
          theme_color?: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          allow_negative_bank?: boolean;
          collector_commission_pct?: number;
          credit_limit_income_multiple?: number | null;
          credit_min_score?: number;
          credit_score_weights?: NonNullable<Json>;
          currency?: string;
          customer_ban_days?: number;
          default_tax_class_id?: string | null;
          delivery_fee_tax_class_id?: string | null;
          deposit_vat_timing?: string;
          discount_caps?: NonNullable<Json>;
          global_min_stock?: number;
          installment_markup_vat?: string;
          legal_referral_days?: NonNullable<Json>;
          organization_id?: string;
          overdue_warning_interval_days?: number;
          prices_include_vat?: boolean;
          purchase_approval_threshold?: number | null;
          receipt_fields?: NonNullable<Json>;
          receipt_footer?: string | null;
          receipt_header?: string | null;
          receipt_width_mm?: number;
          return_policy_days?: number;
          theme_color?: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'org_settings_default_tax_fk';
            columns: ['default_tax_class_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'tax_classes';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'org_settings_delivery_fee_tax_fk';
            columns: ['delivery_fee_tax_class_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'tax_classes';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'org_settings_org_fk';
            columns: ['organization_id'];
            isOneToOne: true;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'org_settings_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      organization_features: {
        Row: {
          config: NonNullable<Json>;
          feature_key: string;
          is_enabled: boolean;
          organization_id: string;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          config?: NonNullable<Json>;
          feature_key: string;
          is_enabled?: boolean;
          organization_id: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          config?: NonNullable<Json>;
          feature_key?: string;
          is_enabled?: boolean;
          organization_id?: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'organization_features_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'organization_features_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      organizations: {
        Row: {
          address: string | null;
          commercial_register: string | null;
          consumer_finance_legal_status: string | null;
          created_at: string;
          creditor_model: Database['public']['Enums']['creditor_model'];
          default_language: string;
          id: string;
          installments_enabled: boolean;
          legal_name: string | null;
          logo_file_id: string | null;
          name: string;
          phone: string | null;
          plan_key: string;
          status: Database['public']['Enums']['org_status'];
          subscription_end: string | null;
          subscription_start: string | null;
          tax_registration_no: string | null;
          tenant_slug: string;
          timezone: string;
          updated_at: string;
        };
        Insert: {
          address?: string | null;
          commercial_register?: string | null;
          consumer_finance_legal_status?: string | null;
          created_at?: string;
          creditor_model?: Database['public']['Enums']['creditor_model'];
          default_language?: string;
          id?: string;
          installments_enabled?: boolean;
          legal_name?: string | null;
          logo_file_id?: string | null;
          name: string;
          phone?: string | null;
          plan_key: string;
          status?: Database['public']['Enums']['org_status'];
          subscription_end?: string | null;
          subscription_start?: string | null;
          tax_registration_no?: string | null;
          tenant_slug: string;
          timezone?: string;
          updated_at?: string;
        };
        Update: {
          address?: string | null;
          commercial_register?: string | null;
          consumer_finance_legal_status?: string | null;
          created_at?: string;
          creditor_model?: Database['public']['Enums']['creditor_model'];
          default_language?: string;
          id?: string;
          installments_enabled?: boolean;
          legal_name?: string | null;
          logo_file_id?: string | null;
          name?: string;
          phone?: string | null;
          plan_key?: string;
          status?: Database['public']['Enums']['org_status'];
          subscription_end?: string | null;
          subscription_start?: string | null;
          tax_registration_no?: string | null;
          tenant_slug?: string;
          timezone?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'organizations_logo_file_fk';
            columns: ['logo_file_id', 'id'];
            isOneToOne: false;
            referencedRelation: 'files';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'organizations_plan_key_fkey';
            columns: ['plan_key'];
            isOneToOne: false;
            referencedRelation: 'plans';
            referencedColumns: ['key'];
          },
        ];
      };
      password_resets: {
        Row: {
          created_at: string;
          created_by: string | null;
          employee_id: string;
          expires_at: string;
          id: string;
          organization_id: string;
          revoked_at: string | null;
          token_hash: string;
          used_at: string | null;
        };
        Insert: {
          created_at?: string;
          created_by?: string | null;
          employee_id: string;
          expires_at: string;
          id?: string;
          organization_id: string;
          revoked_at?: string | null;
          token_hash: string;
          used_at?: string | null;
        };
        Update: {
          created_at?: string;
          created_by?: string | null;
          employee_id?: string;
          expires_at?: string;
          id?: string;
          organization_id?: string;
          revoked_at?: string | null;
          token_hash?: string;
          used_at?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'password_resets_employee_id_organization_id_fkey';
            columns: ['employee_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      payment_allocations: {
        Row: {
          amount: number;
          charge_id: string | null;
          contract_id: string | null;
          created_at: string;
          created_by: string | null;
          id: string;
          order_id: string | null;
          organization_id: string;
          payment_id: string;
          principal_amount: number | null;
          profit_amount: number | null;
          return_id: string | null;
          sale_id: string | null;
          schedule_line_id: string | null;
        };
        Insert: {
          amount: number;
          charge_id?: string | null;
          contract_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          order_id?: string | null;
          organization_id: string;
          payment_id: string;
          principal_amount?: number | null;
          profit_amount?: number | null;
          return_id?: string | null;
          sale_id?: string | null;
          schedule_line_id?: string | null;
        };
        Update: {
          amount?: number;
          charge_id?: string | null;
          contract_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          order_id?: string | null;
          organization_id?: string;
          payment_id?: string;
          principal_amount?: number | null;
          profit_amount?: number | null;
          return_id?: string | null;
          sale_id?: string | null;
          schedule_line_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'payment_allocations_charge_id_contract_id_organization_id_fkey';
            columns: ['charge_id', 'contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'charges';
            referencedColumns: ['id', 'contract_id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_orders';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_order_balances';
            referencedColumns: ['order_id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'payment_allocations_payment_id_organization_id_fkey';
            columns: ['payment_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'payments';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_return_id_organization_id_fkey';
            columns: ['return_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_returns';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_sale_id_organization_id_fkey';
            columns: ['sale_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_sale_id_organization_id_fkey';
            columns: ['sale_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_sale_balances';
            referencedColumns: ['sale_id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_schedule_line_id_contract_id_organizat_fkey';
            columns: ['schedule_line_id', 'contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'schedule_lines';
            referencedColumns: ['id', 'contract_id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_schedule_line_id_contract_id_organizat_fkey';
            columns: ['schedule_line_id', 'contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_schedule_line_status';
            referencedColumns: ['schedule_line_id', 'contract_id', 'organization_id'];
          },
        ];
      };
      payments: {
        Row: {
          amount: number;
          branch_id: string;
          business_date: string;
          cash_account_id: string | null;
          created_at: string;
          created_by: string | null;
          customer_id: string | null;
          direction: Database['public']['Enums']['payment_direction'];
          id: string;
          idempotency_key: string;
          method: Database['public']['Enums']['payment_method'];
          number: string;
          organization_id: string;
          paid_at: string;
          reason: string | null;
          received_by: string | null;
          reference: string | null;
          reverses_payment_id: string | null;
          shift_id: string | null;
        };
        Insert: {
          amount: number;
          branch_id: string;
          business_date: string;
          cash_account_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string | null;
          direction: Database['public']['Enums']['payment_direction'];
          id?: string;
          idempotency_key: string;
          method: Database['public']['Enums']['payment_method'];
          number: string;
          organization_id: string;
          paid_at?: string;
          reason?: string | null;
          received_by?: string | null;
          reference?: string | null;
          reverses_payment_id?: string | null;
          shift_id?: string | null;
        };
        Update: {
          amount?: number;
          branch_id?: string;
          business_date?: string;
          cash_account_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string | null;
          direction?: Database['public']['Enums']['payment_direction'];
          id?: string;
          idempotency_key?: string;
          method?: Database['public']['Enums']['payment_method'];
          number?: string;
          organization_id?: string;
          paid_at?: string;
          reason?: string | null;
          received_by?: string | null;
          reference?: string | null;
          reverses_payment_id?: string | null;
          shift_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'payments_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payments_cash_account_id_organization_id_fkey';
            columns: ['cash_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'cash_accounts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payments_cash_account_id_organization_id_fkey';
            columns: ['cash_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_cash_balances';
            referencedColumns: ['cash_account_id', 'organization_id'];
          },
          {
            foreignKeyName: 'payments_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payments_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payments_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_customer_exposure';
            referencedColumns: ['customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'payments_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'payments_received_by_fk';
            columns: ['received_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payments_reverses_payment_id_organization_id_fkey';
            columns: ['reverses_payment_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'payments';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payments_shift_id_organization_id_fkey';
            columns: ['shift_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'shifts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payments_shift_id_organization_id_fkey';
            columns: ['shift_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_shift_expected_cash';
            referencedColumns: ['shift_id', 'organization_id'];
          },
        ];
      };
      permissions: {
        Row: {
          created_at: string;
          description: string;
          key: string;
          module: string;
        };
        Insert: {
          created_at?: string;
          description: string;
          key: string;
          module: string;
        };
        Update: {
          created_at?: string;
          description?: string;
          key?: string;
          module?: string;
        };
        Relationships: [];
      };
      plans: {
        Row: {
          created_at: string;
          description: string | null;
          display_order: number;
          is_active: boolean;
          key: string;
          max_branches: number | null;
          max_devices: number | null;
          max_users: number | null;
          modules: string[];
          name: string;
          price_monthly: number;
        };
        Insert: {
          created_at?: string;
          description?: string | null;
          display_order?: number;
          is_active?: boolean;
          key: string;
          max_branches?: number | null;
          max_devices?: number | null;
          max_users?: number | null;
          modules?: string[];
          name: string;
          price_monthly: number;
        };
        Update: {
          created_at?: string;
          description?: string | null;
          display_order?: number;
          is_active?: boolean;
          key?: string;
          max_branches?: number | null;
          max_devices?: number | null;
          max_users?: number | null;
          modules?: string[];
          name?: string;
          price_monthly?: number;
        };
        Relationships: [];
      };
      product_branch_min_stock: {
        Row: {
          branch_id: string;
          min_stock: number;
          organization_id: string;
          product_id: string;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          branch_id: string;
          min_stock: number;
          organization_id: string;
          product_id: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          branch_id?: string;
          min_stock?: number;
          organization_id?: string;
          product_id?: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'product_branch_min_stock_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'product_branch_min_stock_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'product_branch_min_stock_updated_by_organization_id_fkey';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      products: {
        Row: {
          archived_at: string | null;
          avg_cost: number;
          barcode: string | null;
          cash_price: number;
          category_id: string | null;
          created_at: string;
          created_by: string | null;
          eta_item_code: string | null;
          eta_item_type: string | null;
          id: string;
          image_file_id: string | null;
          installment_price: number | null;
          is_active: boolean;
          is_serialized: boolean;
          min_stock: number;
          name_ar: string;
          name_en: string | null;
          organization_id: string;
          sku: string;
          tax_class_id: string;
          unit_of_measure: string;
          updated_at: string;
          updated_by: string | null;
          warranty_months: number;
        };
        Insert: {
          archived_at?: string | null;
          avg_cost?: number;
          barcode?: string | null;
          cash_price: number;
          category_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          eta_item_code?: string | null;
          eta_item_type?: string | null;
          id?: string;
          image_file_id?: string | null;
          installment_price?: number | null;
          is_active?: boolean;
          is_serialized?: boolean;
          min_stock?: number;
          name_ar: string;
          name_en?: string | null;
          organization_id: string;
          sku: string;
          tax_class_id: string;
          unit_of_measure?: string;
          updated_at?: string;
          updated_by?: string | null;
          warranty_months?: number;
        };
        Update: {
          archived_at?: string | null;
          avg_cost?: number;
          barcode?: string | null;
          cash_price?: number;
          category_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          eta_item_code?: string | null;
          eta_item_type?: string | null;
          id?: string;
          image_file_id?: string | null;
          installment_price?: number | null;
          is_active?: boolean;
          is_serialized?: boolean;
          min_stock?: number;
          name_ar?: string;
          name_en?: string | null;
          organization_id?: string;
          sku?: string;
          tax_class_id?: string;
          unit_of_measure?: string;
          updated_at?: string;
          updated_by?: string | null;
          warranty_months?: number;
        };
        Relationships: [
          {
            foreignKeyName: 'products_category_id_organization_id_fkey';
            columns: ['category_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'categories';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'products_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'products_image_file_id_organization_id_fkey';
            columns: ['image_file_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'files';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'products_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'products_tax_class_id_organization_id_fkey';
            columns: ['tax_class_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'tax_classes';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'products_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      purchase_invoice_lines: {
        Row: {
          created_at: string;
          created_by: string | null;
          id: string;
          invoice_id: string;
          line_total: number;
          organization_id: string;
          po_line_id: string | null;
          product_id: string;
          quantity: number;
          serials: string[] | null;
          tax_amount: number;
          tax_class_id: string;
          unit_cost: number;
        };
        Insert: {
          created_at?: string;
          created_by?: string | null;
          id?: string;
          invoice_id: string;
          line_total: number;
          organization_id: string;
          po_line_id?: string | null;
          product_id: string;
          quantity: number;
          serials?: string[] | null;
          tax_amount?: number;
          tax_class_id: string;
          unit_cost: number;
        };
        Update: {
          created_at?: string;
          created_by?: string | null;
          id?: string;
          invoice_id?: string;
          line_total?: number;
          organization_id?: string;
          po_line_id?: string | null;
          product_id?: string;
          quantity?: number;
          serials?: string[] | null;
          tax_amount?: number;
          tax_class_id?: string;
          unit_cost?: number;
        };
        Relationships: [
          {
            foreignKeyName: 'purchase_invoice_lines_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_invoice_lines_invoice_id_organization_id_fkey';
            columns: ['invoice_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'purchase_invoices';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_invoice_lines_invoice_id_organization_id_fkey';
            columns: ['invoice_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_purchase_invoice_balances';
            referencedColumns: ['purchase_invoice_id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_invoice_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'purchase_invoice_lines_po_line_id_organization_id_fkey';
            columns: ['po_line_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'purchase_order_lines';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_invoice_lines_po_line_id_organization_id_fkey';
            columns: ['po_line_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_po_line_received';
            referencedColumns: ['po_line_id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_invoice_lines_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_invoice_lines_tax_class_id_organization_id_fkey';
            columns: ['tax_class_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'tax_classes';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      purchase_invoices: {
        Row: {
          approved_at: string | null;
          approved_by: string | null;
          branch_id: string;
          created_at: string;
          created_by: string | null;
          id: string;
          idempotency_key: string;
          invoice_date: string;
          number: string;
          organization_id: string;
          po_id: string | null;
          rejected_reason: string | null;
          status: Database['public']['Enums']['purchase_invoice_status'];
          subtotal: number;
          supplier_id: string;
          supplier_invoice_no: string | null;
          tax_total: number;
          total: number;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          approved_at?: string | null;
          approved_by?: string | null;
          branch_id: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key: string;
          invoice_date: string;
          number: string;
          organization_id: string;
          po_id?: string | null;
          rejected_reason?: string | null;
          status?: Database['public']['Enums']['purchase_invoice_status'];
          subtotal?: number;
          supplier_id: string;
          supplier_invoice_no?: string | null;
          tax_total?: number;
          total?: number;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          approved_at?: string | null;
          approved_by?: string | null;
          branch_id?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key?: string;
          invoice_date?: string;
          number?: string;
          organization_id?: string;
          po_id?: string | null;
          rejected_reason?: string | null;
          status?: Database['public']['Enums']['purchase_invoice_status'];
          subtotal?: number;
          supplier_id?: string;
          supplier_invoice_no?: string | null;
          tax_total?: number;
          total?: number;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'purchase_invoices_approved_by_fk';
            columns: ['approved_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_invoices_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_invoices_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_invoices_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'purchase_invoices_po_id_organization_id_fkey';
            columns: ['po_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'purchase_orders';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_invoices_supplier_id_organization_id_fkey';
            columns: ['supplier_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'suppliers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_invoices_supplier_id_organization_id_fkey';
            columns: ['supplier_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_supplier_balances';
            referencedColumns: ['supplier_id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_invoices_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      purchase_order_lines: {
        Row: {
          created_at: string;
          created_by: string | null;
          expected_unit_cost: number | null;
          id: string;
          organization_id: string;
          po_id: string;
          product_id: string;
          quantity: number;
        };
        Insert: {
          created_at?: string;
          created_by?: string | null;
          expected_unit_cost?: number | null;
          id?: string;
          organization_id: string;
          po_id: string;
          product_id: string;
          quantity: number;
        };
        Update: {
          created_at?: string;
          created_by?: string | null;
          expected_unit_cost?: number | null;
          id?: string;
          organization_id?: string;
          po_id?: string;
          product_id?: string;
          quantity?: number;
        };
        Relationships: [
          {
            foreignKeyName: 'purchase_order_lines_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_order_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'purchase_order_lines_po_id_organization_id_fkey';
            columns: ['po_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'purchase_orders';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_order_lines_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      purchase_orders: {
        Row: {
          branch_id: string;
          created_at: string;
          created_by: string | null;
          expected_date: string | null;
          id: string;
          idempotency_key: string;
          notes: string | null;
          number: string;
          organization_id: string;
          status: Database['public']['Enums']['po_status'];
          supplier_id: string;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          branch_id: string;
          created_at?: string;
          created_by?: string | null;
          expected_date?: string | null;
          id?: string;
          idempotency_key: string;
          notes?: string | null;
          number: string;
          organization_id: string;
          status?: Database['public']['Enums']['po_status'];
          supplier_id: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          branch_id?: string;
          created_at?: string;
          created_by?: string | null;
          expected_date?: string | null;
          id?: string;
          idempotency_key?: string;
          notes?: string | null;
          number?: string;
          organization_id?: string;
          status?: Database['public']['Enums']['po_status'];
          supplier_id?: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'purchase_orders_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_orders_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_orders_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'purchase_orders_supplier_id_organization_id_fkey';
            columns: ['supplier_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'suppliers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_orders_supplier_id_organization_id_fkey';
            columns: ['supplier_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_supplier_balances';
            referencedColumns: ['supplier_id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_orders_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      purchase_return_lines: {
        Row: {
          created_at: string;
          created_by: string | null;
          id: string;
          invoice_line_id: string;
          line_total: number;
          organization_id: string;
          product_id: string;
          quantity: number;
          return_id: string;
          tax_amount: number;
          unit_cost: number;
          unit_id: string | null;
        };
        Insert: {
          created_at?: string;
          created_by?: string | null;
          id?: string;
          invoice_line_id: string;
          line_total: number;
          organization_id: string;
          product_id: string;
          quantity: number;
          return_id: string;
          tax_amount?: number;
          unit_cost: number;
          unit_id?: string | null;
        };
        Update: {
          created_at?: string;
          created_by?: string | null;
          id?: string;
          invoice_line_id?: string;
          line_total?: number;
          organization_id?: string;
          product_id?: string;
          quantity?: number;
          return_id?: string;
          tax_amount?: number;
          unit_cost?: number;
          unit_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'purchase_return_lines_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_return_lines_invoice_line_id_organization_id_fkey';
            columns: ['invoice_line_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'purchase_invoice_lines';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_return_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'purchase_return_lines_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_return_lines_return_id_organization_id_fkey';
            columns: ['return_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'purchase_returns';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_return_lines_unit_id_organization_id_fkey';
            columns: ['unit_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'units';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      purchase_returns: {
        Row: {
          branch_id: string;
          business_date: string;
          cash_account_id: string | null;
          created_at: string;
          created_by: string | null;
          id: string;
          idempotency_key: string;
          number: string;
          organization_id: string;
          purchase_invoice_id: string;
          reason: string;
          refund_mode: Database['public']['Enums']['purchase_refund_mode'];
          subtotal: number;
          supplier_id: string;
          tax_total: number;
          total: number;
        };
        Insert: {
          branch_id: string;
          business_date: string;
          cash_account_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key: string;
          number: string;
          organization_id: string;
          purchase_invoice_id: string;
          reason: string;
          refund_mode: Database['public']['Enums']['purchase_refund_mode'];
          subtotal: number;
          supplier_id: string;
          tax_total?: number;
          total: number;
        };
        Update: {
          branch_id?: string;
          business_date?: string;
          cash_account_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key?: string;
          number?: string;
          organization_id?: string;
          purchase_invoice_id?: string;
          reason?: string;
          refund_mode?: Database['public']['Enums']['purchase_refund_mode'];
          subtotal?: number;
          supplier_id?: string;
          tax_total?: number;
          total?: number;
        };
        Relationships: [
          {
            foreignKeyName: 'purchase_returns_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_returns_cash_account_id_organization_id_fkey';
            columns: ['cash_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'cash_accounts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_returns_cash_account_id_organization_id_fkey';
            columns: ['cash_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_cash_balances';
            referencedColumns: ['cash_account_id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_returns_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_returns_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'purchase_returns_purchase_invoice_id_organization_id_fkey';
            columns: ['purchase_invoice_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'purchase_invoices';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_returns_purchase_invoice_id_organization_id_fkey';
            columns: ['purchase_invoice_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_purchase_invoice_balances';
            referencedColumns: ['purchase_invoice_id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_returns_supplier_id_organization_id_fkey';
            columns: ['supplier_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'suppliers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_returns_supplier_id_organization_id_fkey';
            columns: ['supplier_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_supplier_balances';
            referencedColumns: ['supplier_id', 'organization_id'];
          },
        ];
      };
      quotation_lines: {
        Row: {
          created_at: string;
          created_by: string | null;
          custom_notes: string | null;
          description: string | null;
          discount_amount: number;
          id: string;
          line_no: number;
          line_total: number;
          organization_id: string;
          product_id: string | null;
          quantity: number;
          quotation_id: string;
          tax_amount: number;
          unit_price: number;
        };
        Insert: {
          created_at?: string;
          created_by?: string | null;
          custom_notes?: string | null;
          description?: string | null;
          discount_amount?: number;
          id?: string;
          line_no: number;
          line_total: number;
          organization_id: string;
          product_id?: string | null;
          quantity: number;
          quotation_id: string;
          tax_amount?: number;
          unit_price: number;
        };
        Update: {
          created_at?: string;
          created_by?: string | null;
          custom_notes?: string | null;
          description?: string | null;
          discount_amount?: number;
          id?: string;
          line_no?: number;
          line_total?: number;
          organization_id?: string;
          product_id?: string | null;
          quantity?: number;
          quotation_id?: string;
          tax_amount?: number;
          unit_price?: number;
        };
        Relationships: [
          {
            foreignKeyName: 'quotation_lines_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'quotation_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'quotation_lines_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'quotation_lines_quotation_id_organization_id_fkey';
            columns: ['quotation_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'quotations';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      quotations: {
        Row: {
          branch_id: string;
          created_at: string;
          created_by: string | null;
          customer_id: string | null;
          discount_total: number;
          id: string;
          idempotency_key: string;
          notes: string | null;
          number: string;
          organization_id: string;
          status: Database['public']['Enums']['quotation_status'];
          subtotal: number;
          tax_total: number;
          total: number;
          updated_at: string;
          updated_by: string | null;
          valid_until: string | null;
        };
        Insert: {
          branch_id: string;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string | null;
          discount_total?: number;
          id?: string;
          idempotency_key: string;
          notes?: string | null;
          number: string;
          organization_id: string;
          status?: Database['public']['Enums']['quotation_status'];
          subtotal?: number;
          tax_total?: number;
          total?: number;
          updated_at?: string;
          updated_by?: string | null;
          valid_until?: string | null;
        };
        Update: {
          branch_id?: string;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string | null;
          discount_total?: number;
          id?: string;
          idempotency_key?: string;
          notes?: string | null;
          number?: string;
          organization_id?: string;
          status?: Database['public']['Enums']['quotation_status'];
          subtotal?: number;
          tax_total?: number;
          total?: number;
          updated_at?: string;
          updated_by?: string | null;
          valid_until?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'quotations_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'quotations_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'quotations_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'quotations_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_customer_exposure';
            referencedColumns: ['customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'quotations_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'quotations_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      role_permissions: {
        Row: {
          permission_key: string;
          role: Database['public']['Enums']['employee_role'];
        };
        Insert: {
          permission_key: string;
          role: Database['public']['Enums']['employee_role'];
        };
        Update: {
          permission_key?: string;
          role?: Database['public']['Enums']['employee_role'];
        };
        Relationships: [
          {
            foreignKeyName: 'role_permissions_permission_key_fkey';
            columns: ['permission_key'];
            isOneToOne: false;
            referencedRelation: 'permissions';
            referencedColumns: ['key'];
          },
        ];
      };
      sale_lines: {
        Row: {
          created_at: string;
          created_by: string | null;
          discount_amount: number;
          id: string;
          line_no: number;
          line_total: number;
          order_line_id: string | null;
          organization_id: string;
          price_override_approval_id: string | null;
          product_id: string;
          quantity: number;
          sale_id: string;
          tax_amount: number;
          tax_class_id: string;
          tax_rate: number;
          unit_cost: number;
          unit_id: string | null;
          unit_price: number;
          warranty_until: string | null;
        };
        Insert: {
          created_at?: string;
          created_by?: string | null;
          discount_amount?: number;
          id?: string;
          line_no: number;
          line_total: number;
          order_line_id?: string | null;
          organization_id: string;
          price_override_approval_id?: string | null;
          product_id: string;
          quantity: number;
          sale_id: string;
          tax_amount?: number;
          tax_class_id: string;
          tax_rate: number;
          unit_cost?: number;
          unit_id?: string | null;
          unit_price: number;
          warranty_until?: string | null;
        };
        Update: {
          created_at?: string;
          created_by?: string | null;
          discount_amount?: number;
          id?: string;
          line_no?: number;
          line_total?: number;
          order_line_id?: string | null;
          organization_id?: string;
          price_override_approval_id?: string | null;
          product_id?: string;
          quantity?: number;
          sale_id?: string;
          tax_amount?: number;
          tax_class_id?: string;
          tax_rate?: number;
          unit_cost?: number;
          unit_id?: string | null;
          unit_price?: number;
          warranty_until?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'sale_lines_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sale_lines_order_line_id_organization_id_fkey';
            columns: ['order_line_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_order_lines';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sale_lines_order_line_id_organization_id_fkey';
            columns: ['order_line_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_order_line_fulfilment';
            referencedColumns: ['order_line_id', 'organization_id'];
          },
          {
            foreignKeyName: 'sale_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'sale_lines_price_override_approval_id_organization_id_fkey';
            columns: ['price_override_approval_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'approvals';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sale_lines_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sale_lines_sale_id_organization_id_fkey';
            columns: ['sale_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sale_lines_sale_id_organization_id_fkey';
            columns: ['sale_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_sale_balances';
            referencedColumns: ['sale_id', 'organization_id'];
          },
          {
            foreignKeyName: 'sale_lines_tax_class_id_organization_id_fkey';
            columns: ['tax_class_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'tax_classes';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sale_lines_unit_id_organization_id_fkey';
            columns: ['unit_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'units';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      sales: {
        Row: {
          branch_id: string;
          business_date: string;
          cost_total: number;
          created_at: string;
          created_by: string | null;
          customer_id: string | null;
          delivery_id: string | null;
          device_id: string | null;
          discount_reason: string | null;
          discount_total: number;
          id: string;
          idempotency_key: string;
          is_b2b: boolean;
          issued_at: string;
          kind: Database['public']['Enums']['sale_kind'];
          number: string;
          offline_created_at: string | null;
          order_id: string | null;
          organization_id: string;
          prices_include_vat: boolean;
          shift_id: string | null;
          subtotal: number;
          tax_total: number;
          total: number;
        };
        Insert: {
          branch_id: string;
          business_date: string;
          cost_total?: number;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string | null;
          delivery_id?: string | null;
          device_id?: string | null;
          discount_reason?: string | null;
          discount_total?: number;
          id?: string;
          idempotency_key: string;
          is_b2b?: boolean;
          issued_at?: string;
          kind?: Database['public']['Enums']['sale_kind'];
          number: string;
          offline_created_at?: string | null;
          order_id?: string | null;
          organization_id: string;
          prices_include_vat: boolean;
          shift_id?: string | null;
          subtotal: number;
          tax_total?: number;
          total: number;
        };
        Update: {
          branch_id?: string;
          business_date?: string;
          cost_total?: number;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string | null;
          delivery_id?: string | null;
          device_id?: string | null;
          discount_reason?: string | null;
          discount_total?: number;
          id?: string;
          idempotency_key?: string;
          is_b2b?: boolean;
          issued_at?: string;
          kind?: Database['public']['Enums']['sale_kind'];
          number?: string;
          offline_created_at?: string | null;
          order_id?: string | null;
          organization_id?: string;
          prices_include_vat?: boolean;
          shift_id?: string | null;
          subtotal?: number;
          tax_total?: number;
          total?: number;
        };
        Relationships: [
          {
            foreignKeyName: 'sales_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_customer_exposure';
            referencedColumns: ['customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_delivery_id_organization_id_fkey';
            columns: ['delivery_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'deliveries';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_device_id_organization_id_fkey';
            columns: ['device_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'devices';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_orders';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_order_balances';
            referencedColumns: ['order_id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'sales_shift_id_organization_id_fkey';
            columns: ['shift_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'shifts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_shift_id_organization_id_fkey';
            columns: ['shift_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_shift_expected_cash';
            referencedColumns: ['shift_id', 'organization_id'];
          },
        ];
      };
      sales_order_lines: {
        Row: {
          created_at: string;
          created_by: string | null;
          custom_notes: string | null;
          discount_amount: number;
          fulfilment: Database['public']['Enums']['fulfilment_mode'];
          id: string;
          line_no: number;
          line_total: number;
          order_id: string;
          organization_id: string;
          po_line_id: string | null;
          product_id: string;
          quantity: number;
          tax_amount: number;
          tax_class_id: string;
          tax_rate: number;
          unit_price: number;
        };
        Insert: {
          created_at?: string;
          created_by?: string | null;
          custom_notes?: string | null;
          discount_amount?: number;
          fulfilment?: Database['public']['Enums']['fulfilment_mode'];
          id?: string;
          line_no: number;
          line_total: number;
          order_id: string;
          organization_id: string;
          po_line_id?: string | null;
          product_id: string;
          quantity: number;
          tax_amount?: number;
          tax_class_id: string;
          tax_rate: number;
          unit_price: number;
        };
        Update: {
          created_at?: string;
          created_by?: string | null;
          custom_notes?: string | null;
          discount_amount?: number;
          fulfilment?: Database['public']['Enums']['fulfilment_mode'];
          id?: string;
          line_no?: number;
          line_total?: number;
          order_id?: string;
          organization_id?: string;
          po_line_id?: string | null;
          product_id?: string;
          quantity?: number;
          tax_amount?: number;
          tax_class_id?: string;
          tax_rate?: number;
          unit_price?: number;
        };
        Relationships: [
          {
            foreignKeyName: 'sales_order_lines_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_order_lines_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_orders';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_order_lines_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_order_balances';
            referencedColumns: ['order_id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_order_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'sales_order_lines_po_line_id_organization_id_fkey';
            columns: ['po_line_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'purchase_order_lines';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_order_lines_po_line_id_organization_id_fkey';
            columns: ['po_line_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_po_line_received';
            referencedColumns: ['po_line_id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_order_lines_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_order_lines_tax_class_id_organization_id_fkey';
            columns: ['tax_class_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'tax_classes';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      sales_orders: {
        Row: {
          branch_id: string;
          cancelled_reason: string | null;
          created_at: string;
          created_by: string | null;
          customer_id: string;
          delivery_address: string | null;
          discount_total: number;
          id: string;
          idempotency_key: string;
          notes: string | null;
          number: string;
          organization_id: string;
          prices_include_vat: boolean;
          quotation_id: string | null;
          status: Database['public']['Enums']['order_status'];
          subtotal: number;
          tax_total: number;
          total: number;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          branch_id: string;
          cancelled_reason?: string | null;
          created_at?: string;
          created_by?: string | null;
          customer_id: string;
          delivery_address?: string | null;
          discount_total?: number;
          id?: string;
          idempotency_key: string;
          notes?: string | null;
          number: string;
          organization_id: string;
          prices_include_vat: boolean;
          quotation_id?: string | null;
          status?: Database['public']['Enums']['order_status'];
          subtotal: number;
          tax_total?: number;
          total: number;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          branch_id?: string;
          cancelled_reason?: string | null;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string;
          delivery_address?: string | null;
          discount_total?: number;
          id?: string;
          idempotency_key?: string;
          notes?: string | null;
          number?: string;
          organization_id?: string;
          prices_include_vat?: boolean;
          quotation_id?: string | null;
          status?: Database['public']['Enums']['order_status'];
          subtotal?: number;
          tax_total?: number;
          total?: number;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'sales_orders_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_orders_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_orders_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_orders_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_customer_exposure';
            referencedColumns: ['customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_orders_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'sales_orders_quotation_id_organization_id_fkey';
            columns: ['quotation_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'quotations';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_orders_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      sales_return_lines: {
        Row: {
          condition: Database['public']['Enums']['return_condition'];
          created_at: string;
          created_by: string | null;
          id: string;
          organization_id: string;
          quantity: number;
          refund_amount: number;
          return_id: string;
          sale_line_id: string;
          tax_amount: number;
          unit_cost: number;
          unit_id: string | null;
        };
        Insert: {
          condition?: Database['public']['Enums']['return_condition'];
          created_at?: string;
          created_by?: string | null;
          id?: string;
          organization_id: string;
          quantity: number;
          refund_amount: number;
          return_id: string;
          sale_line_id: string;
          tax_amount?: number;
          unit_cost?: number;
          unit_id?: string | null;
        };
        Update: {
          condition?: Database['public']['Enums']['return_condition'];
          created_at?: string;
          created_by?: string | null;
          id?: string;
          organization_id?: string;
          quantity?: number;
          refund_amount?: number;
          return_id?: string;
          sale_line_id?: string;
          tax_amount?: number;
          unit_cost?: number;
          unit_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'sales_return_lines_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_return_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'sales_return_lines_return_id_organization_id_fkey';
            columns: ['return_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_returns';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_return_lines_sale_line_id_organization_id_fkey';
            columns: ['sale_line_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sale_lines';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_return_lines_sale_line_id_unit_id_organization_id_fkey';
            columns: ['sale_line_id', 'unit_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sale_lines';
            referencedColumns: ['id', 'unit_id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_return_lines_unit_id_organization_id_fkey';
            columns: ['unit_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'units';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      sales_returns: {
        Row: {
          approval_id: string | null;
          branch_id: string;
          business_date: string;
          created_at: string;
          created_by: string | null;
          exchange_sale_id: string | null;
          id: string;
          idempotency_key: string;
          kind: Database['public']['Enums']['return_kind'];
          number: string;
          organization_id: string;
          reason: string;
          refund_method: Database['public']['Enums']['refund_method'];
          sale_id: string;
          shift_id: string | null;
          subtotal: number;
          tax_total: number;
          total: number;
        };
        Insert: {
          approval_id?: string | null;
          branch_id: string;
          business_date: string;
          created_at?: string;
          created_by?: string | null;
          exchange_sale_id?: string | null;
          id?: string;
          idempotency_key: string;
          kind: Database['public']['Enums']['return_kind'];
          number: string;
          organization_id: string;
          reason: string;
          refund_method: Database['public']['Enums']['refund_method'];
          sale_id: string;
          shift_id?: string | null;
          subtotal: number;
          tax_total?: number;
          total: number;
        };
        Update: {
          approval_id?: string | null;
          branch_id?: string;
          business_date?: string;
          created_at?: string;
          created_by?: string | null;
          exchange_sale_id?: string | null;
          id?: string;
          idempotency_key?: string;
          kind?: Database['public']['Enums']['return_kind'];
          number?: string;
          organization_id?: string;
          reason?: string;
          refund_method?: Database['public']['Enums']['refund_method'];
          sale_id?: string;
          shift_id?: string | null;
          subtotal?: number;
          tax_total?: number;
          total?: number;
        };
        Relationships: [
          {
            foreignKeyName: 'sales_returns_approval_id_organization_id_fkey';
            columns: ['approval_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'approvals';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_returns_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_returns_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_returns_exchange_sale_id_organization_id_fkey';
            columns: ['exchange_sale_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_returns_exchange_sale_id_organization_id_fkey';
            columns: ['exchange_sale_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_sale_balances';
            referencedColumns: ['sale_id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_returns_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'sales_returns_sale_id_organization_id_fkey';
            columns: ['sale_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_returns_sale_id_organization_id_fkey';
            columns: ['sale_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_sale_balances';
            referencedColumns: ['sale_id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_returns_shift_id_organization_id_fkey';
            columns: ['shift_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'shifts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_returns_shift_id_organization_id_fkey';
            columns: ['shift_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_shift_expected_cash';
            referencedColumns: ['shift_id', 'organization_id'];
          },
        ];
      };
      schedule_lines: {
        Row: {
          amount: number | null;
          contract_id: string;
          created_at: string;
          created_by: string | null;
          due_date: string;
          id: string;
          organization_id: string;
          principal: number;
          profit: number;
          seq: number;
          superseded: boolean;
          version: number;
        };
        Insert: {
          amount?: never;
          contract_id: string;
          created_at?: string;
          created_by?: string | null;
          due_date: string;
          id?: string;
          organization_id: string;
          principal: number;
          profit: number;
          seq: number;
          superseded?: boolean;
          version: number;
        };
        Update: {
          amount?: never;
          contract_id?: string;
          created_at?: string;
          created_by?: string | null;
          due_date?: string;
          id?: string;
          organization_id?: string;
          principal?: number;
          profit?: number;
          seq?: number;
          superseded?: boolean;
          version?: number;
        };
        Relationships: [
          {
            foreignKeyName: 'schedule_lines_contract_id_organization_id_fkey';
            columns: ['contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'contracts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'schedule_lines_contract_id_organization_id_fkey';
            columns: ['contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_contract_balances';
            referencedColumns: ['contract_id', 'organization_id'];
          },
          {
            foreignKeyName: 'schedule_lines_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'schedule_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      shifts: {
        Row: {
          branch_id: string;
          closed_at: string | null;
          closed_by: string | null;
          count_breakdown: Json | null;
          counted_cash: number | null;
          created_at: string;
          created_by: string | null;
          device_id: string | null;
          difference_reason: string | null;
          drawer_account_id: string;
          employee_id: string;
          expected_cash: number | null;
          id: string;
          idempotency_key: string;
          number: string;
          opened_at: string;
          opening_float: number;
          organization_id: string;
          status: Database['public']['Enums']['shift_status'];
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          branch_id: string;
          closed_at?: string | null;
          closed_by?: string | null;
          count_breakdown?: Json | null;
          counted_cash?: number | null;
          created_at?: string;
          created_by?: string | null;
          device_id?: string | null;
          difference_reason?: string | null;
          drawer_account_id: string;
          employee_id: string;
          expected_cash?: number | null;
          id?: string;
          idempotency_key: string;
          number: string;
          opened_at?: string;
          opening_float?: number;
          organization_id: string;
          status?: Database['public']['Enums']['shift_status'];
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          branch_id?: string;
          closed_at?: string | null;
          closed_by?: string | null;
          count_breakdown?: Json | null;
          counted_cash?: number | null;
          created_at?: string;
          created_by?: string | null;
          device_id?: string | null;
          difference_reason?: string | null;
          drawer_account_id?: string;
          employee_id?: string;
          expected_cash?: number | null;
          id?: string;
          idempotency_key?: string;
          number?: string;
          opened_at?: string;
          opening_float?: number;
          organization_id?: string;
          status?: Database['public']['Enums']['shift_status'];
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'shifts_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'shifts_closed_by_fk';
            columns: ['closed_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'shifts_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'shifts_device_id_organization_id_fkey';
            columns: ['device_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'devices';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'shifts_drawer_account_id_organization_id_fkey';
            columns: ['drawer_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'cash_accounts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'shifts_drawer_account_id_organization_id_fkey';
            columns: ['drawer_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_cash_balances';
            referencedColumns: ['cash_account_id', 'organization_id'];
          },
          {
            foreignKeyName: 'shifts_employee_id_organization_id_fkey';
            columns: ['employee_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'shifts_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'shifts_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      stock_adjustment_lines: {
        Row: {
          adjustment_id: string;
          created_at: string;
          created_by: string | null;
          id: string;
          organization_id: string;
          product_id: string;
          quantity: number;
          unit_id: string | null;
        };
        Insert: {
          adjustment_id: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          organization_id: string;
          product_id: string;
          quantity: number;
          unit_id?: string | null;
        };
        Update: {
          adjustment_id?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          organization_id?: string;
          product_id?: string;
          quantity?: number;
          unit_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'stock_adjustment_lines_adjustment_id_organization_id_fkey';
            columns: ['adjustment_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'stock_adjustments';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_adjustment_lines_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_adjustment_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'stock_adjustment_lines_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_adjustment_lines_unit_id_organization_id_fkey';
            columns: ['unit_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'units';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      stock_adjustments: {
        Row: {
          branch_id: string;
          count_id: string | null;
          created_at: string;
          created_by: string | null;
          id: string;
          idempotency_key: string;
          note: string | null;
          number: string;
          organization_id: string;
          reason: Database['public']['Enums']['adjustment_reason'];
        };
        Insert: {
          branch_id: string;
          count_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key: string;
          note?: string | null;
          number: string;
          organization_id: string;
          reason: Database['public']['Enums']['adjustment_reason'];
        };
        Update: {
          branch_id?: string;
          count_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key?: string;
          note?: string | null;
          number?: string;
          organization_id?: string;
          reason?: Database['public']['Enums']['adjustment_reason'];
        };
        Relationships: [
          {
            foreignKeyName: 'stock_adjustments_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_adjustments_count_id_organization_id_fkey';
            columns: ['count_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'stock_counts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_adjustments_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_adjustments_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      stock_count_lines: {
        Row: {
          count_id: string;
          counted_qty: number | null;
          created_at: string;
          created_by: string | null;
          expected_qty: number;
          id: string;
          organization_id: string;
          product_id: string;
          unit_id: string | null;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          count_id: string;
          counted_qty?: number | null;
          created_at?: string;
          created_by?: string | null;
          expected_qty: number;
          id?: string;
          organization_id: string;
          product_id: string;
          unit_id?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          count_id?: string;
          counted_qty?: number | null;
          created_at?: string;
          created_by?: string | null;
          expected_qty?: number;
          id?: string;
          organization_id?: string;
          product_id?: string;
          unit_id?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'stock_count_lines_count_id_organization_id_fkey';
            columns: ['count_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'stock_counts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_count_lines_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_count_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'stock_count_lines_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_count_lines_unit_id_organization_id_fkey';
            columns: ['unit_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'units';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_count_lines_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      stock_counts: {
        Row: {
          branch_id: string;
          category_id: string | null;
          created_at: string;
          created_by: string | null;
          id: string;
          idempotency_key: string;
          number: string;
          organization_id: string;
          posted_at: string | null;
          posted_by: string | null;
          status: Database['public']['Enums']['count_status'];
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          branch_id: string;
          category_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key: string;
          number: string;
          organization_id: string;
          posted_at?: string | null;
          posted_by?: string | null;
          status?: Database['public']['Enums']['count_status'];
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          branch_id?: string;
          category_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key?: string;
          number?: string;
          organization_id?: string;
          posted_at?: string | null;
          posted_by?: string | null;
          status?: Database['public']['Enums']['count_status'];
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'stock_counts_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_counts_category_id_organization_id_fkey';
            columns: ['category_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'categories';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_counts_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_counts_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'stock_counts_posted_by_fk';
            columns: ['posted_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_counts_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      stock_levels: {
        Row: {
          branch_id: string;
          on_hand: number;
          organization_id: string;
          product_id: string;
          reserved: number;
          stock_state: Database['public']['Enums']['stock_state'];
          updated_at: string;
        };
        Insert: {
          branch_id: string;
          on_hand?: number;
          organization_id: string;
          product_id: string;
          reserved?: number;
          stock_state?: Database['public']['Enums']['stock_state'];
          updated_at?: string;
        };
        Update: {
          branch_id?: string;
          on_hand?: number;
          organization_id?: string;
          product_id?: string;
          reserved?: number;
          stock_state?: Database['public']['Enums']['stock_state'];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'stock_levels_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_levels_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'stock_levels_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      stock_movements: {
        Row: {
          branch_id: string;
          business_date: string;
          created_at: string;
          created_by: string | null;
          id: string;
          organization_id: string;
          product_id: string;
          quantity: number;
          reverses_movement_id: string | null;
          source_id: string;
          source_line_id: string | null;
          source_type: Database['public']['Enums']['doc_type'];
          stock_state: Database['public']['Enums']['stock_state'];
          type: Database['public']['Enums']['stock_movement_type'];
          unit_cost: number;
          unit_id: string | null;
        };
        Insert: {
          branch_id: string;
          business_date: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          organization_id: string;
          product_id: string;
          quantity: number;
          reverses_movement_id?: string | null;
          source_id: string;
          source_line_id?: string | null;
          source_type: Database['public']['Enums']['doc_type'];
          stock_state?: Database['public']['Enums']['stock_state'];
          type: Database['public']['Enums']['stock_movement_type'];
          unit_cost?: number;
          unit_id?: string | null;
        };
        Update: {
          branch_id?: string;
          business_date?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          organization_id?: string;
          product_id?: string;
          quantity?: number;
          reverses_movement_id?: string | null;
          source_id?: string;
          source_line_id?: string | null;
          source_type?: Database['public']['Enums']['doc_type'];
          stock_state?: Database['public']['Enums']['stock_state'];
          type?: Database['public']['Enums']['stock_movement_type'];
          unit_cost?: number;
          unit_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'stock_movements_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_movements_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_movements_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'stock_movements_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_movements_reverses_movement_id_organization_id_fkey';
            columns: ['reverses_movement_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'stock_movements';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_movements_unit_id_organization_id_fkey';
            columns: ['unit_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'units';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      stock_reservations: {
        Row: {
          branch_id: string;
          created_at: string;
          created_by: string | null;
          id: string;
          order_line_id: string;
          organization_id: string;
          product_id: string;
          quantity: number;
          released_at: string | null;
          status: Database['public']['Enums']['reservation_status'];
          unit_id: string | null;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          branch_id: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          order_line_id: string;
          organization_id: string;
          product_id: string;
          quantity: number;
          released_at?: string | null;
          status?: Database['public']['Enums']['reservation_status'];
          unit_id?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          branch_id?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          order_line_id?: string;
          organization_id?: string;
          product_id?: string;
          quantity?: number;
          released_at?: string | null;
          status?: Database['public']['Enums']['reservation_status'];
          unit_id?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'stock_reservations_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_reservations_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_reservations_order_line_fk';
            columns: ['order_line_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_order_lines';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_reservations_order_line_fk';
            columns: ['order_line_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_order_line_fulfilment';
            referencedColumns: ['order_line_id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_reservations_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'stock_reservations_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_reservations_unit_id_organization_id_fkey';
            columns: ['unit_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'units';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_reservations_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      stock_transfer_lines: {
        Row: {
          created_at: string;
          created_by: string | null;
          discrepancy_reason: string | null;
          id: string;
          organization_id: string;
          product_id: string;
          qty_received: number | null;
          qty_sent: number;
          transfer_id: string;
          unit_id: string | null;
        };
        Insert: {
          created_at?: string;
          created_by?: string | null;
          discrepancy_reason?: string | null;
          id?: string;
          organization_id: string;
          product_id: string;
          qty_received?: number | null;
          qty_sent: number;
          transfer_id: string;
          unit_id?: string | null;
        };
        Update: {
          created_at?: string;
          created_by?: string | null;
          discrepancy_reason?: string | null;
          id?: string;
          organization_id?: string;
          product_id?: string;
          qty_received?: number | null;
          qty_sent?: number;
          transfer_id?: string;
          unit_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'stock_transfer_lines_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_transfer_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'stock_transfer_lines_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_transfer_lines_transfer_id_organization_id_fkey';
            columns: ['transfer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'stock_transfers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_transfer_lines_unit_id_organization_id_fkey';
            columns: ['unit_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'units';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      stock_transfers: {
        Row: {
          created_at: string;
          created_by: string | null;
          from_branch_id: string;
          id: string;
          idempotency_key: string;
          notes: string | null;
          number: string;
          organization_id: string;
          received_at: string | null;
          received_by: string | null;
          sent_at: string | null;
          sent_by: string | null;
          status: Database['public']['Enums']['transfer_status'];
          to_branch_id: string;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          created_at?: string;
          created_by?: string | null;
          from_branch_id: string;
          id?: string;
          idempotency_key: string;
          notes?: string | null;
          number: string;
          organization_id: string;
          received_at?: string | null;
          received_by?: string | null;
          sent_at?: string | null;
          sent_by?: string | null;
          status?: Database['public']['Enums']['transfer_status'];
          to_branch_id: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          created_at?: string;
          created_by?: string | null;
          from_branch_id?: string;
          id?: string;
          idempotency_key?: string;
          notes?: string | null;
          number?: string;
          organization_id?: string;
          received_at?: string | null;
          received_by?: string | null;
          sent_at?: string | null;
          sent_by?: string | null;
          status?: Database['public']['Enums']['transfer_status'];
          to_branch_id?: string;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'stock_transfers_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_transfers_from_branch_id_organization_id_fkey';
            columns: ['from_branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_transfers_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'stock_transfers_received_by_fk';
            columns: ['received_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_transfers_sent_by_fk';
            columns: ['sent_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_transfers_to_branch_id_organization_id_fkey';
            columns: ['to_branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_transfers_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      store_credit_balances: {
        Row: {
          balance: number;
          customer_id: string;
          organization_id: string;
          updated_at: string;
        };
        Insert: {
          balance?: number;
          customer_id: string;
          organization_id: string;
          updated_at?: string;
        };
        Update: {
          balance?: number;
          customer_id?: string;
          organization_id?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'store_credit_balances_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'store_credit_balances_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_customer_exposure';
            referencedColumns: ['customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'store_credit_balances_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      store_credit_movements: {
        Row: {
          amount: number;
          branch_id: string;
          business_date: string;
          created_at: string;
          created_by: string | null;
          customer_id: string;
          id: string;
          organization_id: string;
          source_id: string;
          source_type: Database['public']['Enums']['doc_type'];
        };
        Insert: {
          amount: number;
          branch_id: string;
          business_date: string;
          created_at?: string;
          created_by?: string | null;
          customer_id: string;
          id?: string;
          organization_id: string;
          source_id: string;
          source_type: Database['public']['Enums']['doc_type'];
        };
        Update: {
          amount?: number;
          branch_id?: string;
          business_date?: string;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string;
          id?: string;
          organization_id?: string;
          source_id?: string;
          source_type?: Database['public']['Enums']['doc_type'];
        };
        Relationships: [
          {
            foreignKeyName: 'store_credit_movements_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'store_credit_movements_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'store_credit_movements_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'store_credit_movements_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_customer_exposure';
            referencedColumns: ['customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'store_credit_movements_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      subscription_payments: {
        Row: {
          amount: number;
          created_at: string;
          id: string;
          idempotency_key: string | null;
          organization_id: string;
          paid_at: string;
          period_end: string;
          period_start: string;
          plan_key: string;
          recorded_by_admin: string | null;
          reference: string | null;
        };
        Insert: {
          amount: number;
          created_at?: string;
          id?: string;
          idempotency_key?: string | null;
          organization_id: string;
          paid_at?: string;
          period_end: string;
          period_start: string;
          plan_key: string;
          recorded_by_admin?: string | null;
          reference?: string | null;
        };
        Update: {
          amount?: number;
          created_at?: string;
          id?: string;
          idempotency_key?: string | null;
          organization_id?: string;
          paid_at?: string;
          period_end?: string;
          period_start?: string;
          plan_key?: string;
          recorded_by_admin?: string | null;
          reference?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'subscription_payments_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'subscription_payments_plan_key_fkey';
            columns: ['plan_key'];
            isOneToOne: false;
            referencedRelation: 'plans';
            referencedColumns: ['key'];
          },
          {
            foreignKeyName: 'subscription_payments_recorded_by_admin_fkey';
            columns: ['recorded_by_admin'];
            isOneToOne: false;
            referencedRelation: 'super_admins';
            referencedColumns: ['auth_user_id'];
          },
        ];
      };
      super_admins: {
        Row: {
          auth_user_id: string;
          created_at: string;
          email: string;
          full_name: string;
          is_active: boolean;
        };
        Insert: {
          auth_user_id: string;
          created_at?: string;
          email: string;
          full_name: string;
          is_active?: boolean;
        };
        Update: {
          auth_user_id?: string;
          created_at?: string;
          email?: string;
          full_name?: string;
          is_active?: boolean;
        };
        Relationships: [];
      };
      supplier_payment_allocations: {
        Row: {
          amount: number;
          created_at: string;
          created_by: string | null;
          id: string;
          organization_id: string;
          purchase_invoice_id: string;
          supplier_payment_id: string;
        };
        Insert: {
          amount: number;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          organization_id: string;
          purchase_invoice_id: string;
          supplier_payment_id: string;
        };
        Update: {
          amount?: number;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          organization_id?: string;
          purchase_invoice_id?: string;
          supplier_payment_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'supplier_payment_allocations_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'supplier_payment_allocations_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'supplier_payment_allocations_purchase_invoice_id_organizat_fkey';
            columns: ['purchase_invoice_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'purchase_invoices';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'supplier_payment_allocations_purchase_invoice_id_organizat_fkey';
            columns: ['purchase_invoice_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_purchase_invoice_balances';
            referencedColumns: ['purchase_invoice_id', 'organization_id'];
          },
          {
            foreignKeyName: 'supplier_payment_allocations_supplier_payment_id_organizat_fkey';
            columns: ['supplier_payment_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'supplier_payments';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      supplier_payments: {
        Row: {
          amount: number;
          branch_id: string;
          business_date: string;
          cash_account_id: string;
          created_at: string;
          created_by: string | null;
          id: string;
          idempotency_key: string;
          number: string;
          organization_id: string;
          paid_at: string;
          reason: string | null;
          reference: string | null;
          reverses_payment_id: string | null;
          supplier_id: string;
        };
        Insert: {
          amount: number;
          branch_id: string;
          business_date: string;
          cash_account_id: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key: string;
          number: string;
          organization_id: string;
          paid_at?: string;
          reason?: string | null;
          reference?: string | null;
          reverses_payment_id?: string | null;
          supplier_id: string;
        };
        Update: {
          amount?: number;
          branch_id?: string;
          business_date?: string;
          cash_account_id?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          idempotency_key?: string;
          number?: string;
          organization_id?: string;
          paid_at?: string;
          reason?: string | null;
          reference?: string | null;
          reverses_payment_id?: string | null;
          supplier_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'supplier_payments_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'supplier_payments_cash_account_id_organization_id_fkey';
            columns: ['cash_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'cash_accounts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'supplier_payments_cash_account_id_organization_id_fkey';
            columns: ['cash_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_cash_balances';
            referencedColumns: ['cash_account_id', 'organization_id'];
          },
          {
            foreignKeyName: 'supplier_payments_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'supplier_payments_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'supplier_payments_reverses_payment_id_organization_id_fkey';
            columns: ['reverses_payment_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'supplier_payments';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'supplier_payments_supplier_id_organization_id_fkey';
            columns: ['supplier_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'suppliers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'supplier_payments_supplier_id_organization_id_fkey';
            columns: ['supplier_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_supplier_balances';
            referencedColumns: ['supplier_id', 'organization_id'];
          },
        ];
      };
      suppliers: {
        Row: {
          address: string | null;
          archived_at: string | null;
          created_at: string;
          created_by: string | null;
          id: string;
          name: string;
          notes: string | null;
          organization_id: string;
          payment_terms_days: number;
          phone: string | null;
          tax_registration_no: string | null;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          address?: string | null;
          archived_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          name: string;
          notes?: string | null;
          organization_id: string;
          payment_terms_days?: number;
          phone?: string | null;
          tax_registration_no?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          address?: string | null;
          archived_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          name?: string;
          notes?: string | null;
          organization_id?: string;
          payment_terms_days?: number;
          phone?: string | null;
          tax_registration_no?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'suppliers_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'suppliers_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'suppliers_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      tax_classes: {
        Row: {
          archived_at: string | null;
          created_at: string;
          created_by: string | null;
          eta_subtype: string;
          eta_tax_type: string;
          id: string;
          kind: Database['public']['Enums']['tax_kind'];
          name: string;
          organization_id: string;
          rate: number;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          archived_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          eta_subtype?: string;
          eta_tax_type?: string;
          id?: string;
          kind?: Database['public']['Enums']['tax_kind'];
          name: string;
          organization_id: string;
          rate: number;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          archived_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          eta_subtype?: string;
          eta_tax_type?: string;
          id?: string;
          kind?: Database['public']['Enums']['tax_kind'];
          name?: string;
          organization_id?: string;
          rate?: number;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'tax_classes_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'tax_classes_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'tax_classes_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      units: {
        Row: {
          branch_id: string;
          cost: number;
          created_at: string;
          created_by: string | null;
          id: string;
          organization_id: string;
          product_id: string;
          purchase_invoice_line_id: string | null;
          serial: string;
          status: Database['public']['Enums']['unit_status'];
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          branch_id: string;
          cost: number;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          organization_id: string;
          product_id: string;
          purchase_invoice_line_id?: string | null;
          serial: string;
          status?: Database['public']['Enums']['unit_status'];
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          branch_id?: string;
          cost?: number;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          organization_id?: string;
          product_id?: string;
          purchase_invoice_line_id?: string | null;
          serial?: string;
          status?: Database['public']['Enums']['unit_status'];
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'units_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'units_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'units_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'units_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'units_purchase_invoice_line_id_organization_id_fkey';
            columns: ['purchase_invoice_line_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'purchase_invoice_lines';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'units_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      warranty_claims: {
        Row: {
          branch_id: string;
          closed_at: string | null;
          created_at: string;
          created_by: string | null;
          customer_id: string | null;
          id: string;
          idempotency_key: string;
          issue: string;
          number: string;
          organization_id: string;
          replacement_unit_id: string | null;
          resolution: string | null;
          sale_line_id: string;
          status: Database['public']['Enums']['claim_status'];
          unit_id: string | null;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          branch_id: string;
          closed_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string | null;
          id?: string;
          idempotency_key: string;
          issue: string;
          number: string;
          organization_id: string;
          replacement_unit_id?: string | null;
          resolution?: string | null;
          sale_line_id: string;
          status?: Database['public']['Enums']['claim_status'];
          unit_id?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          branch_id?: string;
          closed_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string | null;
          id?: string;
          idempotency_key?: string;
          issue?: string;
          number?: string;
          organization_id?: string;
          replacement_unit_id?: string | null;
          resolution?: string | null;
          sale_line_id?: string;
          status?: Database['public']['Enums']['claim_status'];
          unit_id?: string | null;
          updated_at?: string;
          updated_by?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'warranty_claims_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'warranty_claims_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'warranty_claims_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'warranty_claims_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_customer_exposure';
            referencedColumns: ['customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'warranty_claims_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'warranty_claims_replacement_unit_id_organization_id_fkey';
            columns: ['replacement_unit_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'units';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'warranty_claims_sale_line_id_organization_id_fkey';
            columns: ['sale_line_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sale_lines';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'warranty_claims_unit_id_organization_id_fkey';
            columns: ['unit_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'units';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'warranty_claims_updated_by_fk';
            columns: ['updated_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
    };
    Views: {
      v_cash_balances: {
        Row: {
          balance: number | null;
          branch_id: string | null;
          cash_account_id: string | null;
          employee_id: string | null;
          is_active: boolean | null;
          kind: Database['public']['Enums']['cash_account_kind'] | null;
          name: string | null;
          organization_id: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'cash_accounts_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_accounts_employee_id_organization_id_fkey';
            columns: ['employee_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'cash_accounts_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      v_contract_balances: {
        Row: {
          branch_id: string | null;
          contract_id: string | null;
          customer_id: string | null;
          fees_due: number | null;
          financed_amount: number | null;
          markup_amount: number | null;
          max_days_late: number | null;
          next_due_date: string | null;
          number: string | null;
          organization_id: string | null;
          overdue_amount: number | null;
          overdue_lines: number | null;
          paid: number | null;
          paid_principal: number | null;
          paid_profit: number | null;
          principal_outstanding: number | null;
          remaining: number | null;
          status: Database['public']['Enums']['contract_status'] | null;
          total_payable: number | null;
        };
        Relationships: [
          {
            foreignKeyName: 'contracts_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contracts_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'contracts_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_customer_exposure';
            referencedColumns: ['customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'contracts_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      v_customer_exposure: {
        Row: {
          available_credit: number | null;
          credit_limit: number | null;
          customer_id: string | null;
          exposure: number | null;
          fees_due: number | null;
          open_contracts: number | null;
          organization_id: string | null;
          overdue_amount: number | null;
          status: Database['public']['Enums']['customer_status'] | null;
          store_credit: number | null;
        };
        Relationships: [
          {
            foreignKeyName: 'customers_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      v_effective_allocations: {
        Row: {
          amount: number | null;
          branch_id: string | null;
          business_date: string | null;
          charge_id: string | null;
          contract_id: string | null;
          created_at: string | null;
          created_by: string | null;
          customer_id: string | null;
          direction: Database['public']['Enums']['payment_direction'] | null;
          id: string | null;
          method: Database['public']['Enums']['payment_method'] | null;
          order_id: string | null;
          organization_id: string | null;
          paid_at: string | null;
          payment_id: string | null;
          principal_amount: number | null;
          profit_amount: number | null;
          return_id: string | null;
          sale_id: string | null;
          schedule_line_id: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'payment_allocations_charge_id_contract_id_organization_id_fkey';
            columns: ['charge_id', 'contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'charges';
            referencedColumns: ['id', 'contract_id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_orders';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_order_balances';
            referencedColumns: ['order_id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'payment_allocations_payment_id_organization_id_fkey';
            columns: ['payment_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'payments';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_return_id_organization_id_fkey';
            columns: ['return_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_returns';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_sale_id_organization_id_fkey';
            columns: ['sale_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_sale_id_organization_id_fkey';
            columns: ['sale_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_sale_balances';
            referencedColumns: ['sale_id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_schedule_line_id_contract_id_organizat_fkey';
            columns: ['schedule_line_id', 'contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'schedule_lines';
            referencedColumns: ['id', 'contract_id', 'organization_id'];
          },
          {
            foreignKeyName: 'payment_allocations_schedule_line_id_contract_id_organizat_fkey';
            columns: ['schedule_line_id', 'contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_schedule_line_status';
            referencedColumns: ['schedule_line_id', 'contract_id', 'organization_id'];
          },
        ];
      };
      v_order_balances: {
        Row: {
          branch_id: string | null;
          customer_id: string | null;
          delivered_value: number | null;
          deposits_paid: number | null;
          financed: number | null;
          order_id: string | null;
          organization_id: string | null;
          status: Database['public']['Enums']['order_status'] | null;
          total: number | null;
          unpaid: number | null;
        };
        Relationships: [
          {
            foreignKeyName: 'sales_orders_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_orders_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_orders_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_customer_exposure';
            referencedColumns: ['customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_orders_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      v_order_line_fulfilment: {
        Row: {
          delivered: number | null;
          fulfilment: Database['public']['Enums']['fulfilment_mode'] | null;
          order_id: string | null;
          order_line_id: string | null;
          organization_id: string | null;
          product_id: string | null;
          quantity: number | null;
          remaining: number | null;
          reserved: number | null;
        };
        Relationships: [
          {
            foreignKeyName: 'sales_order_lines_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_orders';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_order_lines_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_order_balances';
            referencedColumns: ['order_id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_order_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'sales_order_lines_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      v_po_line_received: {
        Row: {
          organization_id: string | null;
          po_id: string | null;
          po_line_id: string | null;
          product_id: string | null;
          quantity: number | null;
          received: number | null;
          remaining: number | null;
        };
        Relationships: [
          {
            foreignKeyName: 'purchase_order_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'purchase_order_lines_po_id_organization_id_fkey';
            columns: ['po_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'purchase_orders';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_order_lines_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      v_purchase_invoice_balances: {
        Row: {
          branch_id: string | null;
          invoice_date: string | null;
          organization_id: string | null;
          outstanding: number | null;
          paid: number | null;
          purchase_invoice_id: string | null;
          returned_credit: number | null;
          supplier_id: string | null;
          total: number | null;
        };
        Relationships: [
          {
            foreignKeyName: 'purchase_invoices_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_invoices_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'purchase_invoices_supplier_id_organization_id_fkey';
            columns: ['supplier_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'suppliers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'purchase_invoices_supplier_id_organization_id_fkey';
            columns: ['supplier_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_supplier_balances';
            referencedColumns: ['supplier_id', 'organization_id'];
          },
        ];
      };
      v_receivables_aging: {
        Row: {
          branch_id: string | null;
          contract_id: string | null;
          customer_id: string | null;
          fees_due: number | null;
          late_1_30: number | null;
          late_31_60: number | null;
          late_61_90: number | null;
          late_90_plus: number | null;
          not_yet_due: number | null;
          organization_id: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'schedule_lines_contract_id_organization_id_fkey';
            columns: ['contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'contracts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'schedule_lines_contract_id_organization_id_fkey';
            columns: ['contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_contract_balances';
            referencedColumns: ['contract_id', 'organization_id'];
          },
          {
            foreignKeyName: 'schedule_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      v_sale_balances: {
        Row: {
          branch_id: string | null;
          customer_id: string | null;
          financed: number | null;
          kind: Database['public']['Enums']['sale_kind'] | null;
          order_id: string | null;
          organization_id: string | null;
          paid: number | null;
          returned: number | null;
          sale_id: string | null;
          total: number | null;
          unpaid: number | null;
        };
        Relationships: [
          {
            foreignKeyName: 'sales_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_customer_id_organization_id_fkey';
            columns: ['customer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_customer_exposure';
            referencedColumns: ['customer_id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'sales_orders';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_order_id_organization_id_fkey';
            columns: ['order_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_order_balances';
            referencedColumns: ['order_id', 'organization_id'];
          },
          {
            foreignKeyName: 'sales_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      v_schedule_line_status: {
        Row: {
          amount: number | null;
          contract_id: string | null;
          days_late: number | null;
          due_date: string | null;
          fees_due: number | null;
          organization_id: string | null;
          paid: number | null;
          paid_principal: number | null;
          paid_profit: number | null;
          principal: number | null;
          principal_remaining: number | null;
          profit: number | null;
          remaining: number | null;
          schedule_line_id: string | null;
          seq: number | null;
          status: string | null;
          superseded: boolean | null;
          version: number | null;
        };
        Relationships: [
          {
            foreignKeyName: 'schedule_lines_contract_id_organization_id_fkey';
            columns: ['contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'contracts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'schedule_lines_contract_id_organization_id_fkey';
            columns: ['contract_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_contract_balances';
            referencedColumns: ['contract_id', 'organization_id'];
          },
          {
            foreignKeyName: 'schedule_lines_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      v_shift_expected_cash: {
        Row: {
          branch_id: string | null;
          cash_in: number | null;
          cash_out: number | null;
          counted_cash: number | null;
          difference: number | null;
          drawer_account_id: string | null;
          employee_id: string | null;
          expected_cash: number | null;
          opening_float: number | null;
          organization_id: string | null;
          shift_id: string | null;
          status: Database['public']['Enums']['shift_status'] | null;
        };
        Relationships: [
          {
            foreignKeyName: 'shifts_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'shifts_drawer_account_id_organization_id_fkey';
            columns: ['drawer_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'cash_accounts';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'shifts_drawer_account_id_organization_id_fkey';
            columns: ['drawer_account_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'v_cash_balances';
            referencedColumns: ['cash_account_id', 'organization_id'];
          },
          {
            foreignKeyName: 'shifts_employee_id_organization_id_fkey';
            columns: ['employee_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'shifts_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      v_stock_available: {
        Row: {
          available: number | null;
          branch_id: string | null;
          damaged: number | null;
          is_low_stock: boolean | null;
          min_stock: number | null;
          on_hand: number | null;
          organization_id: string | null;
          product_id: string | null;
          reserved: number | null;
        };
        Relationships: [
          {
            foreignKeyName: 'stock_levels_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_levels_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'stock_levels_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      v_stock_in_transit: {
        Row: {
          branch_id: string | null;
          in_transit: number | null;
          organization_id: string | null;
          product_id: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'stock_transfers_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'stock_transfers_to_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      v_supplier_balances: {
        Row: {
          balance: number | null;
          invoiced: number | null;
          name: string | null;
          organization_id: string | null;
          paid: number | null;
          returned_credit: number | null;
          supplier_id: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'suppliers_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      v_unit_history: {
        Row: {
          branch_id: string | null;
          business_date: string | null;
          created_at: string | null;
          created_by: string | null;
          organization_id: string | null;
          product_id: string | null;
          quantity: number | null;
          serial: string | null;
          source_id: string | null;
          source_type: Database['public']['Enums']['doc_type'] | null;
          type: Database['public']['Enums']['stock_movement_type'] | null;
          unit_cost: number | null;
          unit_id: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'stock_movements_branch_id_organization_id_fkey';
            columns: ['branch_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_movements_created_by_fk';
            columns: ['created_by', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_movements_org_fk';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'stock_movements_product_id_organization_id_fkey';
            columns: ['product_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'stock_movements_unit_id_organization_id_fkey';
            columns: ['unit_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'units';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
    };
    Functions: {
      accept_invite: { Args: { p_auth_user_id: string; p_token_hash: string }; Returns: Json };
      admin_change_plan: {
        Args: { p_organization_id: string; p_plan_key: string; p_reason: string };
        Returns: undefined;
      };
      admin_get_subscription: { Args: { p_organization_id: string }; Returns: Json };
      admin_list_organizations: {
        Args: {
          p_limit?: number;
          p_offset?: number;
          p_search?: string;
          p_status?: Database['public']['Enums']['org_status'];
        };
        Returns: {
          created_at: string;
          id: string;
          name: string;
          owner_email: string;
          owner_full_name: string;
          owner_invite_status: string;
          plan_key: string;
          status: Database['public']['Enums']['org_status'];
          subscription_end: string;
          subscription_state: string;
          tenant_slug: string;
          total_count: number;
        }[];
      };
      admin_provision_organization: {
        Args: {
          p_branch_name?: string;
          p_expires_at?: string;
          p_name: string;
          p_owner_email: string;
          p_owner_full_name: string;
          p_owner_phone?: string;
          p_plan_key: string;
          p_tenant_slug: string;
          p_token_hash?: string;
        };
        Returns: Json;
      };
      admin_record_subscription_payment: {
        Args: {
          p_amount: string;
          p_extend?: boolean;
          p_idempotency_key?: string;
          p_organization_id: string;
          p_period_end: string;
          p_period_start: string;
          p_reference: string | null;
        };
        Returns: string;
      };
      admin_resend_owner_invite: {
        Args: { p_expires_at: string; p_organization_id: string; p_token_hash: string };
        Returns: Json;
      };
      admin_set_organization_status: {
        Args: {
          p_organization_id: string;
          p_reason?: string;
          p_status: Database['public']['Enums']['org_status'];
        };
        Returns: undefined;
      };
      admin_set_subscription_dates: {
        Args: {
          p_end: string | null;
          p_organization_id: string;
          p_reason: string;
          p_start: string;
        };
        Returns: undefined;
      };
      auth_clear_must_change_password: { Args: { p_auth_user_id: string }; Returns: number };
      auth_record_login: { Args: Record<PropertyKey, never>; Returns: undefined };
      auth_record_logout: { Args: Record<PropertyKey, never>; Returns: undefined };
      auth_record_password_change: { Args: Record<PropertyKey, never>; Returns: undefined };
      branch_deactivation_check: { Args: { p_branch_id: string }; Returns: Json };
      cancel_stock_count: { Args: { p_count_id: string }; Returns: Json };
      cancel_stock_transfer: { Args: { p_id: string }; Returns: Json };
      consume_password_reset: { Args: { p_token_hash: string }; Returns: string };
      create_branch: {
        Args: {
          p_address: string | null;
          p_city: string | null;
          p_code: string;
          p_eta_branch_code: string | null;
          p_governorate: string | null;
          p_name: string;
          p_phone: string | null;
        };
        Returns: string;
      };
      create_category: { Args: { p_name: string; p_parent_id?: string }; Returns: string };
      create_employee: {
        Args: {
          p_branch_ids: string[];
          p_default_branch_id: string | null;
          p_email: string | null;
          p_expires_at: string;
          p_full_name: string;
          p_overrides: Json;
          p_phone: string | null;
          p_role: Database['public']['Enums']['employee_role'];
          p_token_hash: string;
          p_username: string | null;
        };
        Returns: Json;
      };
      create_password_reset: {
        Args: { p_employee_id: string; p_expires_at: string; p_token_hash: string };
        Returns: Json;
      };
      create_product: { Args: { p: Json }; Returns: string };
      create_stock_count: {
        Args: { p_branch_id: string; p_category_id: string | null; p_idempotency_key: string };
        Returns: Json;
      };
      create_stock_transfer: {
        Args: {
          p_from_branch_id: string;
          p_idempotency_key: string;
          p_lines: Json;
          p_notes: string | null;
          p_to_branch_id: string;
        };
        Returns: Json;
      };
      create_tax_class: {
        Args: {
          p_eta_subtype: string;
          p_eta_tax_type: string;
          p_kind: Database['public']['Enums']['tax_kind'];
          p_name: string;
          p_rate: number;
        };
        Returns: string;
      };
      export_stock_movements: {
        Args: {
          p_branch_id?: string;
          p_from?: string;
          p_product_id?: string;
          p_serial?: string;
          p_to?: string;
          p_types?: Database['public']['Enums']['stock_movement_type'][];
        };
        Returns: Json;
      };
      find_unit: { Args: { p_serial: string }; Returns: Json };
      get_product: { Args: { p_id: string }; Returns: Json };
      get_shop_profile: { Args: Record<PropertyKey, never>; Returns: Json };
      get_shop_settings: { Args: Record<PropertyKey, never>; Returns: Json };
      get_stock_adjustment: { Args: { p_id: string }; Returns: Json };
      get_stock_count: {
        Args: {
          p_filter?: string;
          p_id: string;
          p_limit?: number;
          p_offset?: number;
          p_search?: string;
        };
        Returns: Json;
      };
      get_stock_transfer: { Args: { p_id: string }; Returns: Json };
      get_subscription_status: { Args: Record<PropertyKey, never>; Returns: Json };
      get_unit: { Args: { p_id: string }; Returns: Json };
      invite_lookup: { Args: { p_token_hash: string }; Returns: Json };
      jobs_claim: {
        Args: { p_limit?: number; p_types: string[]; p_worker: string };
        Returns: {
          attempts: number;
          created_at: string;
          dedupe_key: string | null;
          finished_at: string | null;
          id: string;
          job_type: string;
          last_error: string | null;
          locked_at: string | null;
          locked_by: string | null;
          max_attempts: number;
          organization_id: string | null;
          payload: NonNullable<Json>;
          run_at: string;
          status: Database['public']['Enums']['job_status'];
        }[];
        SetofOptions: {
          from: '*';
          to: 'jobs';
          isOneToOne: false;
          isSetofReturn: true;
        };
      };
      jobs_enqueue_daily: {
        Args: { p_job_type: string; p_local_time: string; p_max_attempts?: number; p_now?: string };
        Returns: number;
      };
      jobs_fail: {
        Args: { p_error: string; p_job_id: string; p_retry_in: string; p_worker: string };
        Returns: Database['public']['Enums']['job_status'];
      };
      jobs_ledger_mismatches: {
        Args: { p_organization_id: string };
        Returns: {
          branch_id: string;
          cached: number;
          detail: string;
          from_ledger: number;
          ledger: string;
          organization_id: string;
          subject_id: string;
        }[];
      };
      jobs_succeed: { Args: { p_job_id: string; p_worker: string }; Returns: boolean };
      list_branch_min_levels: { Args: { p_product_id: string }; Returns: Json };
      list_categories: { Args: Record<PropertyKey, never>; Returns: Json };
      list_employees: {
        Args: {
          p_limit: number;
          p_offset: number;
          p_role: Database['public']['Enums']['employee_role'] | null;
          p_search: string | null;
          p_status: string | null;
        };
        Returns: {
          branch_ids: string[];
          created_at: string;
          default_branch_id: string;
          email: string;
          full_name: string;
          id: string;
          invite_status: string;
          is_active: boolean;
          override_count: number;
          phone: string;
          role: Database['public']['Enums']['employee_role'];
          total_count: number;
          username: string;
        }[];
      };
      list_installment_policies: { Args: Record<PropertyKey, never>; Returns: Json };
      list_product_units: { Args: { p_product_id: string; p_status?: string }; Returns: Json };
      list_products: {
        Args: {
          p_category_id?: string;
          p_include_children?: boolean;
          p_limit?: number;
          p_offset?: number;
          p_search?: string;
          p_status?: string;
        };
        Returns: Json;
      };
      list_stock: {
        Args: {
          p_branch_id?: string;
          p_category_id?: string;
          p_include_children?: boolean;
          p_limit?: number;
          p_low_only?: boolean;
          p_offset?: number;
          p_search?: string;
        };
        Returns: Json;
      };
      list_stock_adjustments: {
        Args: { p_branch_id?: string; p_limit?: number; p_offset?: number; p_reason?: string };
        Returns: Json;
      };
      list_stock_counts: {
        Args: { p_branch_id?: string; p_limit?: number; p_offset?: number; p_status?: string };
        Returns: Json;
      };
      list_stock_movements: {
        Args: {
          p_branch_id?: string;
          p_from?: string;
          p_limit?: number;
          p_offset?: number;
          p_product_id?: string;
          p_serial?: string;
          p_to?: string;
          p_types?: Database['public']['Enums']['stock_movement_type'][];
        };
        Returns: Json;
      };
      list_stock_transfers: {
        Args: { p_branch_id?: string; p_limit?: number; p_offset?: number; p_status?: string };
        Returns: Json;
      };
      list_tax_classes: { Args: Record<PropertyKey, never>; Returns: Json };
      list_transfer_destinations: { Args: Record<PropertyKey, never>; Returns: Json };
      lookup_product: { Args: { p_code: string }; Returns: Json };
      low_stock_summary: { Args: { p_limit?: number }; Returns: Json };
      my_permissions: {
        Args: Record<PropertyKey, never>;
        Returns: {
          all_branches: boolean;
          branch_ids: string[];
          keys: string[];
        }[];
      };
      my_shops: {
        Args: Record<PropertyKey, never>;
        Returns: {
          org_id: string;
          org_name: string;
          role: Database['public']['Enums']['employee_role'];
          tenant_slug: string;
        }[];
      };
      password_reset_lookup: { Args: { p_token_hash: string }; Returns: Json };
      post_stock_adjustment: {
        Args: {
          p_branch_id: string;
          p_idempotency_key: string;
          p_lines: Json;
          p_note: string | null;
          p_reason: string;
        };
        Returns: Json;
      };
      post_stock_count: {
        Args: { p_count_id: string; p_idempotency_key: string; p_uncounted_as_zero: boolean };
        Returns: Json;
      };
      publish_installment_policy: { Args: { p_policy: Json }; Returns: string };
      receive_stock_transfer: { Args: { p_id: string; p_lines: Json }; Returns: Json };
      register_file: {
        Args: {
          p_entity_id: string | null;
          p_entity_type: string | null;
          p_id: string;
          p_mime: string;
          p_original_name: string | null;
          p_path: string;
          p_purpose: Database['public']['Enums']['file_purpose'];
          p_sha256: string | null;
          p_size_bytes: number;
        };
        Returns: string;
      };
      register_units: {
        Args: {
          p_branch_id: string;
          p_cost: string;
          p_idempotency_key: string;
          p_note: string | null;
          p_product_id: string;
          p_serials: Json;
        };
        Returns: Json;
      };
      require_module: { Args: { p_module: string }; Returns: undefined };
      resend_employee_invite: {
        Args: { p_employee_id: string; p_expires_at: string; p_token_hash: string };
        Returns: Json;
      };
      save_stock_count_lines: { Args: { p_count_id: string; p_lines: Json }; Returns: Json };
      scan_stock_count: { Args: { p_code: string; p_count_id: string }; Returns: Json };
      search_units: {
        Args: {
          p_branch_id?: string;
          p_limit?: number;
          p_offset?: number;
          p_search?: string;
          p_status?: string;
        };
        Returns: Json;
      };
      send_stock_transfer: { Args: { p_id: string }; Returns: Json };
      session_context: {
        Args: Record<PropertyKey, never>;
        Returns: {
          branch_ids: string[];
          default_branch_id: string;
          employee_id: string;
          must_change_password: boolean;
          organization_id: string;
          refusal: string;
          role: Database['public']['Enums']['employee_role'];
        }[];
      };
      set_branch_active: {
        Args: {
          p_active: boolean;
          p_branch_id: string;
          p_confirm?: boolean;
          p_reason: string | null;
        };
        Returns: undefined;
      };
      set_branch_min_level: {
        Args: { p_branch_id: string; p_min_stock?: number; p_product_id: string };
        Returns: Json;
      };
      set_category_archived: {
        Args: { p_archived: boolean; p_id: string; p_move_to?: string };
        Returns: undefined;
      };
      set_employee_active: {
        Args: { p_active: boolean; p_employee_id: string; p_reason: string | null };
        Returns: {
          employee_id: string;
          is_active: boolean;
        }[];
      };
      set_employee_branches: {
        Args: { p_branch_ids: string[]; p_employee_id: string; p_reason: string };
        Returns: {
          branch_ids: string[];
          employee_id: string;
        }[];
      };
      set_employee_permission: {
        Args: {
          p_employee_id: string;
          p_granted: boolean;
          p_permission_key: string;
          p_reason: string;
        };
        Returns: {
          employee_id: string;
          granted: boolean;
          permission_key: string;
        }[];
      };
      set_product_archived: { Args: { p_archived: boolean; p_id: string }; Returns: undefined };
      set_tax_class_archived: { Args: { p_archived: boolean; p_id: string }; Returns: undefined };
      update_branch: {
        Args: {
          p_address: string | null;
          p_branch_id: string;
          p_city: string | null;
          p_default_cash_account_id: string | null;
          p_eta_branch_code: string | null;
          p_governorate: string | null;
          p_name: string;
          p_phone: string | null;
        };
        Returns: undefined;
      };
      update_category: { Args: { p_changes: Json; p_id: string }; Returns: undefined };
      update_employee: {
        Args: {
          p_default_branch_id: string | null;
          p_email: string | null;
          p_employee_id: string;
          p_full_name: string;
          p_phone: string | null;
          p_role: Database['public']['Enums']['employee_role'];
          p_username: string | null;
        };
        Returns: Json;
      };
      update_org_profile: { Args: { p_changes: Json }; Returns: undefined };
      update_org_settings: { Args: { p_changes: Json }; Returns: undefined };
      update_org_settings_p03: { Args: { p_changes: Json }; Returns: undefined };
      update_product: { Args: { p_changes: Json; p_id: string }; Returns: undefined };
      update_stock_transfer: {
        Args: { p_id: string; p_lines: Json; p_notes: string | null };
        Returns: Json;
      };
      update_tax_class: { Args: { p_changes: Json; p_id: string }; Returns: undefined };
    };
    Enums: {
      adjustment_reason: 'damage' | 'loss' | 'found' | 'correction' | 'count' | 'other';
      approval_kind:
        | 'purchase_invoice'
        | 'price_override'
        | 'credit_exception'
        | 'discount_above_cap'
        | 'charge_waiver'
        | 'reschedule'
        | 'write_off'
        | 'refund';
      approval_status: 'pending' | 'approved' | 'rejected' | 'cancelled';
      audit_severity: 'info' | 'warning' | 'critical';
      cash_account_kind: 'safe' | 'bank' | 'drawer' | 'collector_wallet';
      cash_movement_type:
        | 'float_in'
        | 'float_out'
        | 'sale'
        | 'refund'
        | 'deposit'
        | 'collection'
        | 'supplier_payment'
        | 'supplier_refund'
        | 'expense'
        | 'transfer_in'
        | 'transfer_out'
        | 'settlement'
        | 'adjustment'
        | 'opening';
      cash_transfer_kind: 'transfer' | 'collector_settlement';
      change_kind: 'early_settlement' | 'reschedule' | 'write_off' | 'return_adjustment';
      charge_kind: 'late_fee';
      claim_status: 'open' | 'in_repair' | 'repaired' | 'replaced' | 'rejected' | 'closed';
      commission_status: 'accrued' | 'paid' | 'cancelled';
      contract_status: 'active' | 'completed' | 'rescheduled' | 'written_off' | 'returned';
      count_status: 'open' | 'posted' | 'cancelled';
      creditor_model: 'in_house';
      customer_status: 'active' | 'watch' | 'blocked';
      day_close_status: 'closed' | 'reopened';
      delivery_status: 'scheduled' | 'out_for_delivery' | 'delivered' | 'failed' | 'cancelled';
      device_status: 'unregistered' | 'pending' | 'active' | 'revoked';
      doc_type:
        | 'sale'
        | 'sales_return'
        | 'quotation'
        | 'sales_order'
        | 'delivery'
        | 'contract'
        | 'payment'
        | 'purchase_order'
        | 'purchase_invoice'
        | 'purchase_return'
        | 'supplier_payment'
        | 'transfer'
        | 'stock_count'
        | 'stock_adjustment'
        | 'cash_transfer'
        | 'expense'
        | 'warranty_claim'
        | 'legal_case'
        | 'shift'
        | 'charge'
        | 'contract_change'
        | 'import';
      early_settlement_rule: 'no_discount' | 'waive_future_profit' | 'percent_of_future_profit';
      employee_role:
        | 'OWNER'
        | 'BRANCH_MANAGER'
        | 'CASHIER'
        | 'WAREHOUSE'
        | 'COLLECTOR'
        | 'ACCOUNTANT'
        | 'LAWYER';
      eta_environment: 'preprod' | 'prod';
      file_purpose:
        | 'logo'
        | 'product_image'
        | 'customer_id'
        | 'survey_photo'
        | 'signature'
        | 'contract_pdf'
        | 'promissory_note'
        | 'delivery_proof'
        | 'expense_receipt'
        | 'legal_document'
        | 'import'
        | 'export'
        | 'other';
      fiscal_doc_type: 'b2c_receipt' | 'b2c_return' | 'b2b_invoice' | 'b2b_credit_note';
      fiscal_status: 'pending' | 'submitted' | 'accepted' | 'rejected' | 'failed' | 'cancelled';
      fulfilment_mode: 'from_stock' | 'to_order';
      import_kind:
        | 'products'
        | 'customers'
        | 'suppliers'
        | 'opening_stock'
        | 'opening_cash'
        | 'opening_contracts'
        | 'full_export';
      import_status:
        | 'uploaded'
        | 'validating'
        | 'validated'
        | 'importing'
        | 'completed'
        | 'failed'
        | 'cancelled';
      installment_frequency: 'monthly' | 'weekly' | 'daily';
      job_status: 'queued' | 'running' | 'succeeded' | 'failed' | 'dead';
      late_fee_type: 'none' | 'fixed' | 'percent';
      legal_status: 'preparing' | 'filed' | 'in_court' | 'judgment' | 'closed';
      order_status: 'open' | 'partially_delivered' | 'delivered' | 'cancelled';
      org_status: 'active' | 'suspended' | 'expired' | 'closed';
      payment_direction: 'in' | 'out';
      payment_method: 'cash' | 'bank_transfer' | 'store_credit';
      po_status: 'draft' | 'sent' | 'partially_received' | 'received' | 'cancelled';
      purchase_invoice_status: 'draft' | 'pending_approval' | 'approved' | 'rejected';
      purchase_refund_mode: 'supplier_credit' | 'cash';
      quotation_status: 'draft' | 'sent' | 'accepted' | 'expired' | 'cancelled';
      refund_method: 'cash' | 'bank_transfer' | 'store_credit' | 'contract_adjustment';
      reservation_status: 'active' | 'released' | 'fulfilled';
      return_condition: 'resellable' | 'damaged';
      return_kind: 'return' | 'void' | 'exchange';
      sale_kind: 'pos' | 'delivery';
      shift_status: 'open' | 'closed';
      stock_movement_type:
        | 'opening'
        | 'purchase_in'
        | 'purchase_return_out'
        | 'sale_out'
        | 'sale_return_in'
        | 'transfer_out'
        | 'transfer_in'
        | 'adjustment'
        | 'delivery_out'
        | 'claim_out'
        | 'claim_in';
      stock_state: 'sellable' | 'damaged';
      survey_status: 'assigned' | 'submitted' | 'approved' | 'rejected' | 'cancelled';
      tax_kind: 'standard' | 'zero' | 'exempt';
      transfer_status: 'draft' | 'sent' | 'received' | 'partially_received' | 'cancelled';
      unit_status:
        'in_stock' | 'reserved' | 'in_transit' | 'sold' | 'returned' | 'in_repair' | 'written_off';
    };
    CompositeTypes: {
      [_ in never]: never;
    };
  };
};

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>;

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, 'public'>];

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema['Tables'] & DefaultSchema['Views'])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables'] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Views'])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables'] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Views'])[TableName] extends {
      Row: infer R;
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema['Tables'] & DefaultSchema['Views'])
    ? (DefaultSchema['Tables'] & DefaultSchema['Views'])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R;
      }
      ? R
      : never
    : never;

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema['Tables'] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables']
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables'][TableName] extends {
      Insert: infer I;
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema['Tables']
    ? DefaultSchema['Tables'][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I;
      }
      ? I
      : never
    : never;

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema['Tables'] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables']
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables'][TableName] extends {
      Update: infer U;
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema['Tables']
    ? DefaultSchema['Tables'][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U;
      }
      ? U
      : never
    : never;

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    keyof DefaultSchema['Enums'] | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions['schema']]['Enums']
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions['schema']]['Enums'][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema['Enums']
    ? DefaultSchema['Enums'][DefaultSchemaEnumNameOrOptions]
    : never;

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    keyof DefaultSchema['CompositeTypes'] | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions['schema']]['CompositeTypes']
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions['schema']]['CompositeTypes'][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema['CompositeTypes']
    ? DefaultSchema['CompositeTypes'][PublicCompositeTypeNameOrOptions]
    : never;

export const Constants = {
  public: {
    Enums: {
      adjustment_reason: ['damage', 'loss', 'found', 'correction', 'count', 'other'],
      approval_kind: [
        'purchase_invoice',
        'price_override',
        'credit_exception',
        'discount_above_cap',
        'charge_waiver',
        'reschedule',
        'write_off',
        'refund',
      ],
      approval_status: ['pending', 'approved', 'rejected', 'cancelled'],
      audit_severity: ['info', 'warning', 'critical'],
      cash_account_kind: ['safe', 'bank', 'drawer', 'collector_wallet'],
      cash_movement_type: [
        'float_in',
        'float_out',
        'sale',
        'refund',
        'deposit',
        'collection',
        'supplier_payment',
        'supplier_refund',
        'expense',
        'transfer_in',
        'transfer_out',
        'settlement',
        'adjustment',
        'opening',
      ],
      cash_transfer_kind: ['transfer', 'collector_settlement'],
      change_kind: ['early_settlement', 'reschedule', 'write_off', 'return_adjustment'],
      charge_kind: ['late_fee'],
      claim_status: ['open', 'in_repair', 'repaired', 'replaced', 'rejected', 'closed'],
      commission_status: ['accrued', 'paid', 'cancelled'],
      contract_status: ['active', 'completed', 'rescheduled', 'written_off', 'returned'],
      count_status: ['open', 'posted', 'cancelled'],
      creditor_model: ['in_house'],
      customer_status: ['active', 'watch', 'blocked'],
      day_close_status: ['closed', 'reopened'],
      delivery_status: ['scheduled', 'out_for_delivery', 'delivered', 'failed', 'cancelled'],
      device_status: ['unregistered', 'pending', 'active', 'revoked'],
      doc_type: [
        'sale',
        'sales_return',
        'quotation',
        'sales_order',
        'delivery',
        'contract',
        'payment',
        'purchase_order',
        'purchase_invoice',
        'purchase_return',
        'supplier_payment',
        'transfer',
        'stock_count',
        'stock_adjustment',
        'cash_transfer',
        'expense',
        'warranty_claim',
        'legal_case',
        'shift',
        'charge',
        'contract_change',
        'import',
      ],
      early_settlement_rule: ['no_discount', 'waive_future_profit', 'percent_of_future_profit'],
      employee_role: [
        'OWNER',
        'BRANCH_MANAGER',
        'CASHIER',
        'WAREHOUSE',
        'COLLECTOR',
        'ACCOUNTANT',
        'LAWYER',
      ],
      eta_environment: ['preprod', 'prod'],
      file_purpose: [
        'logo',
        'product_image',
        'customer_id',
        'survey_photo',
        'signature',
        'contract_pdf',
        'promissory_note',
        'delivery_proof',
        'expense_receipt',
        'legal_document',
        'import',
        'export',
        'other',
      ],
      fiscal_doc_type: ['b2c_receipt', 'b2c_return', 'b2b_invoice', 'b2b_credit_note'],
      fiscal_status: ['pending', 'submitted', 'accepted', 'rejected', 'failed', 'cancelled'],
      fulfilment_mode: ['from_stock', 'to_order'],
      import_kind: [
        'products',
        'customers',
        'suppliers',
        'opening_stock',
        'opening_cash',
        'opening_contracts',
        'full_export',
      ],
      import_status: [
        'uploaded',
        'validating',
        'validated',
        'importing',
        'completed',
        'failed',
        'cancelled',
      ],
      installment_frequency: ['monthly', 'weekly', 'daily'],
      job_status: ['queued', 'running', 'succeeded', 'failed', 'dead'],
      late_fee_type: ['none', 'fixed', 'percent'],
      legal_status: ['preparing', 'filed', 'in_court', 'judgment', 'closed'],
      order_status: ['open', 'partially_delivered', 'delivered', 'cancelled'],
      org_status: ['active', 'suspended', 'expired', 'closed'],
      payment_direction: ['in', 'out'],
      payment_method: ['cash', 'bank_transfer', 'store_credit'],
      po_status: ['draft', 'sent', 'partially_received', 'received', 'cancelled'],
      purchase_invoice_status: ['draft', 'pending_approval', 'approved', 'rejected'],
      purchase_refund_mode: ['supplier_credit', 'cash'],
      quotation_status: ['draft', 'sent', 'accepted', 'expired', 'cancelled'],
      refund_method: ['cash', 'bank_transfer', 'store_credit', 'contract_adjustment'],
      reservation_status: ['active', 'released', 'fulfilled'],
      return_condition: ['resellable', 'damaged'],
      return_kind: ['return', 'void', 'exchange'],
      sale_kind: ['pos', 'delivery'],
      shift_status: ['open', 'closed'],
      stock_movement_type: [
        'opening',
        'purchase_in',
        'purchase_return_out',
        'sale_out',
        'sale_return_in',
        'transfer_out',
        'transfer_in',
        'adjustment',
        'delivery_out',
        'claim_out',
        'claim_in',
      ],
      stock_state: ['sellable', 'damaged'],
      survey_status: ['assigned', 'submitted', 'approved', 'rejected', 'cancelled'],
      tax_kind: ['standard', 'zero', 'exempt'],
      transfer_status: ['draft', 'sent', 'received', 'partially_received', 'cancelled'],
      unit_status: [
        'in_stock',
        'reserved',
        'in_transit',
        'sold',
        'returned',
        'in_repair',
        'written_off',
      ],
    },
  },
} as const;
