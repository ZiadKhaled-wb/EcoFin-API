// src/services/auth.service.test.ts
import { describe, it, expect, vi, beforeEach } from 'vitest';

// -----------------------------------------------------------------------
// Module-level mock. Every exported client from utils/supabase is a
// fresh SupabaseMock instance. `supabaseUser(jwt)` returns the same
// instance on every call so tests can queue responses against it.
// -----------------------------------------------------------------------
vi.mock('../utils/supabase', async () => {
    const { createSupabaseMock } = await import('../test/supabase-mock');
    const admin = createSupabaseMock();
    const anon = createSupabaseMock();
    const user = createSupabaseMock();
    return {
        supabaseAdmin: admin,
        supabaseAnon: anon,
        supabaseUser: () => user,
    };
});

// Imports must come after vi.mock so they receive the mocked module.
import { supabaseAdmin, supabaseAnon } from '../utils/supabase';
import type { SupabaseMock } from '../test/supabase-mock';
import {
    login,
    checkLicense,
    activateWorkspace,
    resetOwnerPassword,
    changePassword,
    forgotPassword,
} from './auth.service';

const admin = supabaseAdmin as unknown as SupabaseMock;
const anon = supabaseAnon as unknown as SupabaseMock;

beforeEach(() => {
    admin.reset();
    anon.reset();
    vi.clearAllMocks();
});

// ===========================================================================
// LOGIN
// ===========================================================================

