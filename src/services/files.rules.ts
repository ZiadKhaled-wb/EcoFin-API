// server/src/services/files.rules.ts
//
// F14 pure rules, no I/O: who may upload or read which purpose, what a file really is (magic
// bytes, never the client's mime or name), how big it may be, how its name and hash are kept.
// Unit tested in files.rules.test.ts. files.service.ts applies them in the order the task gives.

import { createHash } from 'node:crypto';
import type { FilePurpose, PermissionKey } from '@ziadkhaled-wb/contracts';
import { AppError, BadRequest, safeMessage } from '../utils/errors';
import type { SameOrgTable } from '../utils/tenant';

/** A type the server recognised from the file's own bytes. */
export type DetectedType = 'jpeg' | 'png' | 'webp' | 'pdf' | 'xlsx' | 'csv';

/** Permission to upload one purpose (the same key the database function checks). */
export const UPLOAD_PERMISSION: Record<FilePurpose, PermissionKey> = {
  logo: 'org.settings_manage',
  product_image: 'catalog.manage',
  customer_id: 'customer.create',
  survey_photo: 'survey.submit',
  signature: 'installment.create',
  contract_pdf: 'installment.create',
  promissory_note: 'installment.create',
  delivery_proof: 'delivery.manage',
  expense_receipt: 'expense.create',
  legal_document: 'legal.manage',
  import: 'import.data',
  export: 'export.data',
  other: 'org.settings_manage',
};

/** Permission to get a signed link or list one purpose. `null` = any employee of the shop. */
export const READ_PERMISSION: Record<FilePurpose, PermissionKey | null> = {
  logo: null,
  product_image: null,
  customer_id: 'customer.view_pii',
  survey_photo: 'customer.view_pii',
  signature: 'customer.view_pii',
  contract_pdf: null,
  promissory_note: null,
  delivery_proof: null,
  expense_receipt: 'cash.view',
  legal_document: 'legal.view',
  import: 'import.data',
  export: 'export.data',
  other: 'org.settings_manage',
};

const IMAGES: readonly DetectedType[] = ['jpeg', 'png', 'webp'];
const DOCUMENTS: readonly DetectedType[] = [...IMAGES, 'pdf'];
const DATA_FILES: readonly DetectedType[] = ['csv', 'xlsx', 'pdf'];

/** What each purpose accepts, after the bytes were recognised. */
export const ALLOWED_TYPES: Record<FilePurpose, readonly DetectedType[]> = {
  logo: IMAGES,
  product_image: IMAGES,
  customer_id: IMAGES,
  survey_photo: IMAGES,
  signature: IMAGES,
  delivery_proof: IMAGES,
  expense_receipt: DOCUMENTS,
  legal_document: DOCUMENTS,
  contract_pdf: DOCUMENTS,
  promissory_note: DOCUMENTS,
  other: DOCUMENTS,
  import: DATA_FILES,
  export: DATA_FILES,
};

/**
 * `entityType` values a file may point at, and the table its `entityId` must belong to in the
 * caller's shop (F05 assertSameOrg). Any other entity type is refused.
 */
export const ENTITY_TABLES = {
  customer: 'customers',
  product: 'products',
  expense: 'expenses',
  contract: 'contracts',
  legal_case: 'legal_cases',
  delivery: 'deliveries',
  warranty_claim: 'warranty_claims',
} as const satisfies Record<string, SameOrgTable>;

export type EntityType = keyof typeof ENTITY_TABLES;

export const ENTITY_TYPES = Object.keys(ENTITY_TABLES) as EntityType[];

/** Recognises the file from its first bytes. CSV has no signature: it is text with a .csv name. */
export function detectFileType(bytes: Buffer, originalName: string | null): DetectedType | null {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff)
    return 'jpeg';
  if (bytes.length >= 4 && bytes.subarray(0, 4).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47])))
    return 'png';
  if (
    bytes.length >= 12 &&
    bytes.subarray(0, 4).toString('latin1') === 'RIFF' &&
    bytes.subarray(8, 12).toString('latin1') === 'WEBP'
  )
    return 'webp';
  if (bytes.length >= 4 && bytes.subarray(0, 4).toString('latin1') === '%PDF') return 'pdf';
  // A zip container: .xlsx is one. Other zips are refused by the purpose allow-list.
  if (bytes.length >= 4 && bytes.subarray(0, 4).equals(Buffer.from([0x50, 0x4b, 0x03, 0x04])))
    return 'xlsx';
  if (originalName !== null && /\.csv$/i.test(originalName) && isUtf8Text(bytes)) return 'csv';
  return null;
}

function isUtf8Text(bytes: Buffer): boolean {
  if (bytes.includes(0)) return false;
  try {
    new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    return true;
  } catch {
    return false;
  }
}

const MIME: Record<DetectedType, string> = {
  jpeg: 'image/jpeg',
  png: 'image/png',
  webp: 'image/webp',
  pdf: 'application/pdf',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  csv: 'text/csv',
};

const EXTENSION: Record<DetectedType, string> = {
  jpeg: 'jpg',
  png: 'png',
  webp: 'webp',
  pdf: 'pdf',
  xlsx: 'xlsx',
  csv: 'csv',
};

export const mimeOf = (type: DetectedType): string => MIME[type];
export const extensionOf = (type: DetectedType): string => EXTENSION[type];

/** Refuses an empty file (validation) or one over `maxBytes` (413 FILE_TOO_LARGE). */
export function assertUploadSize(size: number, maxBytes: number): void {
  if (size === 0) throw BadRequest('The file is empty.', 'VALIDATION_FAILED');
  if (size > maxBytes) throw new AppError(safeMessage('FILE_TOO_LARGE'), 'FILE_TOO_LARGE');
}

/** Refuses a type the purpose doesn't allow (415 FILE_TYPE_NOT_ALLOWED). */
export function assertAllowedType(type: DetectedType, purpose: FilePurpose): void {
  if (!ALLOWED_TYPES[purpose].includes(type)) {
    throw new AppError(safeMessage('FILE_TYPE_NOT_ALLOWED'), 'FILE_TYPE_NOT_ALLOWED');
  }
}

/**
 * The client's file name as metadata only: no path parts, no control characters, at most 200
 * characters. Returns null when nothing is left.
 */
export function sanitizeOriginalName(raw: string | undefined): string | null {
  if (raw === undefined) return null;
  const base = raw.split(/[\\/]/).pop() ?? '';
  const clean = Array.from(base.replace(/[\u0000-\u001f\u007f]/g, '').trim())
    .slice(0, 200)
    .join('');
  return clean === '' ? null : clean;
}

export function sha256Hex(bytes: Buffer): string {
  return createHash('sha256').update(bytes).digest('hex');
}

const ORPHAN_AFTER_MS = 24 * 60 * 60 * 1000;

/**
 * Stored objects at least 24 hours old that no files row points at. Report only: nothing is
 * deleted by this function.
 */
export function findOrphans(
  objects: readonly { path: string; createdAt: Date }[],
  knownPaths: ReadonlySet<string>,
  now: Date,
): string[] {
  return objects
    .filter(
      (o) => now.getTime() - o.createdAt.getTime() >= ORPHAN_AFTER_MS && !knownPaths.has(o.path),
    )
    .map((o) => o.path);
}
