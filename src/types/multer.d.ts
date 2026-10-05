// Types for the parts of `multer` the API uses (F14). The project adds no @types dependency:
// `multer` is the only new package F14 allows. Extend this file if more of multer is needed.

declare module 'multer' {
  import type { RequestHandler } from 'express';

  /** One uploaded file, held in memory (memoryStorage). */
  export interface MulterFile {
    fieldname: string;
    originalname: string;
    mimetype: string;
    size: number;
    buffer: Buffer;
  }

  export interface MulterOptions {
    storage: unknown;
    limits?: { fileSize?: number; files?: number; fields?: number };
  }

  export interface Multer {
    single(fieldname: string): RequestHandler;
  }

  function multer(options: MulterOptions): Multer;

  namespace multer {
    function memoryStorage(): unknown;

    class MulterError extends Error {
      code: string;
      field?: string;
    }
  }

  export default multer;
}