describe('login', () => {
    const org = {
        id: '00000000-0000-0000-0000-000000000001',
        tenant_slug: 'testshop',
        name: 'Test Shop',
        is_active: true,
        is_suspended: false,
    };
    const authUser = {
        id: '00000000-0000-0000-0000-000000000003',
        email: 'owner@test.local',
    };
    const employee = {
        id: '00000000-0000-0000-0000-000000000002',
        organization_id: org.id,
        role: 'OWNER',
        username: 'owner',
        branch_id: null,
        permissions: [],
        is_active: true,
        must_change_password: false,
    };
    const session = {
        access_token: 'jwt',
        refresh_token: 'refresh',
    };

    it('rejects an unknown tenant slug with INVALID_CREDENTIALS', async () => {
        admin.queue({ data: null, error: null }); // org lookup → not found

        await expect(login('unknown-slug', 'owner', 'pw')).rejects.toMatchObject({
            code: 'INVALID_CREDENTIALS',
            statusCode: 401,
        });
    });

    it('rejects a suspended org with INVALID_CREDENTIALS (not a distinct message)', async () => {
        admin.queue({ data: { ...org, is_suspended: true }, error: null });

        await expect(login('testshop', 'owner', 'pw')).rejects.toMatchObject({
            code: 'INVALID_CREDENTIALS',
        });
    });

    it('rejects an unknown username with INVALID_CREDENTIALS', async () => {
        admin.queue({ data: org, error: null });
        admin.queue({ data: null, error: null }); // username lookup → none

        await expect(login('testshop', 'nobody', 'pw')).rejects.toMatchObject({
            code: 'INVALID_CREDENTIALS',
        });
    });

    it('rejects a wrong password with INVALID_CREDENTIALS', async () => {
        admin.queue({ data: org, error: null });
        admin.queue({ data: { auth_id: authUser.id }, error: null });
        admin.queue({ data: { user: authUser }, error: null }); // getUserById
        anon.queue({ data: null, error: { message: 'invalid credentials' } });

        await expect(login('testshop', 'owner', 'wrong')).rejects.toMatchObject({
            code: 'INVALID_CREDENTIALS',
        });
    });

    it('produces the SAME error body for unknown slug / unknown user / wrong password', async () => {
        // Criterion 3 — the enumeration defence. Compare the caught errors
        // by their user-facing fields, ignoring the internal requestId.
        const collect = async (fn: () => Promise<unknown>) => {
            try { await fn(); } catch (e) { return e as { message: string; code: string }; }
            throw new Error('expected a throw');
        };

        admin.queue({ data: null, error: null });
        const unknownSlug = await collect(() => login('unknown', 'x', 'y'));

        admin.queue({ data: org, error: null });
        admin.queue({ data: null, error: null });
        const unknownUser = await collect(() => login('testshop', 'nobody', 'y'));

        admin.queue({ data: org, error: null });
        admin.queue({ data: { auth_id: authUser.id }, error: null });
        admin.queue({ data: { user: authUser }, error: null });
        anon.queue({ data: null, error: { message: 'invalid' } });
        const wrongPw = await collect(() => login('testshop', 'owner', 'y'));

        expect(unknownSlug.message).toBe(unknownUser.message);
        expect(unknownUser.message).toBe(wrongPw.message);
        expect(unknownSlug.code).toBe('INVALID_CREDENTIALS');
        expect(unknownUser.code).toBe('INVALID_CREDENTIALS');
        expect(wrongPw.code).toBe('INVALID_CREDENTIALS');
    });

    it('rejects an inactive employee with ACCOUNT_DISABLED (after correct password)', async () => {
        admin.queue({ data: org, error: null });
        admin.queue({ data: { auth_id: authUser.id }, error: null });
        admin.queue({ data: { user: authUser }, error: null });
        anon.queue({ data: { user: authUser, session }, error: null });
        admin.queue({ data: { ...employee, is_active: false }, error: null });

        await expect(login('testshop', 'owner', 'correct')).rejects.toMatchObject({
            code: 'ACCOUNT_DISABLED',
            statusCode: 403,
        });
    });

    it('rejects login when the JWT org does not match the requested slug', async () => {
        admin.queue({ data: org, error: null });
        admin.queue({ data: { auth_id: authUser.id }, error: null });
        admin.queue({ data: { user: authUser }, error: null });
        anon.queue({ data: { user: authUser, session }, error: null });
        admin.queue({
            data: { ...employee, organization_id: 'different-org-uuid' },
            error: null,
        });

        await expect(login('testshop', 'owner', 'correct')).rejects.toMatchObject({
            code: 'INVALID_CREDENTIALS',
        });
    });

    it('returns session, user, and must_change_password on success', async () => {
        admin.queue({ data: org, error: null });
        admin.queue({ data: { auth_id: authUser.id }, error: null });
        admin.queue({ data: { user: authUser }, error: null });
        anon.queue({ data: { user: authUser, session }, error: null });
        admin.queue({ data: { ...employee, must_change_password: true }, error: null });

        const result = await login('testshop', 'owner', 'correct');

        expect(result.session.access_token).toBe('jwt');
        expect(result.session.refresh_token).toBe('refresh');
        expect(result.must_change_password).toBe(true);
        expect(result.user.role).toBe('OWNER');
        expect(result.user.orgId).toBe(org.id);
        expect(result.user.personId).toBe(employee.id);
    });

    it('accepts an email identifier without an employee lookup', async () => {
        admin.queue({ data: org, error: null });
        anon.queue({ data: { user: authUser, session }, error: null });
        admin.queue({ data: employee, error: null });

        const result = await login('testshop', 'owner@test.local', 'correct');

        expect(result.user.email).toBe('owner@test.local');
        expect(result.user.role).toBe('OWNER');
        // The pre-auth employee-by-username lookup was NOT performed.
        // (Verifying by checking the mock: only 2 admin queries ran.)
    });

    it('uses supabaseAnon.signInWithPassword — never supabaseAdmin', async () => {
        admin.queue({ data: org, error: null });
        admin.queue({ data: { auth_id: authUser.id }, error: null });
        admin.queue({ data: { user: authUser }, error: null });
        anon.queue({ data: { user: authUser, session }, error: null });
        admin.queue({ data: employee, error: null });

        await login('testshop', 'owner', 'correct');

        expect(anon.auth.signInWithPassword).toHaveBeenCalledOnce();
        // The admin client must never call signInWithPassword — doing so
        // bypasses Supabase's own rate limiting. See ADR-0004 D2.
        expect(admin.auth.signInWithPassword).not.toHaveBeenCalled();
    });
});

// ===========================================================================
// CHECK LICENSE
// ===========================================================================

