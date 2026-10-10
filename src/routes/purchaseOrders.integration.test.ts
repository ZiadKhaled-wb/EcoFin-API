// U05 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh shop's owner creates an order (one key, twice), edits and sends it, receives part of it
// as a draft invoice and approves it (partially_received), is refused above what is still to
// come, receives the rest (received) and can't receive a closed order; stock rises by exactly
// what was approved. A warehouse user orders and receives but can't approve.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  PurchaseInvoice,
  PurchaseOrder,
  PurchaseOrderList,
  StockList,
  Supplier,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('U05 purchase orders against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let warehouse: string;
  let org: string;
  let branch: string;
  let supplierId: string;
  let tv: string;
  let cable: string;
  let ip = 0;
  const call = (
    method: 'get' | 'post' | 'put',
    path: string,
    token = owner,
    body?: object,
    key?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.57.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.57.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  const onHand = async (id: string) =>
    StockList.parse((await call('get', `/api/stock?branch_id=${branch}`)).body).items.find(
      (r) => r.product_id === id,
    )?.on_hand ?? 0;
  const order = async (id: string) =>
    PurchaseOrder.parse((await call('get', `/api/purchase-orders/${id}`)).body);

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `u05.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.57.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'U05 shop',
        tenant_slug: `u05-${STAMP}`,
        plan_key: 'retail',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.57.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);

    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    branch = main.data!.id as string;
    const whEmail = `u05.warehouse.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email: whEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email: whEmail,
        full_name: 'Warehouse',
        role: 'WAREHOUSE',
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branch });
    warehouse = await login(whEmail);

    const supplier = await call('post', '/api/suppliers', owner, { name: 'Nile Traders' });
    expect(supplier.status, JSON.stringify(supplier.body)).toBe(201);
    supplierId = Supplier.parse(supplier.body).id;
    const p1 = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون',
      sku: 'U05-TV',
      cash_price: '200.00',
    });
    expect(p1.status, JSON.stringify(p1.body)).toBe(201);
    tv = (p1.body as { id: string }).id;
    const p2 = await call('post', '/api/products', owner, {
      name_ar: 'كابل',
      sku: 'U05-CB',
      cash_price: '20.00',
    });
    expect(p2.status, JSON.stringify(p2.body)).toBe(201);
    cable = (p2.body as { id: string }).id;
  }, 60_000);

  it('owner: order, send, receive part (partially_received), the rest (received), then closed', async () => {
    const body = {
      supplier_id: supplierId,
      branch_id: branch,
      notes: ' Call first ',
      lines: [
        { product_id: tv, quantity: 10, expected_unit_cost: '100.00' },
        { product_id: cable, quantity: 5 },
      ],
    };
    expect((await call('post', '/api/purchase-orders', owner, body)).status).toBe(400);
    const key = `u05-it-${STAMP}`;
    const created = await call('post', '/api/purchase-orders', owner, body, key);
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const draft = PurchaseOrder.parse(created.body);
    expect(draft).toMatchObject({ status: 'draft', notes: 'Call first', invoices: [] });
    expect(draft.number).toContain('PO');
    const again = await call('post', '/api/purchase-orders', owner, body, key);
    expect(PurchaseOrder.parse(again.body).id).toBe(draft.id);
    const tvLine = draft.lines.find((l) => l.product_id === tv)!;
    const cableLine = draft.lines.find((l) => l.product_id === cable)!;

    const edited = await call('put', `/api/purchase-orders/${draft.id}`, owner, {
      expected_date: '2026-12-01',
    });
    expect(edited.status, JSON.stringify(edited.body)).toBe(200);
    expect(PurchaseOrder.parse(edited.body).expected_date).toBe('2026-12-01');
    const tooEarly = await call(
      'post',
      `/api/purchase-orders/${draft.id}/invoice`,
      owner,
      {},
      `u05-it-early-${STAMP}`,
    );
    expect(tooEarly.status).toBe(409);
    expect(code(tooEarly)).toBe('PO_NOT_SENT');
    const sent = await call('post', `/api/purchase-orders/${draft.id}/send`);
    expect(PurchaseOrder.parse(sent.body).status).toBe('sent');
    const late = await call('put', `/api/purchase-orders/${draft.id}`, owner, { notes: 'late' });
    expect(late.status).toBe(409);
    expect(code(late)).toBe('PURCHASE_ORDER_NOT_EDITABLE');

    const recvKey = `u05-it-recv-${STAMP}`;
    const recvBody = {
      lines: [
        { po_line_id: tvLine.id, quantity: 6 },
        { po_line_id: cableLine.id, quantity: 5, unit_cost: '9.50' },
      ],
    };
    const received = await call(
      'post',
      `/api/purchase-orders/${draft.id}/invoice`,
      owner,
      recvBody,
      recvKey,
    );
    expect(received.status, JSON.stringify(received.body)).toBe(201);
    const invoice = PurchaseInvoice.parse(received.body);
    expect(invoice).toMatchObject({
      status: 'draft',
      po_id: draft.id,
      po_number: draft.number,
      subtotal: '647.50',
    });
    expect(invoice.lines.find((l) => l.product_id === tv)).toMatchObject({
      quantity: 6,
      unit_cost: '100.00',
      po_line_id: tvLine.id,
    });
    const sameInvoice = await call(
      'post',
      `/api/purchase-orders/${draft.id}/invoice`,
      owner,
      recvBody,
      recvKey,
    );
    expect(PurchaseInvoice.parse(sameInvoice.body).id).toBe(invoice.id);
    expect((await order(draft.id)).lines.find((l) => l.product_id === tv)).toMatchObject({
      received: 0,
      on_draft_invoices: 6,
      remaining: 10,
    });

    const approved = await call('post', `/api/purchase-invoices/${invoice.id}/approve`);
    expect(approved.status, JSON.stringify(approved.body)).toBe(200);
    const partly = await order(draft.id);
    expect(partly.status).toBe('partially_received');
    expect(partly.lines.find((l) => l.product_id === tv)).toMatchObject({
      received: 6,
      remaining: 4,
    });
    expect(partly.invoices).toEqual([
      expect.objectContaining({ id: invoice.id, status: 'approved' }),
    ]);
    expect(await onHand(tv)).toBe(6);
    expect(await onHand(cable)).toBe(5);

    const tooMany = await call(
      'post',
      `/api/purchase-orders/${draft.id}/invoice`,
      owner,
      { lines: [{ po_line_id: tvLine.id, quantity: 5 }] },
      `u05-it-over-${STAMP}`,
    );
    expect(tooMany.status).toBe(409);
    expect(code(tooMany)).toBe('PO_OVER_RECEIPT');
    expect(ErrorResponse.parse(tooMany.body).error.details).toEqual({
      po_line_id: tvLine.id,
      remaining: 4,
    });

    const rest = await call(
      'post',
      `/api/purchase-orders/${draft.id}/invoice`,
      owner,
      {},
      `u05-it-rest-${STAMP}`,
    );
    expect(rest.status, JSON.stringify(rest.body)).toBe(201);
    const restInvoice = PurchaseInvoice.parse(rest.body);
    expect(restInvoice.lines.map((l) => [l.product_id, l.quantity])).toEqual([[tv, 4]]);
    expect((await call('post', `/api/purchase-invoices/${restInvoice.id}/approve`)).status).toBe(
      200,
    );
    expect((await order(draft.id)).status).toBe('received');
    expect(await onHand(tv)).toBe(10);
    const closed = await call(
      'post',
      `/api/purchase-orders/${draft.id}/invoice`,
      owner,
      {},
      `u05-it-closed-${STAMP}`,
    );
    expect(closed.status).toBe(409);
    expect(code(closed)).toBe('PO_CLOSED');

    const list = PurchaseOrderList.parse(
      (await call('get', '/api/purchase-orders?status=received&search=PO')).body,
    );
    expect(list.items).toEqual([
      expect.objectContaining({ id: draft.id, lines_count: 2, ordered: 15, received: 15 }),
    ]);
  });

  it('a warehouse user orders, sends, receives and cancels but cannot approve', async () => {
    const created = await call(
      'post',
      '/api/purchase-orders',
      warehouse,
      {
        supplier_id: supplierId,
        branch_id: branch,
        lines: [{ product_id: cable, quantity: 3, expected_unit_cost: '10.00' }],
      },
      `u05-it-wh-${STAMP}`,
    );
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const id = PurchaseOrder.parse(created.body).id;
    expect((await call('post', `/api/purchase-orders/${id}/send`, warehouse)).status).toBe(200);
    const received = await call(
      'post',
      `/api/purchase-orders/${id}/invoice`,
      warehouse,
      {},
      `u05-it-wh-recv-${STAMP}`,
    );
    expect(received.status, JSON.stringify(received.body)).toBe(201);
    const approve = await call(
      'post',
      `/api/purchase-invoices/${PurchaseInvoice.parse(received.body).id}/approve`,
      warehouse,
    );
    expect(approve.status).toBe(403);
    const noReason = await call('post', `/api/purchase-orders/${id}/cancel`, warehouse, {});
    expect(noReason.status).toBe(400);
    const cancelled = await call('post', `/api/purchase-orders/${id}/cancel`, warehouse, {
      reason: 'Ordered twice',
    });
    expect(cancelled.status, JSON.stringify(cancelled.body)).toBe(200);
    expect(PurchaseOrder.parse(cancelled.body).status).toBe('cancelled');
  });
});
