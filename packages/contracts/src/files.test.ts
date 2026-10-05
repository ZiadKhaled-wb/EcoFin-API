// F14 file contracts: the upload fields, the response shapes and the path and query params.
import { describe, it, expect } from 'vitest';
import {
  FILE_PURPOSES,
  FileIdParams,
  FileListResponse,
  FileResponse,
  FileUrlResponse,
  ListFilesQuery,
  UploadFileRequest,
  errorCodeHttpStatus,
} from './index.js';

const ID = '11111111-1111-4111-8111-111111111111';

describe('UploadFileRequest', () => {
  it('accepts a purpose alone, and a purpose with an entity', () => {
    expect(UploadFileRequest.safeParse({ purpose: 'logo' }).success).toBe(true);
    expect(
      UploadFileRequest.safeParse({ purpose: 'customer_id', entityType: 'customer', entityId: ID })
        .success,
    ).toBe(true);
  });
  it('refuses a purpose outside the file_purpose enum', () => {
    expect(UploadFileRequest.safeParse({ purpose: 'selfie' }).success).toBe(false);
  });
  it('refuses unknown fields (strict)', () => {
    expect(UploadFileRequest.safeParse({ purpose: 'logo', organizationId: ID }).success).toBe(
      false,
    );
  });
  it('refuses a malformed entity id', () => {
    expect(UploadFileRequest.safeParse({ purpose: 'logo', entityId: 'nope' }).success).toBe(false);
  });
  it('lists the same 13 purposes as the database enum', () => {
    expect(FILE_PURPOSES).toHaveLength(13);
  });
});

describe('FileResponse and FileUrlResponse', () => {
  it('carries metadata, never a path or a url', () => {
    const parsed = FileResponse.parse({
      id: ID,
      purpose: 'logo',
      mime: 'image/png',
      sizeBytes: 10,
      originalName: null,
      entityType: null,
      entityId: null,
      createdAt: '2026-10-05T12:00:00.000Z',
    });
    expect(parsed).not.toHaveProperty('path');
    expect(parsed).not.toHaveProperty('url');
  });
  it('a signed link needs a valid url and an expiry time', () => {
    expect(
      FileUrlResponse.safeParse({
        url: 'https://x.example/a?t=1',
        expiresAt: '2026-10-05T12:01:00.000Z',
      }).success,
    ).toBe(true);
    expect(
      FileUrlResponse.safeParse({ url: 'not a url', expiresAt: '2026-10-05T12:01:00.000Z' })
        .success,
    ).toBe(false);
  });
  it('a list is an array of file responses', () => {
    expect(FileListResponse.safeParse({ items: [] }).success).toBe(true);
  });
});

describe('query and params', () => {
  it('a list needs both the entity type and the entity id', () => {
    expect(ListFilesQuery.safeParse({ entityType: 'customer', entityId: ID }).success).toBe(true);
    expect(ListFilesQuery.safeParse({ entityType: 'customer' }).success).toBe(false);
  });
  it('the file id in the path is a uuid', () => {
    expect(FileIdParams.safeParse({ id: ID }).success).toBe(true);
    expect(FileIdParams.safeParse({ id: 'x' }).success).toBe(false);
  });
});

describe('file error codes', () => {
  it('map to the HTTP statuses of F14', () => {
    expect(errorCodeHttpStatus.FILE_TOO_LARGE).toBe(413);
    expect(errorCodeHttpStatus.FILE_TYPE_NOT_ALLOWED).toBe(415);
    expect(errorCodeHttpStatus.FILE_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.FILE_PATH_INVALID).toBe(422);
  });
});
