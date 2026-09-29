// server/src/docs/openapi.ts
//
// Single source of truth for the HTTP API. Served by Swagger UI at /docs.
//
// WHY A .ts FILE AND NOT .yaml:
//   A YAML spec would need to be read from disk at runtime and copied into
//   dist/ during build — an extra step that's easy to forget and hard to
//   debug. A TS module is compiled with the rest of the source, gives
//   autocomplete while editing, and fails at typecheck if malformed.
//
// WHEN THIS FILE GETS PAINFUL (roughly >30 endpoints): migrate to a
// generator that derives the spec from Zod schemas (see @asteasolutions/
// zod-to-openapi) so request/response shapes can't drift from the
// validators. For now, hand-written is smaller than the migration.

export const openApiSpec = {
    openapi: '3.0.3',
    info: {
        title: 'EcoFin Pro API',
        version: '0.1.0',
        description:
            'Multi-tenant retail ERP/POS. Tenant scope is resolved from the ' +
            'JWT `sub` claim against the `employees` table. The `license_key` ' +
            'is a one-time activation credential and is never accepted on an ' +
            'authenticated endpoint.',
    },
    servers: [
        { url: 'http://localhost:3001', description: 'Local development' },
    ],
    tags: [
        { name: 'Health', description: 'Liveness probes' },
        { name: 'Auth — public', description: 'No authentication required' },
        { name: 'Auth — authenticated', description: 'Requires a bearer JWT' },
    ],
    components: {
        securitySchemes: {
            bearerAuth: {
                type: 'http',
                scheme: 'bearer',
                bearerFormat: 'JWT',
                description:
                    'The `access_token` returned by /api/auth/login. ' +
                    'Paste it into the Authorize dialog — Swagger sends it on ' +
                    'every request from the same page.',
            },
        },
        schemas: {
            Error: {
                type: 'object',
                required: ['error', 'code', 'requestId'],
                properties: {
                    error: { type: 'string', description: 'User-facing message (Arabic)' },
                    code: {
                        type: 'string',
                        description: 'Machine-readable error code',
                        example: 'INVALID_CREDENTIALS',
                    },
                    requestId: { type: 'string', format: 'uuid' },
                    details: {
                        description: 'Optional structured detail. Sensitive keys are redacted.',
                        nullable: true,
                    },
                },
            },

            // ---------- Requests ----------

            LoginRequest: {
                type: 'object',
                required: ['tenant_slug', 'identifier', 'password'],
                properties: {
                    tenant_slug: {
                        type: 'string',
                        example: 'testshop',
                        description: 'Public tenant identifier (organizations.tenant_slug).',
                    },
                    identifier: {
                        type: 'string',
                        example: 'owner',
                        description: 'Username OR email. Usernames are org-scoped.',
                    },
                    password: { type: 'string', format: 'password', example: 'Str0ngPass!2026' },
                },
            },

            CheckLicenseRequest: {
                type: 'object',
                required: ['license_key'],
                properties: {
                    license_key: {
                        type: 'string',
                        example: 'TEST-ACTIVATION-KEY-001',
                        description: 'Case-insensitive. Hyphens required.',
                    },
                },
            },

            ActivateWorkspaceRequest: {
                type: 'object',
                required: ['license_key', 'email', 'username', 'password', 'confirmPassword'],
                properties: {
                    license_key: { type: 'string', example: 'TEST-ACTIVATION-KEY-001' },
                    email: {
                        type: 'string',
                        format: 'email',
                        example: 'owner@test.local',
                        description: 'Must match the pre-provisioned auth user email.',
                    },
                    username: {
                        type: 'string',
                        minLength: 3,
                        example: 'owner',
                        description: 'Uniqueness is enforced within the tenant, not globally.',
                    },
                    password: { type: 'string', format: 'password', minLength: 8 },
                    confirmPassword: { type: 'string', format: 'password' },
                },
            },

            ForgotPasswordRequest: {
                type: 'object',
                required: ['tenant_slug', 'identifier'],
                properties: {
                    tenant_slug: { type: 'string', example: 'testshop' },
                    identifier: {
                        type: 'string',
                        example: 'owner@test.local',
                        description: 'Username or email. Response is identical either way.',
                    },
                },
            },

            ChangePasswordRequest: {
                type: 'object',
                required: ['currentPassword', 'newPassword', 'confirmPassword'],
                properties: {
                    currentPassword: { type: 'string', format: 'password' },
                    newPassword: { type: 'string', format: 'password', minLength: 8 },
                    confirmPassword: { type: 'string', format: 'password' },
                },
            },

            ResetOwnerPasswordRequest: {
                type: 'object',
                required: ['userId', 'newPassword'],
                properties: {
                    userId: {
                        type: 'string',
                        format: 'uuid',
                        description: "Target employee's Supabase auth_id. Must be in the caller's org.",
                    },
                    newPassword: { type: 'string', format: 'password', minLength: 8 },
                },
            },

            // ---------- Responses ----------

            LoginUser: {
                type: 'object',
                required: [
                    'id', 'personId', 'email', 'username', 'role',
                    'branchId', 'orgId', 'permissions', 'isSuperAdmin',
                ],
                properties: {
                    id: { type: 'string', format: 'uuid', description: 'Supabase auth user id.' },
                    personId: {
                        type: 'string',
                        format: 'uuid',
                        description: 'employees.id, or super_admins.id for platform users.',
                    },
                    email: { type: 'string', nullable: true },
                    username: { type: 'string', nullable: true },
                    role: {
                        type: 'string',
                        enum: [
                            'OWNER', 'OPS_MANAGER', 'ACCOUNTANT', 'CASHIER',
                            'COLLECTOR', 'WAREHOUSE_MANAGER', 'HR_MANAGER',
                            'LAWYER', 'EMPLOYEE', 'SUPER_ADMIN',
                        ],
                    },
                    branchId: { type: 'string', format: 'uuid', nullable: true },
                    orgId: { type: 'string', format: 'uuid', nullable: true },
                    permissions: { type: 'array', items: { type: 'string' }, example: ['pos', 'sales.create'] },
                    isSuperAdmin: { type: 'boolean' },
                },
            },

            LoginResponse: {
                type: 'object',
                required: ['user', 'session', 'must_change_password'],
                properties: {
                    user: { $ref: '#/components/schemas/LoginUser' },
                    session: {
                        type: 'object',
                        required: ['access_token', 'refresh_token'],
                        properties: {
                            access_token: { type: 'string' },
                            refresh_token: { type: 'string' },
                        },
                    },
                    must_change_password: {
                        type: 'boolean',
                        description:
                            'When true, every endpoint except /change-password and ' +
                            '/logout returns 403 MUST_CHANGE_PASSWORD.',
                    },
                },
            },

            CheckLicenseResponse: {
                type: 'object',
                required: ['license_key', 'is_used', 'plan_key', 'org_name'],
                properties: {
                    license_key: { type: 'string' },
                    is_used: { type: 'boolean' },
                    plan_key: { type: 'string', nullable: true },
                    org_name: { type: 'string', nullable: true },
                },
                description:
                    'Deliberately omits owner_email. Returning it here would let ' +
                    'anyone with a license key enumerate a business owner address.',
            },

            ActivateWorkspaceResponse: {
                type: 'object',
                required: ['tenant_slug', 'tenant_name', 'org_id'],
                properties: {
                    tenant_slug: { type: 'string', example: 'testshop' },
                    tenant_name: { type: 'string', example: 'Test Shop' },
                    org_id: { type: 'string', format: 'uuid' },
                },
            },

            MeResponse: {
                type: 'object',
                required: ['id', 'personId', 'role', 'isSuperAdmin', 'must_change_password'],
                properties: {
                    id: { type: 'string', format: 'uuid' },
                    personId: { type: 'string', format: 'uuid' },
                    email: { type: 'string', nullable: true },
                    username: { type: 'string', nullable: true },
                    role: { type: 'string' },
                    branchId: { type: 'string', format: 'uuid', nullable: true },
                    orgId: { type: 'string', format: 'uuid', nullable: true },
                    permissions: { type: 'array', items: { type: 'string' } },
                    isSuperAdmin: { type: 'boolean' },
                    must_change_password: { type: 'boolean' },
                },
            },

            SuccessResponse: {
                type: 'object',
                required: ['success'],
                properties: { success: { type: 'boolean', example: true } },
            },
        },

        responses: {
            InvalidCredentials: {
                description:
                    'Returned identically for: unknown tenant slug, unknown user, wrong password.',
                content: {
                    'application/json': {
                        schema: { $ref: '#/components/schemas/Error' },
                        example: {
                            error: 'بيانات الدخول غير صحيحة.',
                            code: 'INVALID_CREDENTIALS',
                            requestId: '00000000-0000-0000-0000-000000000000',
                        },
                    },
                },
            },
            Unauthorized: {
                description: 'Missing or invalid bearer token.',
                content: {
                    'application/json': {
                        schema: { $ref: '#/components/schemas/Error' },
                        example: {
                            error: 'مطلوب تسجيل الدخول',
                            code: 'UNAUTHORIZED',
                            requestId: '00000000-0000-0000-0000-000000000000',
                        },
                    },
                },
            },
            Forbidden: {
                description: 'Authenticated but not permitted, or account disabled.',
                content: {
                    'application/json': {
                        schema: { $ref: '#/components/schemas/Error' },
                    },
                },
            },
            TooManyRequests: {
                description: 'Rate limit exceeded. Retry-After header is set.',
                content: {
                    'application/json': {
                        schema: { $ref: '#/components/schemas/Error' },
                    },
                },
            },
            BadRequest: {
                description: 'Validation failure or domain error.',
                content: {
                    'application/json': {
                        schema: { $ref: '#/components/schemas/Error' },
                    },
                },
            },
        },
    },

    paths: {
        // =========================================================
        // Health
        // =========================================================
        '/health': {
            get: {
                tags: ['Health'],
                summary: 'Liveness probe',
                security: [],
                responses: {
                    200: {
                        description: 'Service is up',
                        content: {
                            'application/json': {
                                schema: {
                                    type: 'object',
                                    properties: {
                                        ok: { type: 'boolean' },
                                        service: { type: 'string' },
                                        env: { type: 'string' },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },

        // =========================================================
        // Public auth
        // =========================================================
        '/api/auth/login': {
            post: {
                tags: ['Auth — public'],
                summary: 'Log in with username or email',
                security: [],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': { schema: { $ref: '#/components/schemas/LoginRequest' } },
                    },
                },
                responses: {
                    200: {
                        description: 'Login succeeded',
                        content: {
                            'application/json': { schema: { $ref: '#/components/schemas/LoginResponse' } },
                        },
                    },
                    401: { $ref: '#/components/responses/InvalidCredentials' },
                    403: {
                        description: 'Account is disabled (ACCOUNT_DISABLED) — only after correct password.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/Error' },
                                example: {
                                    error: 'هذا الحساب معطل. يرجى التواصل مع الإدارة.',
                                    code: 'ACCOUNT_DISABLED',
                                    requestId: '00000000-0000-0000-0000-000000000000',
                                },
                            },
                        },
                    },
                    429: { $ref: '#/components/responses/TooManyRequests' },
                },
            },
        },

        '/api/auth/check-license': {
            post: {
                tags: ['Auth — public'],
                summary: 'Look up a license key (side-effect free)',
                security: [],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': { schema: { $ref: '#/components/schemas/CheckLicenseRequest' } },
                    },
                },
                responses: {
                    200: {
                        description: 'License found',
                        content: {
                            'application/json': { schema: { $ref: '#/components/schemas/CheckLicenseResponse' } },
                        },
                    },
                    400: {
                        description: 'Invalid or unknown license key',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/Error' },
                                example: {
                                    error: 'كود التفعيل غير صحيح.',
                                    code: 'LICENSE_INVALID',
                                    requestId: '00000000-0000-0000-0000-000000000000',
                                },
                            },
                        },
                    },
                    429: { $ref: '#/components/responses/TooManyRequests' },
                },
            },
        },

        '/api/auth/activate-workspace': {
            post: {
                tags: ['Auth — public'],
                summary: 'One-time activation: sets username + real password, flips is_used',
                security: [],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': { schema: { $ref: '#/components/schemas/ActivateWorkspaceRequest' } },
                    },
                },
                responses: {
                    200: {
                        description: 'Activation succeeded',
                        content: {
                            'application/json': { schema: { $ref: '#/components/schemas/ActivateWorkspaceResponse' } },
                        },
                    },
                    400: {
                        description: 'Domain error (LICENSE_USED, LICENSE_EXPIRED, VALIDATION_FAILED…)',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/Error' },
                                examples: {
                                    alreadyUsed: {
                                        value: {
                                            error: 'تم استخدام كود التفعيل هذا بالفعل.',
                                            code: 'LICENSE_USED',
                                            requestId: '00000000-0000-0000-0000-000000000000',
                                        },
                                    },
                                    usernameTaken: {
                                        value: {
                                            error: 'اسم المستخدم هذا مستخدم بالفعل، يرجى اختيار اسم آخر.',
                                            code: 'VALIDATION_FAILED',
                                            requestId: '00000000-0000-0000-0000-000000000000',
                                        },
                                    },
                                },
                            },
                        },
                    },
                    401: { $ref: '#/components/responses/InvalidCredentials' },
                    404: {
                        description: 'License exists but no owner provisioned yet (LICENSE_NOT_PROVISIONED).',
                        content: {
                            'application/json': { schema: { $ref: '#/components/schemas/Error' } },
                        },
                    },
                    429: { $ref: '#/components/responses/TooManyRequests' },
                },
            },
        },

        '/api/auth/forgot-password': {
            post: {
                tags: ['Auth — public'],
                summary: 'Trigger a password reset email (Supabase native magic link)',
                description:
                    'Always returns 200 regardless of whether the identifier exists. ' +
                    'This is intentional — it prevents email enumeration.',
                security: [],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': { schema: { $ref: '#/components/schemas/ForgotPasswordRequest' } },
                    },
                },
                responses: {
                    200: {
                        description: 'Request accepted (identity-independent)',
                        content: {
                            'application/json': { schema: { $ref: '#/components/schemas/SuccessResponse' } },
                        },
                    },
                    429: { $ref: '#/components/responses/TooManyRequests' },
                },
            },
        },

        // =========================================================
        // Authenticated auth
        // =========================================================
        '/api/auth/change-password': {
            post: {
                tags: ['Auth — authenticated'],
                summary: 'Change own password (the temp-password exit)',
                description:
                    'This is one of only two endpoints reachable when ' +
                    'must_change_password is true (the other is /logout).',
                security: [{ bearerAuth: [] }],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': { schema: { $ref: '#/components/schemas/ChangePasswordRequest' } },
                    },
                },
                responses: {
                    200: {
                        description: 'Password updated',
                        content: {
                            'application/json': { schema: { $ref: '#/components/schemas/SuccessResponse' } },
                        },
                    },
                    400: { $ref: '#/components/responses/BadRequest' },
                    401: {
                        description: 'currentPassword is wrong (INVALID_CREDENTIALS)',
                        content: {
                            'application/json': { schema: { $ref: '#/components/schemas/Error' } },
                        },
                    },
                    403: { $ref: '#/components/responses/Forbidden' },
                },
            },
        },

        '/api/auth/reset-owner-password': {
            post: {
                tags: ['Auth — authenticated'],
                summary: 'Owner-initiated reset of another employee in the same org',
                description:
                    'Requires role OWNER and must_change_password = false. The service ' +
                    'layer re-verifies the target employee is in the caller org ' +
                    '(defence in depth against a middleware mistake).',
                security: [{ bearerAuth: [] }],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': { schema: { $ref: '#/components/schemas/ResetOwnerPasswordRequest' } },
                    },
                },
                responses: {
                    200: {
                        description: 'Password updated',
                        content: {
                            'application/json': { schema: { $ref: '#/components/schemas/SuccessResponse' } },
                        },
                    },
                    401: { $ref: '#/components/responses/Unauthorized' },
                    403: { $ref: '#/components/responses/Forbidden' },
                    404: {
                        description: 'Target employee not found',
                        content: {
                            'application/json': { schema: { $ref: '#/components/schemas/Error' } },
                        },
                    },
                },
            },
        },

        '/api/auth/me': {
            get: {
                tags: ['Auth — authenticated'],
                summary: 'Return the current principal',
                security: [{ bearerAuth: [] }],
                responses: {
                    200: {
                        description: 'Current user',
                        content: {
                            'application/json': { schema: { $ref: '#/components/schemas/MeResponse' } },
                        },
                    },
                    401: { $ref: '#/components/responses/Unauthorized' },
                    403: {
                        description:
                            'MUST_CHANGE_PASSWORD if the temp-password flag is still set; ' +
                            'ACCOUNT_DISABLED if the account is inactive.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/Error' },
                                examples: {
                                    mustChange: {
                                        value: {
                                            error: 'يجب تغيير كلمة المرور قبل المتابعة.',
                                            code: 'MUST_CHANGE_PASSWORD',
                                            requestId: '00000000-0000-0000-0000-000000000000',
                                        },
                                    },
                                    disabled: {
                                        value: {
                                            error: 'هذا الحساب معطل. يرجى التواصل مع الإدارة.',
                                            code: 'ACCOUNT_DISABLED',
                                            requestId: '00000000-0000-0000-0000-000000000000',
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },

        '/api/auth/logout': {
            post: {
                tags: ['Auth — authenticated'],
                summary: 'Client-side logout (no server-side revocation in v1)',
                description:
                    'Stateless JWT. The client clears its tokens. Server-side ' +
                    'session revocation is deferred to v1.1 (see ADR-0004).',
                security: [{ bearerAuth: [] }],
                responses: {
                    200: {
                        description: 'Always succeeds',
                        content: {
                            'application/json': { schema: { $ref: '#/components/schemas/SuccessResponse' } },
                        },
                    },
                    401: { $ref: '#/components/responses/Unauthorized' },
                },
            },
        },
    },
} as const;

export type OpenApiSpec = typeof openApiSpec;