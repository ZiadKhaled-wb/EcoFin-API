import { describe, expect, expectTypeOf, it } from 'vitest';
import {
  AuditSearch,
  AuthForgotPassword,
  AuthLogin,
  AuthLogout,
  AuthMe,
  AuthRefresh,
  AuthResetPassword,
  AuthSelectShop,
  CONTRACTS_VERSION,
  EmployeeBranchesAssign,
  EmployeePermissionOverride,
  ErrorResponse,
  Health,
  IdempotencyKeyHeader,
  MePermissions,
  Money,
  PaginationQuery,
  BusinessDate,
  type AuthLoginBody,
  type AuthLoginResponse,
  type Money as MoneyType,
} from './index.js';
import { readFileSync } from 'node:fs';

const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')) as {
  version: string;
};

const id = '3f2b8c1e-5a4d-4e6f-8a9b-0c1d2e3f4a5b';
const id2 = '7a1b2c3d-4e5f-4a6b-9c8d-1e2f3a4b5c6d';
const now = '2026-10-03T08:00:00.000Z';
const session = { accessToken: 'a', refreshToken: 'r', expiresAt: now };
const user = { id, email: 'a@b.co' };

describe('version', () => {
  it('CONTRACTS_VERSION equals package.json version', () => {
    expect(CONTRACTS_VERSION).toBe(pkg.version);
  });
});

describe('Money', () => {
  it('accepts decimal strings', () => {
    for (const v of ['0', '12', '12.5', '12.50', '-3.20', '9999999999999999.99']) {
      expect(Money.safeParse(v).success, v).toBe(true);
    }
  });
  it('rejects JS numbers and more than 2 decimals', () => {
    for (const v of [12, 12.5, '12.345', '1e3', '', '.5', '12.', 'abc', '12345678901234567']) {
      expect(Money.safeParse(v).success, String(v)).toBe(false);
    }
  });
});

describe('common', () => {
  it('pagination coerces strings and caps pageSize at 100', () => {
    expect(PaginationQuery.parse({ page: '2', pageSize: '100' })).toEqual({
      page: 2,
      pageSize: 100,
    });
    expect(PaginationQuery.parse({})).toEqual({ page: 1, pageSize: 50 });
    expect(PaginationQuery.safeParse({ pageSize: '101' }).success).toBe(false);
    expect(PaginationQuery.safeParse({ page: '0' }).success).toBe(false);
  });
  it('business date must be a real date', () => {
    expect(BusinessDate.safeParse('2026-02-28').success).toBe(true);
    expect(BusinessDate.safeParse('2026-02-30').success).toBe(false);
    expect(BusinessDate.safeParse('2026-2-3').success).toBe(false);
  });
  it('idempotency key header', () => {
    expect(IdempotencyKeyHeader.safeParse({ 'idempotency-key': 'abcdefgh-1' }).success).toBe(true);
    expect(IdempotencyKeyHeader.safeParse({}).success).toBe(false);
  });
});

describe('error response', () => {
  it('parses a valid error and rejects an unknown code', () => {
    expect(ErrorResponse.safeParse({ error: { code: 'OUT_OF_STOCK', message: 'm' } }).success).toBe(
      true,
    );
    expect(ErrorResponse.safeParse({ error: { code: 'NOPE', message: 'm' } }).success).toBe(false);
    expect(ErrorResponse.safeParse({ error: { code: 'OUT_OF_STOCK' } }).success).toBe(false);
  });
});

