import { z } from 'zod';
import { IsoTimestamp, Uuid } from './common.js';

// F14 · file storage (EC-33). Objects live in the private bucket `tenant-files`; their metadata
// rows are in files. The purpose decides who may upload it and who may read it (server map).
export const FILE_PURPOSES = [
  'logo',
  'product_image',
  'customer_id',
  'survey_photo',
  'signature',
  'contract_pdf',
  'promissory_note',
  'delivery_proof',
  'expense_receipt',
  'legal_document',
  'import',
  'export',
  'other',
] as const;
export const FilePurpose = z.enum(FILE_PURPOSES);
export type FilePurpose = z.infer<typeof FilePurpose>;

// POST /files (multipart): the text fields. The file itself is the `file` part.
export const UploadFileRequest = z
  .object({
    purpose: FilePurpose,
    entityType: z.string().trim().min(1).max(40).optional(),
    entityId: Uuid.optional(),
  })
  .strict();
export type UploadFileRequest = z.infer<typeof UploadFileRequest>;

// Metadata only. Never a URL: those come from GET /files/:id/url.
export const FileResponse = z.object({
  id: Uuid,
  purpose: FilePurpose,
  mime: z.string(),
  sizeBytes: z.number().int().min(0),
  originalName: z.string().nullable(),
  entityType: z.string().nullable(),
  entityId: Uuid.nullable(),
  createdAt: IsoTimestamp,
});
export type FileResponse = z.infer<typeof FileResponse>;

// GET /files/:id/url: a short-lived signed link (FILE_URL_TTL_SECONDS on the server).
export const FileUrlResponse = z.object({
  url: z.string().url(),
  expiresAt: IsoTimestamp,
});
export type FileUrlResponse = z.infer<typeof FileUrlResponse>;

// GET /files?entityType=&entityId=: the files of one record, metadata only.
export const ListFilesQuery = z
  .object({
    entityType: z.string().trim().min(1).max(40),
    entityId: Uuid,
  })
  .strict();
export type ListFilesQuery = z.infer<typeof ListFilesQuery>;

export const FileListResponse = z.object({ items: z.array(FileResponse) });
export type FileListResponse = z.infer<typeof FileListResponse>;

export const FileIdParams = z.object({ id: Uuid }).strict();
export type FileIdParams = z.infer<typeof FileIdParams>;

export const FileUpload = { body: UploadFileRequest, response: FileResponse };
export const FileUrl = { params: FileIdParams, response: FileUrlResponse };
export const FileList = { query: ListFilesQuery, response: FileListResponse };
