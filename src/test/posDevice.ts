// O03 fixture for the integration tests: a shift needs the paired POS device of the request.
// pairTestDevice gives a branch a paired device straight in the database (service role), the
// same state the pairing screens leave behind: a device row holding the SHA-256 of a token.
// The test then sends the token in `x-device-token`, as a paired computer does.
//
// The device is found by name, so a seeded shop keeps one test device per name however often
// the tests run (devices are never deleted and count against the plan).
import { createHash, randomBytes } from 'node:crypto';
import type { SupabaseClient } from '@supabase/supabase-js';

export const DEVICE_TOKEN_HEADER = 'x-device-token';

export interface TestDevice {
  id: string;
  /** Send it as `x-device-token`. */
  token: string;
}

export async function pairTestDevice(
  service: SupabaseClient,
  organizationId: string,
  branchId: string,
  name = 'Test POS',
): Promise<TestDevice> {
  const token = randomBytes(32).toString('base64url');
  const pairing = {
    token_hash: createHash('sha256').update(token, 'utf8').digest('hex'),
    paired_at: new Date().toISOString(),
    is_active: true,
  };
  const found = await service
    .from('devices')
    .select('id')
    .eq('organization_id', organizationId)
    .eq('branch_id', branchId)
    .eq('name', name)
    .is('archived_at', null)
    .maybeSingle();
  if (found.error) throw new Error(found.error.message);
  if (found.data) {
    const id = (found.data as { id: string }).id;
    const updated = await service.from('devices').update(pairing).eq('id', id);
    if (updated.error) throw new Error(updated.error.message);
    return { id, token };
  }
  const made = await service
    .from('devices')
    .insert({ organization_id: organizationId, branch_id: branchId, name, ...pairing })
    .select('id')
    .single();
  if (made.error) throw new Error(made.error.message);
  return { id: (made.data as { id: string }).id, token };
}
