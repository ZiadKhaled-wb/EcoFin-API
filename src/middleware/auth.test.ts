// src/middleware/auth.test.ts
import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Request, Response, NextFunction } from 'express';

vi.mock('../utils/supabase', async () => {
    const { createSupabaseMock } = await import('../test/supabase-mock');
    const anon = createSupabaseMock();
    const user = createSupabaseMock();
    return {
        supabaseAnon: anon,
        supabaseUser: () => user,
        supabaseAdmin: createSupabaseMock(),
    };
});

import { supabaseAnon, supabaseUser } from '../utils/supabase';
import type { SupabaseMock } from '../test/supabase-mock';
import {
    authenticate,
    attachEmployee,
    attachSuperAdmin,
    requireTenant,
    requirePasswordChanged,
    isOwner,
    authorizeModule,
} from './auth';

const anon = supabaseAnon as unknown as SupabaseMock;
const user = supabaseUser('') as unknown as SupabaseMock;

// -----------------------------------------------------------------------
// Express mock helpers
// -----------------------------------------------------------------------

function mockReq(overrides: Partial<Request> = {}): Request {
    return {
        headers: {},
        body: {},
        requestId: 'test-request-id',
        ...overrides,
    } as unknown as Request;
}

function mockRes(): Response {
    const res = {
        status: vi.fn().mockReturnThis(),
        json: vi.fn().mockReturnThis(),
        setHeader: vi.fn().mockReturnThis(),
    };
    return res as unknown as Response;
}

/**
 * Runs a middleware and awaits either `next()` (success) or `next(err)`
 * (failure, via asyncHandler's .catch). Returns the captured error.
 */
async function runMiddleware(
    mw: (req: Request, res: Response, next: NextFunction) => void,
    req: Request,
): Promise<{ res: Response; next: ReturnType<typeof vi.fn>; error: unknown }> {
    const res = mockRes();
    const next = vi.fn();
    await new Promise<void>((resolve) => {
        next.mockImplementation(() => resolve());
        mw(req, res, next);
        // Safety net: if next is never called (bug in the middleware), the
        // promise hangs. setImmediate resolves it and lets the assertion
        // about next being called fail cleanly.
        setImmediate(resolve);
    });
    return { res, next, error: next.mock.calls[0]?.[0] };
}

beforeEach(() => {
    anon.reset();
    user.reset();
    vi.clearAllMocks();
});

// ===========================================================================
// authenticate
// ===========================================================================

describe('authenticate', () => {
    it('rejects a request with no Authorization header', async () => {
        const req = mockReq();
        const { error } = await runMiddleware(authenticate, req);
        expect(error).toMatchObject({ code: 'UNAUTHORIZED', statusCode: 401 });
    });

    it('rejects a header that does not use the Bearer scheme', async () => {
        const req = mockReq({ headers: { authorization: 'Basic abc' } });
        const { error } = await runMiddleware(authenticate, req);
        expect(error).toMatchObject({ code: 'UNAUTHORIZED' });
    });

    it('rejects an invalid token', async () => {
        anon.queue({ data: { user: null }, error: { message: 'invalid' } });
        const req = mockReq({ headers: { authorization: 'Bearer bad-token' } });
        const { error } = await runMiddleware(authenticate, req);
        expect(error).toMatchObject({ code: 'UNAUTHORIZED' });
    });

    it('attaches req.user and req.authToken on a valid token', async () => {
        anon.queue({
            data: { user: { id: 'auth-id', email: 'owner@test.local' } },
            error: null,
        });
        const req = mockReq({ headers: { authorization: 'Bearer valid-token' } });
        const { error, next } = await runMiddleware(authenticate, req);

        expect(error).toBeUndefined();
        expect(next).toHaveBeenCalledWith();
        expect(req.user?.id).toBe('auth-id');
        expect(req.authToken).toBe('valid-token');
    });

    it('never calls supabaseAdmin.auth.getUser — uses anon', async () => {
        // Regression guard: the previous version used the service-role
        // client, which bypasses Supabase's own rate limiting.
        anon.queue({ data: { user: { id: 'auth-id' } }, error: null });
        const req = mockReq({ headers: { authorization: 'Bearer t' } });
        await runMiddleware(authenticate, req);
        expect(anon.auth.getUser).toHaveBeenCalledOnce();
    });
});

