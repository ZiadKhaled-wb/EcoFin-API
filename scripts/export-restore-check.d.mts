// Types of the pure helpers exported by export-restore-check.mjs (used by the unit tests).
export function readZip(buffer: Buffer): Record<string, Buffer>;
export function parseCsv(text: string): string[][];
export function unguardCell(value: string): string;