describe('auth schemas', () => {
  it('login body: valid, invalid, extra organization_id', () => {
    expect(AuthLogin.body.safeParse({ email: 'a@b.co', password: 'x' }).success).toBe(true);
    expect(AuthLogin.body.safeParse({ username: 'ali.1', password: 'x', orgId: id }).success).toBe(
      true,
    );
    expect(
      AuthLogin.body.safeParse({ email: 'a@b.co', username: 'ali', password: 'x' }).success,
    ).toBe(false);
    expect(AuthLogin.body.safeParse({ password: 'x' }).success).toBe(false);
    expect(AuthLogin.body.safeParse({ email: 5, password: 'x' }).success).toBe(false);
    expect(
      AuthLogin.body.safeParse({ email: 'a@b.co', password: 'x', organization_id: id }).success,
    ).toBe(false);
  });
  it('login response', () => {
    const ok = {
      ...session,
      user,
      shops: [{ orgId: id, orgName: 'S', role: 'OWNER' }],
      requiresShopSelection: false,
    };
    expect(AuthLogin.response.safeParse(ok).success).toBe(true);
    expect(AuthLogin.response.safeParse({ ...ok, requiresShopSelection: 'no' }).success).toBe(
      false,
    );
    expect(
      AuthLogin.response.safeParse({ ...ok, shops: [{ orgId: id, orgName: 'S', role: 'BOSS' }] })
        .success,
    ).toBe(false);
  });
  it('select shop', () => {
    expect(AuthSelectShop.body.safeParse({ orgId: id }).success).toBe(true);
    expect(AuthSelectShop.body.safeParse({}).success).toBe(false);
    expect(AuthSelectShop.body.safeParse({ orgId: id, organization_id: id2 }).success).toBe(false);
    expect(
      AuthSelectShop.response.safeParse({
        ...session,
        user,
        shop: { orgId: id, orgName: 'S', role: 'CASHIER' },
      }).success,
    ).toBe(true);
    expect(AuthSelectShop.response.safeParse({ ...session, user }).success).toBe(false);
  });
  it('refresh and logout', () => {
    expect(AuthRefresh.body.safeParse({ refreshToken: 't' }).success).toBe(true);
    expect(AuthRefresh.body.safeParse({ refreshToken: 1 }).success).toBe(false);
    expect(AuthRefresh.body.safeParse({ refreshToken: 't', organization_id: id }).success).toBe(
      false,
    );
    expect(AuthRefresh.response.safeParse(session).success).toBe(true);
    expect(AuthRefresh.response.safeParse({ accessToken: 'a' }).success).toBe(false);
    expect(AuthLogout.response.safeParse({ ok: true }).success).toBe(true);
    expect(AuthLogout.response.safeParse({ ok: false }).success).toBe(false);
  });
  it('forgot and reset password', () => {
    expect(AuthForgotPassword.body.safeParse({ email: 'a@b.co' }).success).toBe(true);
    expect(AuthForgotPassword.body.safeParse({ email: 'nope' }).success).toBe(false);
    expect(
      AuthForgotPassword.body.safeParse({ email: 'a@b.co', organization_id: id }).success,
    ).toBe(false);
    expect(
      AuthResetPassword.body.safeParse({ token: 't', newPassword: 'longenough1' }).success,
    ).toBe(true);
    expect(AuthResetPassword.body.safeParse({ token: 't', newPassword: 'short' }).success).toBe(
      false,
    );
    expect(AuthResetPassword.body.safeParse({ newPassword: 'longenough1' }).success).toBe(false);
    expect(
      AuthResetPassword.body.safeParse({
        token: 't',
        newPassword: 'longenough1',
        organization_id: id,
      }).success,
    ).toBe(false);
  });
  it('me response', () => {
    const ok = {
      employee: {
        id,
        fullName: 'A',
        email: null,
        username: 'ali',
        role: 'OWNER',
        defaultBranchId: null,
        mustChangePassword: false,
      },
      org: {
        id,
        tenantSlug: 'shop',
        name: 'Shop',
        timezone: 'Africa/Cairo',
        defaultLanguage: 'ar',
        status: 'active',
        planKey: 'starter',
        subscriptionEnd: '2027-01-01',
      },
      branches: [{ id, code: 'BR1', name: 'Main', isMain: true }],
    };
    expect(AuthMe.response.safeParse(ok).success).toBe(true);
    expect(AuthMe.response.safeParse({ ...ok, branches: [{ id }] }).success).toBe(false);
    expect(AuthMe.response.safeParse({ ...ok, org: { ...ok.org, status: 'gone' } }).success).toBe(
      false,
    );
  });
});