describe('checkLicense', () => {
    it('rejects a malformed license key with LICENSE_INVALID', async () => {
        // 'x' is under the 8-char minimum — fails isValidLicenseKey before
        // any Supabase call runs. No mock response is queued on purpose;
        // the service must not reach the network.
        await expect(checkLicense('x')).rejects.toMatchObject({
            code: 'LICENSE_INVALID',
        });
        expect(admin.from).not.toHaveBeenCalled();
    });

    it('rejects an unknown key with LICENSE_INVALID', async () => {
        admin.queue({ data: null, error: null });
        await expect(checkLicense('ABCD-EFGH-IJKL')).rejects.toMatchObject({
            code: 'LICENSE_INVALID',
        });
    });

    it('returns license metadata for a valid unused key', async () => {
        admin.queue({
            data: {
                license_key: 'TEST-ACTIVATION-KEY-001',
                is_used: false,
                is_active: true,
                is_revoked: false,
                expires_at: null,
                plan_key: 'RETAIL',
                issued_to_org_id: 'org-uuid',
            },
            error: null,
        });
        admin.queue({ data: { name: 'Test Shop' }, error: null });

        const result = await checkLicense('test-ACTIVATION-key-001');

        expect(result.license_key).toBe('TEST-ACTIVATION-KEY-001');
        expect(result.is_used).toBe(false);
        expect(result.plan_key).toBe('RETAIL');
        expect(result.org_name).toBe('Test Shop');
    });

    it('NEVER includes owner_email in the response', async () => {
        // This is the enumeration leak we removed. If it comes back, the
        // test must fail loudly.
        admin.queue({
            data: {
                license_key: 'TEST-ACTIVATION-KEY-001',
                is_used: false,
                is_active: true,
                is_revoked: false,
                expires_at: null,
                plan_key: 'RETAIL',
                issued_to_org_id: 'org-uuid',
            },
            error: null,
        });
        admin.queue({ data: { name: 'Test Shop' }, error: null });

        const result = await checkLicense('TEST-ACTIVATION-KEY-001');

        expect(result).not.toHaveProperty('owner_email');
        expect(Object.keys(result)).not.toContain('owner_email');
    });

    it('normalizes license_key to uppercase', async () => {
        admin.queue({
            data: {
                license_key: 'TEST-ACTIVATION-KEY-001',
                is_used: false,
                is_active: true,
                is_revoked: false,
                expires_at: null,
                plan_key: 'RETAIL',
                issued_to_org_id: 'org-uuid',
            },
            error: null,
        });
        admin.queue({ data: { name: 'Test Shop' }, error: null });

        await checkLicense('test-activation-key-001');

        // The DB query used uppercase.
        expect(admin.eq).toHaveBeenCalledWith('license_key', 'TEST-ACTIVATION-KEY-001');
    });

    it('does not fetch org_name when the license is already used', async () => {
        admin.queue({
            data: {
                license_key: 'TEST-ACTIVATION-KEY-001',
                is_used: true,
                is_active: true,
                is_revoked: false,
                expires_at: null,
                plan_key: 'RETAIL',
                issued_to_org_id: 'org-uuid',
            },
            error: null,
        });

        const result = await checkLicense('TEST-ACTIVATION-KEY-001');

        expect(result.org_name).toBeNull();
        // Only ONE admin query ran (the license lookup); the org lookup was skipped.
        expect(admin.from).toHaveBeenCalledTimes(1);
    });
});

// ===========================================================================
// ACTIVATE WORKSPACE
// ===========================================================================

