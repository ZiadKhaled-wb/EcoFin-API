// server/src/services/storage.service.ts
//
// F14 (D36): the ONLY module that calls Supabase Storage with the service role. The bucket is
// private and has no storage policies, so nothing else can touch its objects. Callers are
// files.service.ts (after the session, shop and permission checks) and the orphan report
// script. This module checks nothing about shops or permissions: its callers must have.
//
// Errors never carry storage messages out: a failed call is logged and answered generically.

import { ServerError } from '../utils/errors';
import { logger } from '../utils/logger';
import { supabaseAdmin } from '../utils/supabase';

export const FILE_BUCKET = 'tenant-files';

/** Writes a new object. Never overwrites (upsert off): a path is used once. */
export async function putObject(path: string, body: Buffer, contentType: string): Promise<void> {
  const { error } = await supabaseAdmin.storage
    .from(FILE_BUCKET)
    .upload(path, body, { contentType, upsert: false });
  if (error) {
    logger.error({ err: error, path }, 'storage.putObject failed');
    throw ServerError('Request failed.');
  }
}

/** A download link valid for `ttlSeconds`. */
export async function createSignedUrl(path: string, ttlSeconds: number): Promise<string> {
  const { data, error } = await supabaseAdmin.storage
    .from(FILE_BUCKET)
    .createSignedUrl(path, ttlSeconds);
  if (error || !data) {
    logger.error({ err: error, path }, 'storage.createSignedUrl failed');
    throw ServerError('Request failed.');
  }
  return data.signedUrl;
}

/**
 * Deletes one object. Returns false (and logs) when it could not, so a caller that is already
 * reporting another error can still report that one.
 */
export async function removeObject(path: string): Promise<boolean> {
  const { error } = await supabaseAdmin.storage.from(FILE_BUCKET).remove([path]);
  if (error) {
    logger.error({ err: error, path }, 'storage.removeObject failed');
    return false;
  }
  return true;
}

const PAGE = 1000;

/**
 * Every object under `prefix` (recursive), with its creation time. For the orphan report only.
 * Folders are walked; a listing that fails stops the walk with a server error.
 */
export async function listStoredObjects(prefix = ''): Promise<{ path: string; createdAt: Date }[]> {
  const out: { path: string; createdAt: Date }[] = [];
  const pending = [prefix];
  while (pending.length > 0) {
    const folder = pending.pop() ?? '';
    for (let offset = 0; ; offset += PAGE) {
      const { data, error } = await supabaseAdmin.storage
        .from(FILE_BUCKET)
        .list(folder, { limit: PAGE, offset });
      if (error || !data) {
        logger.error({ err: error, folder }, 'storage.listStoredObjects failed');
        throw ServerError('Request failed.');
      }
      for (const item of data) {
        const path = folder === '' ? item.name : `${folder}/${item.name}`;
        if (item.id === null) {
          pending.push(path);
        } else {
          // No timestamp means no age: treat it as new, so it is never reported as an orphan.
          out.push({ path, createdAt: item.created_at ? new Date(item.created_at) : new Date() });
        }
      }
      if (data.length < PAGE) break;
    }
  }
  return out;
}
