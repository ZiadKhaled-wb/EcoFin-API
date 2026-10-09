// U02 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh retail_pro shop's owner creates a 2-line draft (one serialized product), edits it,
// approves it twice (the second time changes nothing), the stock view shows the quantities and
// the supplier balance is up by the total; a warehouse user creates but can't approve.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  PurchaseInvoice,
  PurchaseApprovalList,
  PurchaseInvoiceList,
  StockList,
  Supplier,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const TODAY = new Date().toISOString().slice(0, 10);

describe.skipIf(!RUN)('U02 purchase invoices against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let warehouse: string;
  let org: string;
  let branch: string;
  let supplierId: string;
  let tv: string;
  let phone: string;
  let ip = 0;
  const call = (
    method: 'get' | 'post' | 'put' | 'patch',
    path: string,
    token = owner,
    body?: object,
    key?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.54.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.54.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `u02.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.54.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'U02 shop',
        tenant_slug: `u02-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.54.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);

    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    branch = main.data!.id as string;
    const whEmail = `u02.warehouse.${STAMP}@ecotech.test`;
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
      sku: 'U02-TV',
      cash_price: '200.00',
    });
    expect(p1.status, JSON.stringify(p1.body)).toBe(201);
    tv = (p1.body as { id: string }).id;
    const p2 = await call('post', '/api/products', owner, {
      name_ar: 'موبايل',
      sku: 'U02-PH',
      cash_price: '1200.00',
      is_serialized: true,
    });
    expect(p2.status, JSON.stringify(p2.body)).toBe(201);
    phone = (p2.body as { id: string }).id;
  }, 60_000);

  it('owner: draft (one serialized line), edit, approve twice, stock and balance', async () => {
    const key = `u02-it-${STAMP}`;
    const body = {
      supplier_id: supplierId,
      branch_id: branch,
      supplier_invoice_no: 'S-100',
      invoice_date: TODAY,
      lines: [
        { product_id: tv, quantity: 10, unit_cost: '130.00' },
        { product_id: phone, quantity: 2, unit_cost: '900.00' },
      ],
    };
    const created = await call('post', '/api/purchase-invoices', owner, body, key);
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const draft = PurchaseInvoice.parse(created.body);
    expect(draft).toMatchObject({ status: 'draft', subtotal: '3100.00', tax_total: '434.00' });
    const again = await call('post', '/api/purchase-invoices', owner, body, key);
    expect(PurchaseInvoice.parse(again.body).id).toBe(draft.id);

    const noSerials = await call('post', `/api/purchase-invoices/${draft.id}/approve`);
    expect(noSerials.status).toBe(422);
    expect(code(noSerials)).toBe('SERIALS_REQUIRED');
    const phoneLine = draft.lines.find((l) => l.product_id === phone)!;
    expect(ErrorResponse.parse(noSerials.body).error.details).toEqual({ line_ids: [phoneLine.id] });

    const edited = await call('put', `/api/purchase-invoices/${draft.id}`, owner, {
      lines: [
        { product_id: tv, quantity: 10, unit_cost: '130.00' },
        { product_id: phone, quantity: 2, unit_cost: '900.00', serials: [' u02-sn-1', 'U02-SN-2'] },
      ],
    });
    expect(edited.status, JSON.stringify(edited.body)).toBe(200);
    expect(
      PurchaseInvoice.parse(edited.body).lines.find((l) => l.product_id === phone)!.serials,
    ).toEqual(['U02-SN-1', 'U02-SN-2']);

    const approved = await call('post', `/api/purchase-invoices/${draft.id}/approve`);
    expect(approved.status, JSON.stringify(approved.body)).toBe(200);
    const inv = PurchaseInvoice.parse(approved.body);
    expect(inv).toMatchObject({ status: 'approved', total: '3534.00', outstanding: '3534.00' });
    expect(inv.lines.find((l) => l.product_id === phone)!.unit_ids).toHaveLength(2);
    const twice = await call('post', `/api/purchase-invoices/${draft.id}/approve`);
    expect(PurchaseInvoice.parse(twice.body)).toEqual(inv);

    const stock = StockList.parse((await call('get', `/api/stock?branch_id=${branch}`)).body);
    const onHand = (id: string) => stock.items.find((r) => r.product_id === id)!.on_hand;
    expect(onHand(tv)).toBe(10);
    expect(onHand(phone)).toBe(2);
    const sup = Supplier.parse((await call('get', `/api/suppliers/${supplierId}`)).body);
    expect(sup.balance).toBe('3534.00');

    const list = PurchaseInvoiceList.parse(
      (await call('get', '/api/purchase-invoices?status=approved&search=S-1')).body,
    );
    expect(list.items.map((i) => i.id)).toEqual([draft.id]);
  });

  it('a warehouse user creates and edits but gets 403 on approve and reject', async () => {
    const created = await call(
      'post',
      '/api/purchase-invoices',
      warehouse,
      {
        supplier_id: supplierId,
        branch_id: branch,
        invoice_date: TODAY,
        lines: [{ product_id: tv, quantity: 1, unit_cost: '120.00' }],
      },
      `u02-it-wh-${STAMP}`,
    );
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const id = PurchaseInvoice.parse(created.body).id;
    const edit = await call('put', `/api/purchase-invoices/${id}`, warehouse, {
      supplier_invoice_no: 'W-1',
    });
    expect(edit.status).toBe(200);
    const approve = await call('post', `/api/purchase-invoices/${id}/approve`, warehouse);
    expect(approve.status).toBe(403);
    expect(code(approve)).toBe('PERMISSION_DENIED');
    const reject = await call('post', `/api/purchase-invoices/${id}/reject`, warehouse, {
      reason: 'Not allowed',
    });
    expect(reject.status).toBe(403);
  });

  it('refusals: missing key, a duplicate supplier invoice no, a rejected invoice is final', async () => {
    const body = {
      supplier_id: supplierId,
      branch_id: branch,
      supplier_invoice_no: 'S-200',
      invoice_date: TODAY,
      lines: [{ product_id: tv, quantity: 1, unit_cost: '1.00' }],
    };
    expect((await call('post', '/api/purchase-invoices', owner, body)).status).toBe(400);
    const first = await call('post', '/api/purchase-invoices', owner, body, `u02-it-a-${STAMP}`);
    expect(first.status).toBe(201);
    const dup = await call('post', '/api/purchase-invoices', owner, body, `u02-it-b-${STAMP}`);
    expect(dup.status).toBe(409);
    expect(code(dup)).toBe('SUPPLIER_INVOICE_NO_TAKEN');
    const id = PurchaseInvoice.parse(first.body).id;
    const rejected = await call('post', `/api/purchase-invoices/${id}/reject`, owner, {
      reason: 'Wrong prices',
    });
    expect(PurchaseInvoice.parse(rejected.body).status).toBe('rejected');
    const edit = await call('put', `/api/purchase-invoices/${id}`, owner, {
      supplier_invoice_no: 'X',
    });
    expect(edit.status).toBe(409);
    expect(code(edit)).toBe('PURCHASE_INVOICE_NOT_EDITABLE');
  });

  it('U06: above the threshold the manager approve waits; the owner approves it with a note', async () => {
    // A branch manager of the main branch (create + approve).
    const mgrEmail = `u06.manager.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email: mgrEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email: mgrEmail,
        full_name: 'Manager',
        role: 'BRANCH_MANAGER',
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branch });
    const manager = await login(mgrEmail);

    const set = await call('patch', '/api/settings', owner, {
      purchase_approval_threshold: '1000.00',
    });
    expect(set.status, JSON.stringify(set.body)).toBe(200);
    try {
      const onHand = async () =>
        StockList.parse((await call('get', `/api/stock?branch_id=${branch}`)).body).items.find(
          (r) => r.product_id === tv,
        )!.on_hand;
      const before = await onHand();
      const created = await call(
        'post',
        '/api/purchase-invoices',
        manager,
        {
          supplier_id: supplierId,
          branch_id: branch,
          invoice_date: TODAY,
          lines: [{ product_id: tv, quantity: 10, unit_cost: '130.00' }],
        },
        `u06-it-${STAMP}`,
      );
      expect(created.status, JSON.stringify(created.body)).toBe(201);
      const id = PurchaseInvoice.parse(created.body).id;

      const waiting = await call('post', `/api/purchase-invoices/${id}/approve`, manager, {});
      expect(waiting.status, JSON.stringify(waiting.body)).toBe(200);
      expect(PurchaseInvoice.parse(waiting.body)).toMatchObject({
        status: 'pending_approval',
        approval: { status: 'pending', amount: '1482.00', threshold: '1000.00' },
      });
      expect(await onHand()).toBe(before);
      const again = await call('post', `/api/purchase-invoices/${id}/approve`, manager, {});
      expect(again.status).toBe(403);
      expect(code(again)).toBe('APPROVAL_OWNER_ONLY');

      const list = PurchaseApprovalList.parse(
        (await call('get', '/api/purchase-approvals', manager)).body,
      );
      expect(list.items.map((i) => i.invoice.id)).toContain(id);

      const noNote = await call('post', `/api/purchase-invoices/${id}/approve`, owner, {});
      expect(noNote.status).toBe(400);
      expect(code(noNote)).toBe('APPROVAL_NOTE_REQUIRED');
      const approved = await call('post', `/api/purchase-invoices/${id}/approve`, owner, {
        note: 'Checked with the supplier',
      });
      expect(approved.status, JSON.stringify(approved.body)).toBe(200);
      expect(PurchaseInvoice.parse(approved.body)).toMatchObject({
        status: 'approved',
        approval: { status: 'approved', note: 'Checked with the supplier' },
      });
      await call('post', `/api/purchase-invoices/${id}/approve`, owner, {});
      expect(await onHand()).toBe(before + 10);
    } finally {
      await call('patch', '/api/settings', owner, { purchase_approval_threshold: null });
    }
  });
});