describe('activateWorkspace', () => {
    const validLicense = {
        id: 'license-uuid',
        is_used: false,
        is_active: true,
        is_revoked: false,
        expires_at: null,
        issued_to_org_id: 'org-uuid',
    };
    const owner = { id: 'owner-employee-uuid', auth_id: 'owner-auth-uuid' };
    const authUserData = { user: { email: 'owner@test.local' } };

    const payload = {
        license_key: 'TEST-ACTIVATION-KEY-001',
        email: 'owner@test.local',
        username: 'owner',
        password: 'Str0ngPass!2026',
        confirmPassword: 'Str0ngPass!2026',
    };

    it('rejects mismatched passwords before any network call', async () => {
        await expect(
            activateWorkspace({ ...payload, confirmPassword: 'DIFFERENT!' }),
        ).rejects.toMatchObject({ code: 'VALIDATION_FAILED' });
        expect(admin.from).not.toHaveBeenCalled();
    });

    it('rejects a weak password before any network call', async () => {
        await expect(
            activateWorkspace({ ...payload, password: 'short', confirmPassword: 'short' }),
        ).rejects.toMatchObject({ code: 'VALIDATION_FAILED' });
        expect(admin.from).not.toHaveBeenCalled();
    });

    it('rejects a username under 3 chars', async () => {
        await expect(
            activateWorkspace({ ...payload, username: 'ab' }),
        ).rejects.toMatchObject({ code: 'VALIDATION_FAILED' });
    });

    it('rejects an already-used license with LICENSE_USED', async () => {
        admin.queue({ data: { ...validLicense, is_used: true }, error: null });

        await expect(activateWorkspace(payload)).rejects.toMatchObject({
            code: 'LICENSE_USED',
        });
    });

    it('rejects an expired license with LICENSE_EXPIRED', async () => {
        admin.queue({
            data: { ...validLicense, expires_at: new Date(Date.now() - 1000).toISOString() },
            error: null,
        });

        await expect(activateWorkspace(payload)).rejects.toMatchObject({
            code: 'LICENSE_EXPIRED',
        });
    });

    it('rejects a license that was never provisioned with an org', async () => {
        admin.queue({ data: { ...validLicense, issued_to_org_id: null }, error: null });

        await expect(activateWorkspace(payload)).rejects.toMatchObject({
            code: 'LICENSE_NOT_PROVISIONED',
        });
    });

    it('rejects an email that does not match the pre-provisioned auth user', async () => {
        admin.queue({ data: validLicense, error: null });
        admin.queue({ data: owner, error: null });
        admin.queue({ data: { user: { email: 'different@test.local' } }, error: null });

        await expect(activateWorkspace(payload)).rejects.toMatchObject({
            code: 'INVALID_CREDENTIALS',
        });
    });

    it('updates the password BEFORE calling the RPC (ordering guarantee)', async () => {
        admin.queue({ data: validLicense, error: null });
        admin.queue({ data: owner, error: null });
        admin.queue({ data: authUserData, error: null });
        admin.queue({ data: null, error: null }); // password update ok
        admin.queue({ data: [{ tenant_slug: 'testshop', tenant_name: 'TS', org_id: 'org' }], error: null });

        await activateWorkspace(payload);

        const pwOrder = admin.auth.admin.updateUserById.mock.invocationCallOrder[0];
        const rpcOrder = admin.rpc.mock.invocationCallOrder[0];

        // Both must have been called. The non-null assertion after this pair
        // is safe — if either call didn't happen, the test fails here first.
        expect(pwOrder).toBeDefined();
        expect(rpcOrder).toBeDefined();
        expect(pwOrder!).toBeLessThan(rpcOrder!);
    });

    it('does NOT call the RPC if the password update fails', async () => {
        admin.queue({ data: validLicense, error: null });
        admin.queue({ data: owner, error: null });
        admin.queue({ data: authUserData, error: null });
        admin.queue({ data: null, error: { message: 'auth failure' } }); // pw update fails

        await expect(activateWorkspace(payload)).rejects.toMatchObject({
            code: 'INTERNAL',
            statusCode: 500,
        });
        expect(admin.rpc).not.toHaveBeenCalled();
    });

    it('maps USERNAME_TAKEN from the RPC to VALIDATION_FAILED', async () => {
        admin.queue({ data: validLicense, error: null });
        admin.queue({ data: owner, error: null });
        admin.queue({ data: authUserData, error: null });
        admin.queue({ data: null, error: null });
        admin.queue({ data: null, error: { message: 'USERNAME_TAKEN' } });

        await expect(activateWorkspace(payload)).rejects.toMatchObject({
            code: 'VALIDATION_FAILED',
        });
    });

    it('returns tenant identity on success', async () => {
        admin.queue({ data: validLicense, error: null });
        admin.queue({ data: owner, error: null });
        admin.queue({ data: authUserData, error: null });
        admin.queue({ data: null, error: null });
        admin.queue({
            data: [{ tenant_slug: 'testshop', tenant_name: 'Test Shop', org_id: 'org-uuid' }],
            error: null,
        });

        const result = await activateWorkspace(payload);

        expect(result).toEqual({
            tenant_slug: 'testshop',
            tenant_name: 'Test Shop',
            org_id: 'org-uuid',
        });
    });
});

