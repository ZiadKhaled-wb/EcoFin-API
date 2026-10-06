import { describe, it, expect } from 'vitest';
import {
  EmployeeCreateBody,
  EmployeeUpdateBody,
  EmployeesQuery,
  EmployeeActiveBody,
  PasswordResetCompleteBody,
} from './employees.js';
const branch = 'a0200000-0000-4000-8000-000000000001';
describe('O02 employee contracts', () => {
  it('requires a login and normalizes username', () => {
    const body = { full_name: 'Staff', role: 'CASHIER', branch_ids: [branch] };
    expect(EmployeeCreateBody.safeParse(body).success).toBe(false);
    expect(EmployeeCreateBody.parse({ ...body, username: ' CASHIER.1 ' }).username).toBe(
      'cashier.1',
    );
    expect(EmployeeCreateBody.safeParse({ ...body, username: 'a!' }).success).toBe(false);
  });
  it('requires branches, validates overrides, and permits partial edits', () => {
    expect(
      EmployeeCreateBody.safeParse({
        full_name: 'Staff',
        email: 'staff@example.com',
        role: 'CASHIER',
        branch_ids: [],
      }).success,
    ).toBe(false);
    expect(
      EmployeeCreateBody.safeParse({
        full_name: 'Staff',
        email: 'staff@example.com',
        role: 'CASHIER',
        branch_ids: [branch],
        overrides: [{ key: 'unknown', granted: true }],
      }).success,
    ).toBe(false);
    expect(EmployeeUpdateBody.parse({ phone: '123' })).toEqual({ phone: '123' });
    expect(EmployeeUpdateBody.safeParse({ organization_id: branch }).success).toBe(false);
  });
  it('validates filters, deactivation reason and password rules', () => {
    expect(EmployeesQuery.safeParse({ page_size: '101' }).success).toBe(false);
    expect(EmployeeActiveBody.safeParse({ active: false }).success).toBe(false);
    expect(EmployeeActiveBody.safeParse({ active: true }).success).toBe(true);
    expect(PasswordResetCompleteBody.safeParse({ token: 't', password: 'short' }).success).toBe(
      false,
    );
  });
});
