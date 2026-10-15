// R05 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh shop's owner assigns a survey to a collector; the collector saves, uploads a photo
// (purpose survey_photo, entity field_survey) and submits; another collector gets 404 on it and the
// collector 403 on decide; the branch manager approves; the customer's credit profile shows the
// residence points and the latest survey; the requirement read follows the published policy.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  CreditProfile,
  ErrorResponse,
  Survey,
  SurveyArray,
  SurveyList,
  SurveyRequirement,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...Array(64).fill(7)]);
const SCORES = {
  housing_quality: 8,
  neighbourhood: 7,
  income_stability: 6,
  job_status: 9,
  property_ownership: 5,
  overall_impression: 7,
};
const CHECKLIST = {
  met_customer: true,
  address_matches: true,
  id_original_seen: true,
  neighbours_confirm: false,
  utility_bill_seen: true,
  workplace_confirmed: true,
};

type Role = 'CASHIER' | 'COLLECTOR' | 'BRANCH_MANAGER';

describe.skipIf(!RUN)('R05 field surveys against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let admin: string;
  let owner: string;
  let cashier: string;
  let manager: string;
  let collector: string;
  let collector2: string;
  let collectorId: string;
  let collector2Id: string;
  let org: string;
  let ip = 0;
  const nextIp = () => `198.18.75.${(++ip % 250) + 1}`;
  const call = (method: 'get' | 'post' | 'patch', path: string, token = owner, body?: object) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', nextIp())
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function newShop(tag: string) {
    const email = `r05.${tag}.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: `R05 ${tag}`,
        tenant_slug: `r05-${tag}-${STAMP}`,
        plan_key: 'retail',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', nextIp())
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    return { id: shop.body.organization_id as string, token: await login(email) };
  }
  async function addEmployee(role: Role, tag: string, branchId: string) {
    const email = `r05.${tag}.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email,
        full_name: `R05 ${tag}`,
        role,
        default_branch_id: branchId,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branchId });
    return { id: emp.data!.id as string, token: await login(email) };
  }
  async function newCustomer(name: string) {
    const r = await call('post', '/api/customers', owner, {
      full_name: `${name} ${STAMP}`,
      phones: ['01500000020'],
      address: '12 Nile St',
      city: 'Cairo',
    });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return (r.body as { id: string }).id;
  }
  async function assign(customerId: string, assignedTo: string) {
    const r = await call('post', '/api/surveys', owner, {
      customer_id: customerId,
      assigned_to: assignedTo,
      visit_type: 'home',
      instructions: 'Ask for the electricity bill',
    });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return Survey.parse(r.body);
  }
  const uploadPhoto = (surveyId: string, token: string) =>
    request(app)
      .post('/api/files')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + token)
      .set('x-org-id', org)
      .field('purpose', 'survey_photo')
      .field('entityType', 'field_survey')
      .field('entityId', surveyId)
      .attach('file', PNG, { filename: 'visit.png', contentType: 'image/png' });

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    admin = await login('superadmin@ecotech.test');
    const shop = await newShop('main');
    org = shop.id;
    owner = shop.token;
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    cashier = (await addEmployee('CASHIER', 'cashier', main.data!.id)).token;
    manager = (await addEmployee('BRANCH_MANAGER', 'manager', main.data!.id)).token;
    const c1 = await addEmployee('COLLECTOR', 'collector1', main.data!.id);
    const c2 = await addEmployee('COLLECTOR', 'collector2', main.data!.id);
    collector = c1.token;
    collectorId = c1.id;
    collector2 = c2.token;
    collector2Id = c2.id;
  }, 120_000);

  it('assign -> save -> photo -> submit -> approve, and the credit profile shows it', async () => {
    const customerId = await newCustomer('Survey Customer');
    const survey = await assign(customerId, collectorId);
    expect(survey).toMatchObject({
      status: 'assigned',
      assigned_to: { id: collectorId },
      customer: { id: customerId, city: 'Cairo' },
      instructions: 'Ask for the electricity bill',
    });

    const again = await call('post', '/api/surveys', owner, {
      customer_id: customerId,
      assigned_to: collector2Id,
    });
    expect(again.status).toBe(409);
    expect(code(again)).toBe('SURVEY_ALREADY_OPEN');
    expect(again.body.error.details).toMatchObject({ survey_id: survey.id, status: 'assigned' });

    // The collector sees it in Mine; another collector doesn't see it at all.
    const mine = SurveyList.parse((await call('get', '/api/surveys?mine=true', collector)).body);
    expect(mine.items.map((s) => s.id)).toContain(survey.id);
    const other = await call('get', `/api/surveys/${survey.id}`, collector2);
    expect(other.status).toBe(404);
    expect(code(other)).toBe('SURVEY_NOT_FOUND');
    const otherPhoto = await uploadPhoto(survey.id, collector2);
    expect(otherPhoto.status).toBe(403);

    const saved = await call('patch', `/api/surveys/${survey.id}`, collector, {
      scores: { housing_quality: 8 },
      notes: '  Clean flat  ',
    });
    expect(saved.status, JSON.stringify(saved.body)).toBe(200);
    expect(Survey.parse(saved.body)).toMatchObject({
      scores: { housing_quality: 8 },
      notes: 'Clean flat',
    });
    const badScore = await call('patch', `/api/surveys/${survey.id}`, collector, {
      scores: { job_status: 11 },
    });
    expect(badScore.status).toBe(400);

    const noPhoto = await call('post', `/api/surveys/${survey.id}/submit`, collector, {
      scores: SCORES,
      checklist: CHECKLIST,
      gps: {
        lat: 30.0444,
        lng: 31.2357,
        gps_accuracy_m: 150,
        client_captured_at: new Date().toISOString(),
      },
    });
    expect(noPhoto.status).toBe(409);
    expect(code(noPhoto)).toBe('SURVEY_PHOTO_REQUIRED');

    const photo = await uploadPhoto(survey.id, collector);
    expect(photo.status, JSON.stringify(photo.body)).toBe(201);
    // Photos stay private: the collector (no customer.view_pii) can't list them.
    const listed = await call(
      'get',
      `/api/files?entityType=field_survey&entityId=${survey.id}`,
      collector,
    );
    expect(listed.status).toBe(200);
    expect((listed.body as { items: unknown[] }).items).toHaveLength(0);
    const ownerList = await call('get', `/api/files?entityType=field_survey&entityId=${survey.id}`);
    expect(ownerList.status).toBe(200);
    expect((ownerList.body as { items: unknown[] }).items).toHaveLength(1);

    const submitted = await call('post', `/api/surveys/${survey.id}/submit`, collector, {
      scores: SCORES,
      checklist: CHECKLIST,
      gps: {
        lat: 30.0444,
        lng: 31.2357,
        gps_accuracy_m: 150,
        client_captured_at: new Date().toISOString(),
      },
    });
    expect(submitted.status, JSON.stringify(submitted.body)).toBe(200);
    expect(Survey.parse(submitted.body)).toMatchObject({
      status: 'submitted',
      survey_score: 70,
      gps_low_accuracy: true,
      photos_count: 1,
    });

    const collectorDecides = await call('post', `/api/surveys/${survey.id}/decide`, collector, {
      decision: 'approve',
    });
    expect(collectorDecides.status).toBe(403);
    const cashierDecides = await call('post', `/api/surveys/${survey.id}/decide`, cashier, {
      decision: 'approve',
    });
    expect(cashierDecides.status).toBe(403);
    const noNote = await call('post', `/api/surveys/${survey.id}/decide`, manager, {
      decision: 'reject',
    });
    expect(noNote.status).toBe(400);

    const approved = await call('post', `/api/surveys/${survey.id}/decide`, manager, {
      decision: 'approve',
      note: 'Looks fine',
    });
    expect(approved.status, JSON.stringify(approved.body)).toBe(200);
    expect(Survey.parse(approved.body)).toMatchObject({ status: 'approved' });
    expect(Survey.parse(approved.body).valid_until).not.toBeNull();
    const twice = await call('post', `/api/surveys/${survey.id}/decide`, manager, {
      decision: 'approve',
    });
    expect(twice.status).toBe(409);
    expect(code(twice)).toBe('SURVEY_WRONG_STATUS');

    const profile = CreditProfile.parse(
      (await call('get', `/api/customers/${customerId}/credit`)).body,
    );
    expect(profile.latest_survey).toMatchObject({
      id: survey.id,
      status: 'approved',
      survey_score: 70,
    });
    const residence = profile.components.find((c) => c.key === 'residence')!;
    expect(residence.value).toBe(0.7);
    expect(residence.points).toBe(residence.weight * 0.7);

    const customerList = SurveyArray.parse(
      (await call('get', `/api/customers/${customerId}/surveys`, cashier)).body,
    );
    expect(customerList.map((s) => s.id)).toEqual([survey.id]);
  });

  it('reassign, cancel and who may', async () => {
    const customerId = await newCustomer('Cancel Customer');
    const survey = await assign(customerId, collectorId);
    const toCashier = await call('post', `/api/surveys/${survey.id}/reassign`, owner, {
      assigned_to: (
        await service
          .from('employees')
          .select('id')
          .eq('organization_id', org)
          .eq('role', 'CASHIER')
          .single()
      ).data!.id,
    });
    expect(toCashier.status).toBe(409);
    expect(code(toCashier)).toBe('SURVEY_ASSIGNEE_INVALID');
    const moved = await call('post', `/api/surveys/${survey.id}/reassign`, manager, {
      assigned_to: collector2Id,
    });
    expect(moved.status, JSON.stringify(moved.body)).toBe(200);
    expect(Survey.parse(moved.body).assigned_to.id).toBe(collector2Id);
    const notMine = await call('patch', `/api/surveys/${survey.id}`, collector, { notes: 'x' });
    expect(notMine.status).toBe(404);
    const cashierAssigns = await call('post', '/api/surveys', cashier, {
      customer_id: customerId,
      assigned_to: collectorId,
    });
    expect(cashierAssigns.status).toBe(403);
    const shortReason = await call('post', `/api/surveys/${survey.id}/cancel`, owner, {
      reason: 'no',
    });
    expect(shortReason.status).toBe(400);
    const cancelled = await call('post', `/api/surveys/${survey.id}/cancel`, owner, {
      reason: 'Customer moved',
    });
    expect(cancelled.status, JSON.stringify(cancelled.body)).toBe(200);
    expect(Survey.parse(cancelled.body)).toMatchObject({
      status: 'cancelled',
      decision_note: 'Customer moved',
    });
  });

  it('the requirement follows the published policy', async () => {
    const customerId = await newCustomer('Requirement Customer');
    const url = (amount: string) =>
      `/api/customers/${customerId}/survey-requirement?financed_amount=${amount}`;
    expect(SurveyRequirement.parse((await call('get', url('25000.00'))).body)).toMatchObject({
      required_above: null,
      required: false,
      met: true,
    });
    const published = await call('post', '/api/settings/installment-policies', owner, {
      survey_required_above: '20000.00',
    });
    expect(published.status, JSON.stringify(published.body)).toBe(201);
    expect(SurveyRequirement.parse((await call('get', url('25000.00'))).body)).toMatchObject({
      required_above: '20000.00',
      required: true,
      valid_survey: null,
      met: false,
    });
    expect(SurveyRequirement.parse((await call('get', url('20000.00'))).body)).toMatchObject({
      required: false,
      met: true,
    });
    const survey = await assign(customerId, collectorId);
    expect(SurveyRequirement.parse((await call('get', url('25000.00'))).body)).toMatchObject({
      open_survey: { id: survey.id, status: 'assigned' },
      met: false,
    });
    const bad = await call('get', url('abc'));
    expect(bad.status).toBe(400);
  });
});