// ===========================================================================
// attachEmployee
// ===========================================================================

describe('attachEmployee', () => {
    const authReq = (): Request =>
        mockReq({
            headers: { authorization: 'Bearer t' },
            user: { id: 'auth-id' },
            authToken: 't',
        });

    it('continues with NO employee attached when no row exists (super admin case)', async () => {
        user.queue({ data: null, error: null });
        const req = authReq();
        const { error } = await runMiddleware(attachEmployee, req);

        expect(error).toBeUndefined();
        expect(req.employee).toBeUndefined();
    });

    it('rejects a disabled employee with ACCOUNT_DISABLED', async () => {
        user.queue({
            data: {
                id: 'emp-id',
                organization_id: 'org-id',
                auth_id: 'auth-id',
                branch_id: null,
                role: 'OWNER',
                permissions: [],
                is_active: false,
                username: 'owner',
                email: 'o@t.local',
                must_change_password: false,
            },
            error: null,
        });
        const req = authReq();
        const { error } = await runMiddleware(attachEmployee, req);

        expect(error).toMatchObject({ code: 'ACCOUNT_DISABLED', statusCode: 403 });
    });

    it('attaches a fully-shaped req.employee on success', async () => {
        user.queue({
            data: {
                id: 'emp-id',
                organization_id: 'org-id',
                auth_id: 'auth-id',
                branch_id: null,
                role: 'OWNER',
                permissions: ['pos', 'sales.create'],
                is_active: true,
                username: 'owner',
                email: 'owner@test.local',
                must_change_password: false,
            },
            error: null,
        });
        const req = authReq();
        const { error } = await runMiddleware(attachEmployee, req);

        expect(error).toBeUndefined();
        expect(req.employee).toMatchObject({
            id: 'emp-id',
            organization_id: 'org-id',
            role: 'OWNER',
            permissions: ['pos', 'sales.create'],
        });
    });
});

// ===========================================================================
// requireTenant
// ===========================================================================

describe('requireTenant', () => {
    it('rejects when req.employee is not set', async () => {
        const req = mockReq();
        const { error } = await runMiddleware(requireTenant, req);
        expect(error).toMatchObject({ code: 'TENANT_SCOPE_REQUIRED' });
    });

    it('passes when req.employee is set', async () => {
        const req = mockReq({
            employee: {
                id: 'e', organization_id: 'o', auth_id: 'a', branch_id: null,
                role: 'OWNER', permissions: [], is_active: true,
                username: null, email: null, must_change_password: false,
            },
        });
        const { error } = await runMiddleware(requireTenant, req);
        expect(error).toBeUndefined();
    });
});

// ===========================================================================
// requirePasswordChanged
// ===========================================================================

describe('requirePasswordChanged', () => {
    const employee = (overrides: Partial<NonNullable<Request['employee']>> = {}) => ({
        id: 'e', organization_id: 'o', auth_id: 'a', branch_id: null,
        role: 'OWNER' as const, permissions: [], is_active: true,
        username: null, email: null, must_change_password: false,
        ...overrides,
    });

    it('rejects a user still on a temp password', async () => {
        const req = mockReq({ employee: employee({ must_change_password: true }) });
        const { error } = await runMiddleware(requirePasswordChanged, req);
        expect(error).toMatchObject({ code: 'MUST_CHANGE_PASSWORD', statusCode: 403 });
    });

    it('passes once the flag is cleared', async () => {
        const req = mockReq({ employee: employee({ must_change_password: false }) });
        const { error } = await runMiddleware(requirePasswordChanged, req);
        expect(error).toBeUndefined();
    });

    it('passes when no employee is attached (super admin path)', async () => {
        const req = mockReq();
        const { error } = await runMiddleware(requirePasswordChanged, req);
        expect(error).toBeUndefined();
    });
});

// ===========================================================================
// isOwner
// ===========================================================================

