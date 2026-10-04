import { describe, it, expect, beforeEach } from 'vitest';
import { createSupabaseMock, type SupabaseMock } from '../test/supabase-mock';
import type { RequestContext } from '../middleware/requestContext';
import type { DbClient } from '../utils/supabase';
import { AppError } from '../utils/errors';
import { setEmployeeBranches, setEmployeePermission } from './employees.service';

const ORG = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const EMP = '11111111-1111-4111-8111-111111111111';
const BR1 = '22222222-2222-4222-8222-222222222222';

async function codeOf(p: Promise<unknown>): Promise<string> {
  try {
    await p;
  } catch (err) {
    return err instanceof AppError ? err.code : `not an AppError: ${String(err)}`;
  }
  return 'resolved';
}

describe('employees.service', () => {
  let db: SupabaseMock;
  let ctx: RequestContext;

  beforeEach(() => {
    db = createSupabaseMock();
    // The services call rpc(...).single(): let rpc chain like the query builder.
    db.rpc.mockImplementation(() => db);
    ctx = {
      userId: 'u1',
      employeeId: 'e-owner',
      orgId: ORG,
      role: 'OWNER',
      defaultBranchId: null,
      branchIds: [],
      mustChangePassword: false,
      db: db as unknown as DbClient,
    };
  });

  describe('setEmployeePermission', () => {
    const body = { permissionKey: 'sale.void' as const, granted: true, reason: 'cover' };

    it('checks the employee is in the shop, then calls the DB function', async () => {
      db.queue(
        { data: [{ id: EMP }], error: null }, // assertSameOrg
        {
          data: { employee_id: EMP, permission_key: 'sale.void', granted: true },
          error: null,
        },
      );
      expect(await setEmployeePermission(ctx, EMP, body)).toEqual({
        employeeId: EMP,
        permissionKey: 'sale.void',
        granted: true,
      });
      expect(db.from).toHaveBeenCalledWith('employees');
      expect(db.rpc).toHaveBeenCalledWith('set_employee_permission', {
        p_employee_id: EMP,
        p_permission_key: 'sale.void',
        p_granted: true,
        p_reason: 'cover',
      });
    });

    it("another shop's employee -> 404 before the DB function runs", async () => {
      db.queue({ data: [], error: null });
      expect(await codeOf(setEmployeePermission(ctx, EMP, body))).toBe('NOT_FOUND');
      expect(db.rpc).not.toHaveBeenCalled();
    });

    it.each([
      ['PERMISSION_DENIED: employee.manage', 'PERMISSION_DENIED', 403],
      ["FORBIDDEN: the owner's access can't be changed", 'FORBIDDEN', 403],
      ['NOT_FOUND: employee', 'NOT_FOUND', 404],
      ['VALIDATION_FAILED: reason is required (1-500 characters)', 'VALIDATION_FAILED', 400],
    ])('DB error "%s" -> %s', async (message, code, status) => {
      db.queue({ data: [{ id: EMP }], error: null }, { data: null, error: { message } });
      try {
        await setEmployeePermission(ctx, EMP, body);
        expect.unreachable();
      } catch (err) {
        expect(err).toBeInstanceOf(AppError);
        expect((err as AppError).code).toBe(code);
        expect((err as AppError).statusCode).toBe(status);
        expect((err as AppError).message).not.toContain('owner'); // generic message only
      }
    });

    it('an unknown DB error -> 500', async () => {
      db.queue(
        { data: [{ id: EMP }], error: null },
        { data: null, error: { message: 'deadlock detected' } },
      );
      expect(await codeOf(setEmployeePermission(ctx, EMP, body))).toBe('INTERNAL');
    });
  });

  describe('setEmployeeBranches', () => {
    it('replaces the list through the DB function', async () => {
      db.queue(
        { data: [{ id: EMP }], error: null },
        { data: { employee_id: EMP, branch_ids: [BR1] }, error: null },
      );
      expect(await setEmployeeBranches(ctx, EMP, { branchIds: [BR1], reason: 'move' })).toEqual({
        employeeId: EMP,
        branchIds: [BR1],
      });
      expect(db.rpc).toHaveBeenCalledWith('set_employee_branches', {
        p_employee_id: EMP,
        p_branch_ids: [BR1],
        p_reason: 'move',
      });
    });

    it("another shop's branch -> 422 BRANCH_NOT_IN_ORG", async () => {
      db.queue(
        { data: [{ id: EMP }], error: null },
        { data: null, error: { message: 'BRANCH_NOT_IN_ORG' } },
      );
      expect(await codeOf(setEmployeeBranches(ctx, EMP, { branchIds: [BR1], reason: 'x' }))).toBe(
        'BRANCH_NOT_IN_ORG',
      );
    });

    it("another shop's employee -> 404", async () => {
      db.queue({ data: [], error: null });
      expect(await codeOf(setEmployeeBranches(ctx, EMP, { branchIds: [], reason: 'x' }))).toBe(
        'NOT_FOUND',
      );
    });
  });
});
