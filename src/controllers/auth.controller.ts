import type { Request, Response } from 'express';
import * as authService from '../services/auth.service';
import { Unauthorized } from '../utils/errors';

export async function login(req: Request, res: Response) {
  const { tenant_slug, identifier, password } = (req.body ?? {}) as Record<string, unknown>;
  const result = await authService.login(
    tenant_slug as string,
    identifier as string,
    password as string,
  );
  return res.json(result);
}

export async function checkLicense(req: Request, res: Response) {
  const { license_key } = (req.body ?? {}) as Record<string, unknown>;
  const result = await authService.checkLicense(license_key as string);
  return res.json(result);
}

export async function activateWorkspace(req: Request, res: Response) {
  const body = (req.body ?? {}) as authService.ActivateWorkspacePayload;
  const result = await authService.activateWorkspace(body);
  return res.json(result);
}

export async function forgotPassword(req: Request, res: Response) {
  const { tenant_slug, identifier } = (req.body ?? {}) as Record<string, unknown>;
  await authService.forgotPassword(tenant_slug as string, identifier as string);
  return res.json({ success: true });
}

export async function resetOwnerPassword(req: Request, res: Response) {
  const employee = req.employee;
  if (!employee) throw Unauthorized('مطلوب تسجيل الدخول', 'UNAUTHORIZED');
  const { userId, newPassword } = (req.body ?? {}) as Record<string, unknown>;
  await authService.resetOwnerPassword(
    userId as string,
    newPassword as string,
    employee.organization_id,
  );
  return res.json({ success: true });
}

export async function changePassword(req: Request, res: Response) {
  const employee = req.employee;
  const user = req.user;
  if (!employee || !user) throw Unauthorized('مطلوب تسجيل الدخول', 'UNAUTHORIZED');

  const { currentPassword, newPassword, confirmPassword } = (req.body ?? {}) as Record<
    string,
    unknown
  >;

  await authService.changePassword(
    employee.id,
    user.id,
    employee.organization_id,
    currentPassword as string,
    newPassword as string,
    confirmPassword as string,
  );
  return res.json({ success: true });
}

export async function getCurrentUser(req: Request, res: Response) {
  if (req.superAdmin) {
    return res.json({
      id: req.superAdmin.id,
      personId: req.superAdmin.id,
      email: req.superAdmin.email,
      username: null,
      role: 'SUPER_ADMIN',
      branchId: null,
      orgId: null,
      permissions: [],
      isSuperAdmin: true,
      must_change_password: false,
    });
  }
  if (!req.employee) {
    throw Unauthorized('مطلوب تسجيل الدخول', 'UNAUTHORIZED');
  }
  return res.json({
    id: req.employee.id,
    personId: req.employee.id,
    email: req.employee.email,
    username: req.employee.username,
    role: req.employee.role,
    branchId: req.employee.branch_id,
    orgId: req.employee.organization_id,
    permissions: req.employee.permissions,
    isSuperAdmin: false,
    must_change_password: req.employee.must_change_password,
  });
}

export async function logout(_req: Request, res: Response) {
  // Stateless JWTs. The client clears its tokens. A server-side deny-list
  // (session revocation) is deferred to v1.1 — see ADR-0004.
  return res.json({ success: true });
}

export async function refresh(req: Request, res: Response) {
  const { refresh_token } = (req.body ?? {}) as Record<string, unknown>;
  const result = await authService.refreshSession(refresh_token as string);
  return res.json(result);
}