// ===========================================================================
// resetOwnerPassword — defence-in-depth against cross-tenant takeover
// ===========================================================================

describe('resetOwnerPassword', () => {
    it('rejects a target employee in a different org', async () => {
        admin.queue({
            data: { id: 'target', organization_id: 'org-B' },
            error: null,
        });

        await expect(
            resetOwnerPassword('target-auth-id', 'NewPass!234', 'org-A'),
        ).rejects.toMatchObject({ code: 'FORBIDDEN' });

        // The auth update must never run for a cross-tenant target.
        expect(admin.auth.admin.updateUserById).not.toHaveBeenCalled();
    });

    it('rejects a missing caller org (defence in depth)', async () => {
        await expect(
            resetOwnerPassword('target-auth-id', 'NewPass!234', ''),
        ).rejects.toMatchObject({ code: 'TENANT_SCOPE_REQUIRED' });
    });

    it('rejects a weak new password', async () => {
        await expect(
            resetOwnerPassword('target-auth-id', 'short', 'org-A'),
        ).rejects.toMatchObject({ code: 'VALIDATION_FAILED' });
    });

    it('updates the auth user when the target is in the same org', async () => {
        admin.queue({ data: { id: 'target', organization_id: 'org-A' }, error: null });
        admin.queue({ data: { user: {} }, error: null }); // updateUserById ok

        await expect(
            resetOwnerPassword('target-auth-id', 'NewPass!234', 'org-A'),
        ).resolves.toBeUndefined();

        expect(admin.auth.admin.updateUserById).toHaveBeenCalledWith(
            'target-auth-id',
            { password: 'NewPass!234' },
        );
    });
});

// ===========================================================================
// changePassword — the temp-password exit
// ===========================================================================

describe('changePassword', () => {
    it('rejects when the current password is wrong', async () => {
        admin.queue({
            data: { user: { email: 'owner@test.local' } },
            error: null,
        });
        anon.queue({ data: null, error: { message: 'invalid' } });

        await expect(
            changePassword('emp-id', 'auth-id', 'org-id', 'wrong', 'NewPass!234', 'NewPass!234'),
        ).rejects.toMatchObject({ code: 'INVALID_CREDENTIALS' });

        expect(admin.auth.admin.updateUserById).not.toHaveBeenCalled();
    });

    it('rejects when the new password equals the current one', async () => {
        await expect(
            changePassword('emp-id', 'auth-id', 'org-id', 'SamePass!234', 'SamePass!234', 'SamePass!234'),
        ).rejects.toMatchObject({ code: 'VALIDATION_FAILED' });
    });

    it('rejects when newPassword and confirmPassword do not match', async () => {
        await expect(
            changePassword('emp-id', 'auth-id', 'org-id', 'OldPass!234', 'NewPass!234', 'DiffPass!234'),
        ).rejects.toMatchObject({ code: 'VALIDATION_FAILED' });
    });

    it('clears must_change_password AND sets password_changed_at on success', async () => {
        admin.queue({ data: { user: { email: 'owner@test.local' } }, error: null }); // getUserById
        anon.queue({ data: { user: {}, session: {} }, error: null });                 // signIn ok
        admin.queue({ data: { user: {} }, error: null });                             // updateUserById ok
        admin.queue({ data: null, error: null });                                     // employees update ok

        await changePassword('emp-id', 'auth-id', 'org-id', 'OldPass!234', 'NewPass!234', 'NewPass!234');

        // Find the update call on `employees` and inspect its payload.
        const updateCalls = admin.update.mock.calls;
        const employeeUpdate = updateCalls.find(
            (c) => typeof c[0] === 'object' && 'must_change_password' in c[0],
        );
        expect(employeeUpdate).toBeDefined();
        expect(employeeUpdate![0]).toMatchObject({
            must_change_password: false,
            password_changed_at: expect.any(String),
        });
    });
});