describe('isOwner', () => {
    const employee = (role: string) => ({
        id: 'e', organization_id: 'o', auth_id: 'a', branch_id: null,
        role, permissions: [], is_active: true,
        username: null, email: null, must_change_password: false,
    });

    it('rejects a non-owner', async () => {
        const req = mockReq({ employee: employee('CASHIER') as NonNullable<Request['employee']> });
        const { error } = await runMiddleware(isOwner, req);
        expect(error).toMatchObject({ code: 'FORBIDDEN' });
    });

    it('passes for OWNER', async () => {
        const req = mockReq({ employee: employee('OWNER') as NonNullable<Request['employee']> });
        const { error } = await runMiddleware(isOwner, req);
        expect(error).toBeUndefined();
    });

    it('rejects when no employee is attached', async () => {
        const req = mockReq();
        const { error } = await runMiddleware(isOwner, req);
        expect(error).toMatchObject({ code: 'FORBIDDEN' });
    });
});

// ===========================================================================
// authorizeModule
// ===========================================================================

describe('authorizeModule', () => {
    const employee = (role: string, permissions: string[]) => ({
        id: 'e', organization_id: 'o', auth_id: 'a', branch_id: null,
        role, permissions, is_active: true,
        username: null, email: null, must_change_password: false,
    });

    it('OWNER bypasses the permission array entirely', async () => {
        const req = mockReq({ employee: employee('OWNER', []) as NonNullable<Request['employee']> });
        const { error } = await runMiddleware(authorizeModule('inventory'), req);
        expect(error).toBeUndefined();
    });

    it('CASHIER passes when their permissions include the module', async () => {
        const req = mockReq({
            employee: employee('CASHIER', ['pos', 'sales.create']) as NonNullable<Request['employee']>,
        });
        const { error } = await runMiddleware(authorizeModule('pos'), req);
        expect(error).toBeUndefined();
    });

    it('module-level key matches any of its actions', async () => {
        const req = mockReq({
            employee: employee('CASHIER', ['pos.void']) as NonNullable<Request['employee']>,
        });
        const { error } = await runMiddleware(authorizeModule('pos'), req);
        expect(error).toBeUndefined();
    });

    it('rejects when the caller lacks the permission', async () => {
        const req = mockReq({
            employee: employee('CASHIER', ['pos']) as NonNullable<Request['employee']>,
        });
        const { error } = await runMiddleware(authorizeModule('inventory'), req);
        expect(error).toMatchObject({ code: 'FORBIDDEN' });
    });

    it('rejects when no employee is attached', async () => {
        const req = mockReq();
        const { error } = await runMiddleware(authorizeModule('pos'), req);
        expect(error).toMatchObject({ code: 'FORBIDDEN' });
    });
});

// ===========================================================================
// attachSuperAdmin
// ===========================================================================

describe('attachSuperAdmin', () => {
    const authReq = (): Request =>
        mockReq({
            headers: { authorization: 'Bearer t' },
            user: { id: 'auth-id' },
            authToken: 't',
        });

    it('attaches req.superAdmin when a matching active row exists', async () => {
        user.queue({
            data: {
                id: 'sa-id',
                auth_user_id: 'auth-id',
                email: 'admin@example.com',
                full_name: 'Admin',
                is_active: true,
            },
            error: null,
        });

        const req = authReq();
        const { error } = await runMiddleware(attachSuperAdmin, req);

        expect(error).toBeUndefined();
        expect(req.superAdmin).toMatchObject({
            id: 'sa-id',
            email: 'admin@example.com',
            is_active: true,
        });
    });

    it('leaves req.superAdmin undefined when no row exists (not a super admin)', async () => {
        user.queue({ data: null, error: null });

        const req = authReq();
        const { error } = await runMiddleware(attachSuperAdmin, req);

        expect(error).toBeUndefined();
        expect(req.superAdmin).toBeUndefined();
    });

    it('leaves req.superAdmin undefined when the row is inactive', async () => {
        user.queue({
            data: {
                id: 'sa-id',
                auth_user_id: 'auth-id',
                email: 'admin@example.com',
                full_name: 'Admin',
                is_active: false,
            },
            error: null,
        });

        const req = authReq();
        const { error } = await runMiddleware(attachSuperAdmin, req);

        expect(error).toBeUndefined();
        expect(req.superAdmin).toBeUndefined();
    });
});