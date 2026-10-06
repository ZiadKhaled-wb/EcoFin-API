import { describe, expect, it } from 'vitest';
import {
  AdminCreateShopBody,
  AdminShopsQuery,
  AdminShopStatusBody,
  InviteAcceptBody,
} from './shops.js';
const body = {
  name: 'Shop',
  tenant_slug: 'SHOP-ONE',
  plan_key: 'starter',
  owner: { full_name: 'Owner', email: 'owner@example.com' },
};
describe('P01 contracts', () => {
  it('normalizes the slug and refuses reserved or malformed names', () => {
    expect(AdminCreateShopBody.parse(body).tenant_slug).toBe('shop-one');
    for (const tenant_slug of ['admin', 'api', 'app', 'www', 'support', '-bad', 'bad-'])
      expect(AdminCreateShopBody.safeParse({ ...body, tenant_slug }).success).toBe(false);
  });
  it('validates required contact data and unknown fields', () => {
    expect(
      AdminCreateShopBody.safeParse({ ...body, owner: { full_name: '', email: 'invalid' } })
        .success,
    ).toBe(false);
    expect(AdminCreateShopBody.safeParse({ ...body, token: 'raw' }).success).toBe(false);
  });
  it('caps pagination and requires a suspension reason', () => {
    expect(AdminShopsQuery.safeParse({ page_size: 101 }).success).toBe(false);
    expect(AdminShopStatusBody.safeParse({ status: 'suspended', reason: ' ' }).success).toBe(false);
    expect(AdminShopStatusBody.safeParse({ status: 'active' }).success).toBe(true);
  });
  it('allows a legacy account password while the service enforces rules for new accounts', () => {
    expect(InviteAcceptBody.safeParse({ token: 'token', password: 'old' }).success).toBe(true);
  });
});