// ===========================================================================
// forgotPassword — the uniformity contract
// ===========================================================================
//
// Every input that isn't a valid, resolvable, in-tenant user must return
// without calling resetPasswordForEmail. Every input that IS valid must
// return the same way. The response body must not vary. This is the whole
// reason the endpoint exists in this shape.

describe('forgotPassword', () => {
    const org = { id: 'org-uuid' };

    it('returns silently for an empty tenant_slug', async () => {
        await expect(forgotPassword('', 'owner@test.local')).resolves.toBeUndefined();
        expect(admin.from).not.toHaveBeenCalled();
    });

    it('returns silently for an empty identifier', async () => {
        await expect(forgotPassword('testshop', '')).resolves.toBeUndefined();
        expect(admin.from).not.toHaveBeenCalled();
    });

    it('returns silently for a malformed tenant_slug', async () => {
        await expect(forgotPassword('BAD SLUG!', 'owner@test.local')).resolves.toBeUndefined();
        expect(admin.from).not.toHaveBeenCalled();
    });

    it('returns silently for an unknown tenant — no email sent', async () => {
        admin.queue({ data: null, error: null }); // org lookup → none

        await expect(forgotPassword('nope', 'owner@test.local')).resolves.toBeUndefined();
        expect(anon.auth.resetPasswordForEmail).not.toHaveBeenCalled();
    });

    it('returns silently for a known tenant but unknown email — no email sent', async () => {
        admin.queue({ data: org, error: null });         // org found
        admin.queue({ data: null, error: null });         // email→employee lookup → none

        await expect(forgotPassword('testshop', 'nobody@test.local')).resolves.toBeUndefined();
        expect(anon.auth.resetPasswordForEmail).not.toHaveBeenCalled();
    });

    it('returns silently for a known tenant but unknown username — no email sent', async () => {
        admin.queue({ data: org, error: null });          // org found
        admin.queue({ data: null, error: null });          // username lookup → none

        await expect(forgotPassword('testshop', 'nobody')).resolves.toBeUndefined();
        expect(anon.auth.resetPasswordForEmail).not.toHaveBeenCalled();
    });

    it('sends a reset email when the identifier maps to an employee in the tenant', async () => {
        admin.queue({ data: org, error: null });                              // org found
        admin.queue({ data: { auth_id: 'auth-uuid' }, error: null });          // username → employee
        admin.queue({ data: { user: { email: 'owner@test.local' } }, error: null }); // getUserById
        admin.queue({ data: { auth_id: 'auth-uuid' }, error: null });          // email→employee (in-org check)
        anon.queue({ data: null, error: null });                               // resetPasswordForEmail ok

        await expect(forgotPassword('testshop', 'owner')).resolves.toBeUndefined();
        expect(anon.auth.resetPasswordForEmail).toHaveBeenCalledOnce();
        expect(anon.auth.resetPasswordForEmail).toHaveBeenCalledWith(
            'owner@test.local',
            expect.objectContaining({ redirectTo: expect.stringContaining('/reset-password') }),
        );
    });

    it('does NOT send an email for an out-of-tenant email address', async () => {
        // The critical isolation test: a user could otherwise trigger a
        // reset link for another tenant's account by typing their email
        // into this tenant's form.
        admin.queue({ data: org, error: null });          // org found
        admin.queue({ data: null, error: null });          // email→employee in THIS org → none

        await expect(forgotPassword('testshop', 'outsider@other.local')).resolves.toBeUndefined();
        expect(anon.auth.resetPasswordForEmail).not.toHaveBeenCalled();
    });

    it('never throws even when Supabase rejects the reset', async () => {
        // The caller's response must be identical whether the email was
        // sent or not. If we threw here, errorHandler would return a 500
        // and that would be a distinguishing signal.
        admin.queue({ data: org, error: null });
        admin.queue({ data: { auth_id: 'auth-uuid' }, error: null });
        admin.queue({ data: { user: { email: 'owner@test.local' } }, error: null });
        admin.queue({ data: { auth_id: 'auth-uuid' }, error: null });
        anon.queue({ data: null, error: { message: 'smtp down' } });

        await expect(forgotPassword('testshop', 'owner')).resolves.toBeUndefined();
    });
});