describe('access schemas', () => {
  it('me permissions response', () => {
    expect(
      MePermissions.response.safeParse({
        keys: ['sale.create'],
        branchIds: [id],
        allBranches: false,
      }).success,
    ).toBe(true);
    expect(
      MePermissions.response.safeParse({ keys: ['sale.nope'], branchIds: [], allBranches: false })
        .success,
    ).toBe(false);
    expect(MePermissions.response.safeParse({ keys: [], branchIds: [] }).success).toBe(false);
  });
  it('permission override body', () => {
    const ok = { employeeId: id, permissionKey: 'sale.void', granted: true, reason: 'cover shift' };
    expect(EmployeePermissionOverride.body.safeParse(ok).success).toBe(true);
    expect(EmployeePermissionOverride.body.safeParse({ ...ok, granted: 'yes' }).success).toBe(
      false,
    );
    expect(EmployeePermissionOverride.body.safeParse({ ...ok, reason: '  ' }).success).toBe(false);
    expect(EmployeePermissionOverride.body.safeParse({ employeeId: id }).success).toBe(false);
    expect(EmployeePermissionOverride.body.safeParse({ ...ok, organization_id: id2 }).success).toBe(
      false,
    );
    expect(
      EmployeePermissionOverride.response.safeParse({
        employeeId: id,
        permissionKey: 'sale.void',
        granted: false,
      }).success,
    ).toBe(true);
  });
  it('assign branches body', () => {
    expect(
      EmployeeBranchesAssign.body.safeParse({ employeeId: id, branchIds: [id, id2] }).success,
    ).toBe(true);
    expect(
      EmployeeBranchesAssign.body.safeParse({ employeeId: id, branchIds: [id, id] }).success,
    ).toBe(false);
    expect(
      EmployeeBranchesAssign.body.safeParse({ employeeId: id, branchIds: ['x'] }).success,
    ).toBe(false);
    expect(EmployeeBranchesAssign.body.safeParse({ employeeId: id }).success).toBe(false);
    expect(
      EmployeeBranchesAssign.body.safeParse({ employeeId: id, branchIds: [], organization_id: id2 })
        .success,
    ).toBe(false);
    expect(
      EmployeeBranchesAssign.response.safeParse({ employeeId: id, branchIds: [] }).success,
    ).toBe(true);
  });
});

describe('audit schemas', () => {
  it('search query', () => {
    expect(AuditSearch.query.parse({}).pageSize).toBe(50);
    expect(
      AuditSearch.query.safeParse({
        from: now,
        to: '2026-10-04T00:00:00Z',
        actorEmployeeId: id,
        action: 'sale.create',
        entityType: 'sale',
        entityId: id,
        branchId: id,
        page: '2',
      }).success,
    ).toBe(true);
    expect(AuditSearch.query.safeParse({ from: '2026-10-05T00:00:00Z', to: now }).success).toBe(
      false,
    );
    expect(AuditSearch.query.safeParse({ entityId: 'nope' }).success).toBe(false);
    expect(AuditSearch.query.safeParse({ pageSize: '500' }).success).toBe(false);
    expect(AuditSearch.query.safeParse({ organization_id: id }).success).toBe(false);
  });
  it('search response', () => {
    const row = {
      id: 1,
      branchId: null,
      employeeId: id,
      superAdminId: null,
      deviceId: null,
      ip: '1.2.3.4',
      userAgent: null,
      requestId: 'r',
      action: 'auth.login',
      entityType: null,
      entityId: null,
      severity: 'info',
      reason: null,
      before: null,
      after: { a: 1 },
      createdAt: now,
    };
    expect(
      AuditSearch.response.safeParse({ items: [row], page: 1, pageSize: 50, total: 1 }).success,
    ).toBe(true);
    expect(
      AuditSearch.response.safeParse({
        items: [{ ...row, severity: 'fatal' }],
        page: 1,
        pageSize: 50,
        total: 1,
      }).success,
    ).toBe(false);
    expect(AuditSearch.response.safeParse({ items: [row] }).success).toBe(false);
  });
});

describe('health schema', () => {
  it('response', () => {
    expect(
      Health.response.safeParse({ status: 'ok', db: 'ok', version: '0.1.0', time: now }).success,
    ).toBe(true);
    expect(
      Health.response.safeParse({ status: 'up', db: 'ok', version: '0.1.0', time: now }).success,
    ).toBe(false);
    expect(Health.response.safeParse({ status: 'ok', db: 'ok', version: '0.1.0' }).success).toBe(
      false,
    );
  });
});

describe('compile-time contract: renaming or retyping a field breaks the build', () => {
  it('login body and response types', () => {
    expectTypeOf<AuthLoginBody['password']>().toEqualTypeOf<string>();
    expectTypeOf<AuthLoginResponse['requiresShopSelection']>().toEqualTypeOf<boolean>();
    expectTypeOf<MoneyType>().toEqualTypeOf<string>();

    const res = {} as AuthLoginResponse;
    // @ts-expect-error a client still using the old field name no longer compiles
    void res.accessTokenOld;
    // @ts-expect-error money is a string, a number is not assignable
    const bad: MoneyType = 12.5;
    void bad;
    // @ts-expect-error organization_id is not part of the login body type
    const body: AuthLoginBody = { email: 'a@b.co', password: 'x', organization_id: id };
    void body;
  });
});
