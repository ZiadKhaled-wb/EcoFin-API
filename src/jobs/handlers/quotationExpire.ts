import type { SupabaseClient } from '@supabase/supabase-js';
import type { JobHandler } from '../types';
export function quotationExpire(db: SupabaseClient): JobHandler {
  return async (_job, log) => {
    const { data, error } = await db.rpc('expire_quotations');
    if (error) throw new Error('expire_quotations failed: ' + error.message);
    log.info({ expired: data }, 'quotation.expire: done');
  };
}
