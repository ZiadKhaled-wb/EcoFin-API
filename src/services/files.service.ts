// server/src/services/files.service.ts
//
// F14 file storage (EC-33). Upload, signed download link and list of one record's files.
//
// Order of every call: session and shop (loadRequestContext) → permission for the purpose → input
// checks (size, magic-byte type, entity shop) → storage (service role, storage.service only) →
// metadata through public.register_file with the caller's own JWT. If the metadata write fails,
// the object is removed so no orphan is left. Rows are never deleted (the baseline blocks it).

import { randomUUID } from 'node:crypto';
import type {
  FilePurpose,
  FileListResponse,
  FileResponse,
  FileUrlResponse,
  ListFilesQuery,
  PermissionKey,
  UploadFileRequest,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { AppError, BadRequest, ServerError, mapDbError, safeMessage } from '../utils/errors';
import { logger } from '../utils/logger';
import { assertOwnPath, assertSameOrg, tenantFilePath, type SameOrgTable } from '../utils/tenant';
import { getMyPermissions } from './permissions.service';
import {
  ENTITY_TABLES,
  ENTITY_TYPES,
  READ_PERMISSION,
  UPLOAD_PERMISSION,
  assertAllowedType,
  assertUploadSize,
  detectFileType,
  extensionOf,
  mimeOf,
  sanitizeOriginalName,
  sha256Hex,
  type EntityType,
} from './files.rules';
import * as storage from './storage.service';

/** Settings from the environment (FILE_MAX_BYTES, FILE_URL_TTL_SECONDS), passed in by the controller. */
export interface FileSettings {
  maxBytes: number;
  urlTtlSeconds: number;
}

/** The file part of the multipart upload, as multer hands it over. */
export interface UploadedFile {
  buffer: Buffer;
  originalname: string;
}

/** The columns the API returns for a file. Never `path`, never a URL. */
const FILE_COLUMNS =
  'id, purpose, mime, size_bytes, original_name, entity_type, entity_id, created_at';

interface FileRow {
  id: string;
  purpose: FilePurpose;
  mime: string;
  size_bytes: number;
  original_name: string | null;
  entity_type: string | null;
  entity_id: string | null;
  created_at: string;
}

function fail(err: unknown, what: string): never {
  const mapped = mapDbError(err);
  if (mapped) throw mapped;
  logger.error({ err }, `${what} failed`);
  throw ServerError('Request failed.');
}

/** Refuses with 403 PERMISSION_DENIED unless the caller holds `key`. `null` = any employee. */
async function assertPermission(ctx: RequestContext, key: PermissionKey | null): Promise<void> {
  if (key === null) return;
  const { keys } = await getMyPermissions(ctx);
  if (!keys.includes(key)) {
    throw new AppError(safeMessage('PERMISSION_DENIED'), 'PERMISSION_DENIED', undefined, {
      permission: key,
    });
  }
}

/** A `entityType` the server knows, as its table for the shop-ownership check. */
function entityTable(entityType: string): SameOrgTable {
  if (!ENTITY_TYPES.includes(entityType as EntityType)) {
    throw BadRequest('Unknown entity type.', 'VALIDATION_FAILED');
  }
  return ENTITY_TABLES[entityType as EntityType];
}

/** The entity a file points at. An entity id must belong to the caller's shop (404 otherwise). */
async function resolveEntity(
  ctx: RequestContext,
  entityType: string | undefined,
  entityId: string | undefined,
): Promise<{ entityType: string | null; entityId: string | null }> {
  if (entityType === undefined) {
    if (entityId !== undefined)
      throw BadRequest('An entity type is needed with an entity id.', 'VALIDATION_FAILED');
    return { entityType: null, entityId: null };
  }
  const table = entityTable(entityType);
  if (entityId !== undefined) await assertSameOrg(ctx, table, [entityId]);
  return { entityType, entityId: entityId ?? null };
}

function toFileResponse(row: FileRow): FileResponse {
  return {
    id: row.id,
    purpose: row.purpose,
    mime: row.mime,
    sizeBytes: row.size_bytes,
    originalName: row.original_name,
    entityType: row.entity_type,
    entityId: row.entity_id,
    createdAt: new Date(row.created_at).toISOString(),
  };
}

const pad2 = (n: number): string => String(n).padStart(2, '0');

/** POST /api/files: validate, store the object, record its metadata. Returns the new file. */
export async function uploadFile(
  ctx: RequestContext,
  file: UploadedFile | undefined,
  body: UploadFileRequest,
  settings: FileSettings,
): Promise<FileResponse> {
  if (file === undefined) throw BadRequest('A file is required.', 'VALIDATION_FAILED');

  // Before anything is stored: the permission for this purpose.
  await assertPermission(
    ctx,
    body.purpose === 'other' && body.entityType === 'warranty_claim'
      ? 'warranty.manage'
      : UPLOAD_PERMISSION[body.purpose],
  );

  assertUploadSize(file.buffer.length, settings.maxBytes);
  const originalName = sanitizeOriginalName(file.originalname);
  const type = detectFileType(file.buffer, originalName);
  if (type === null)
    throw new AppError(safeMessage('FILE_TYPE_NOT_ALLOWED'), 'FILE_TYPE_NOT_ALLOWED');
  assertAllowedType(type, body.purpose);

  const entity = await resolveEntity(ctx, body.entityType, body.entityId);

  const id = randomUUID();
  const now = new Date();
  // <orgId>/<purpose>/<yyyy>/<mm>/<uuid>.<ext>: the extension comes from the detected type.
  const path = tenantFilePath(
    ctx,
    body.purpose,
    String(now.getUTCFullYear()),
    pad2(now.getUTCMonth() + 1),
    `${id}.${extensionOf(type)}`,
  );
  const mime = mimeOf(type);

  await storage.putObject(path, file.buffer, mime);

  const { error } = await ctx.db.rpc('register_file', {
    p_id: id,
    p_path: path,
    p_original_name: originalName,
    p_mime: mime,
    p_size_bytes: file.buffer.length,
    p_sha256: sha256Hex(file.buffer),
    p_purpose: body.purpose,
    p_entity_type: entity.entityType,
    p_entity_id: entity.entityId,
  });
  if (error) {
    // No orphan: the object goes when its metadata could not be written.
    await storage.removeObject(path);
    fail(error, 'register_file');
  }

  const { data, error: readError } = await ctx.db
    .from('files')
    .select(FILE_COLUMNS)
    .eq('id', id)
    .maybeSingle();
  if (readError) fail(readError, 'files read after upload');
  if (data === null) {
    logger.error({ id }, 'uploadFile: the new file row is not visible to its uploader');
    throw ServerError('Request failed.');
  }
  return toFileResponse(data);
}

/** GET /api/files/:id/url: a short-lived signed link, if the caller may read this purpose. */
export async function getFileUrl(
  ctx: RequestContext,
  fileId: string,
  settings: FileSettings,
): Promise<FileUrlResponse> {
  // RLS limits the row to the caller's shop: another shop's file reads as "not found".
  const { data, error } = await ctx.db
    .from('files')
    .select('id, purpose, path, entity_type, entity_id, deleted_at')
    .eq('id', fileId)
    .maybeSingle();
  if (error) fail(error, 'files read for url');
  // M03: the zip of a full export leaves storage after 7 days; its row stays with deleted_at.
  if (data === null || (data.deleted_at ?? null) !== null) {
    throw new AppError(safeMessage('FILE_NOT_FOUND'), 'FILE_NOT_FOUND');
  }

  await assertPermission(
    ctx,
    data.purpose === 'other' && data.entity_type === 'warranty_claim'
      ? 'warranty.manage'
      : READ_PERMISSION[data.purpose],
  );
  if (data.entity_type === 'warranty_claim' && data.entity_id) {
    const claim = await ctx.db.rpc('get_warranty_claim', { p_claim_id: data.entity_id });
    if (claim.error) fail(claim.error, 'claim photo access');
  }

  const path = assertOwnPath(ctx, data.path);
  if (data.purpose === 'export') {
    // M03: F14 does not audit reads; the download of an export zip is recorded (a no-op for other files).
    const audited = await ctx.db.rpc('record_export_download', { p_file_id: fileId });
    if (audited.error) fail(audited.error, 'record_export_download');
  }
  const url = await storage.createSignedUrl(path, settings.urlTtlSeconds);
  return {
    url,
    expiresAt: new Date(Date.now() + settings.urlTtlSeconds * 1000).toISOString(),
  };
}

/** GET /api/files?entityType=&entityId=: the files of one record that the caller may read. */
export async function listFiles(
  ctx: RequestContext,
  query: ListFilesQuery,
): Promise<FileListResponse> {
  if (query.entityType === 'warranty_claim') {
    const claim = await ctx.db.rpc('get_warranty_claim', { p_claim_id: query.entityId });
    if (claim.error) fail(claim.error, 'claim photo list');
  }
  const table = entityTable(query.entityType);
  await assertSameOrg(ctx, table, [query.entityId]);

  const { data, error } = await ctx.db
    .from('files')
    .select(FILE_COLUMNS)
    .eq('organization_id', ctx.orgId)
    .eq('entity_type', query.entityType)
    .eq('entity_id', query.entityId)
    .order('created_at', { ascending: true });
  if (error) fail(error, 'files list');

  // Metadata only, and only for the purposes the caller may read (same rule as the link).
  const { keys } = await getMyPermissions(ctx);
  const items = (data ?? [])
    .filter((row) => {
      const key =
        row.purpose === 'other' && row.entity_type === 'warranty_claim'
          ? 'warranty.manage'
          : READ_PERMISSION[row.purpose];
      return key === null || keys.includes(key);
    })
    .map(toFileResponse);
  return { items };
}
