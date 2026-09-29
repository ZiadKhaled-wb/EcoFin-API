// server/src/utils/password.ts
//
// Password and token generation helpers.
//
// Password policy: NIST SP 800-63B style — length is the only hard rule.
// No composition requirements, no character-class blocklists, no forced
// rotation. A small common-password blocklist catches the worst cases.

import crypto from 'crypto';

const LETTERS = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
const DIGITS = '23456789';
const SYMBOLS = '!@#$%^&*';

function randomChar(pool: string): string {
    const idx = crypto.randomInt(0, pool.length);
    const ch = pool[idx];
    // randomInt is [0, pool.length), so ch is always defined. The explicit
    // check satisfies noUncheckedIndexedAccess without a non-null assertion.
    if (ch === undefined) {
        throw new Error('randomChar: index out of bounds — this is a bug.');
    }
    return ch;
}

/**
 * Generates a temporary password for accounts provisioned on behalf of a
 * user (new admins, license owners). Always satisfies the app-level
 * password policy (>=8 chars, not in the common-password blocklist).
 */
export function generateTempPassword(length = 12): string {
    if (length < 8) throw new Error('Password length must be at least 8 characters.');
    const required = [randomChar(LETTERS), randomChar(DIGITS), randomChar(SYMBOLS)];
    const pool = LETTERS + DIGITS + SYMBOLS;
    const remaining = length - required.length;
    const rest = Array.from({ length: remaining }, () => randomChar(pool));
    const all = [...required, ...rest];
    // Fisher-Yates shuffle so the required chars aren't positionally biased.
    for (let i = all.length - 1; i > 0; i--) {
        const j = crypto.randomInt(0, i + 1);
        // Both indices are guaranteed in-bounds by the loop condition and by
        // randomInt's exclusive upper bound. The non-null assertions document
        // that; runtime checks here would be unreachable.
        const tmp = all[i]!;
        all[i] = all[j]!;
        all[j] = tmp;
    }
    return all.join('');
}

// Crockford-style base32 — no padding, no ambiguous characters.
const BASE32_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/**
 * Generates a high-entropy token suitable for idempotency keys or one-time
 * secrets (invitation links, password-reset fallbacks if we ever move off
 * Supabase's magic link). 32 bytes -> ~52 base32 chars.
 */
export function generateSecureToken(byteLength = 32): string {
    const bytes = crypto.randomBytes(byteLength);
    let out = '';
    let bits = 0;
    let value = 0;
    for (const byte of bytes) {
        value = (value << 8) | byte;
        bits += 8;
        while (bits >= 5) {
            out += BASE32_ALPHABET[(value >>> (bits - 5)) & 31];
            bits -= 5;
        }
    }
    if (bits > 0) out += BASE32_ALPHABET[(value << (5 - bits)) & 31];
    return out;
}

/**
 * SHA-256 hash of a high-entropy token. Suitable for storing one-time
 * tokens at rest (never store the raw value). NOT suitable for passwords —
 * those go through Supabase Auth's bcrypt.
 */
export function hashToken(token: string): string {
    return crypto.createHash('sha256').update(token).digest('hex');
}

/** Constant-time comparison of a raw token against a stored hash. */
export function verifyTokenHash(token: string, hash: string): boolean {
    const computed = hashToken(token);
    if (computed.length !== hash.length) return false;
    return crypto.timingSafeEqual(
        Buffer.from(computed, 'hex'),
        Buffer.from(hash, 'hex'),
    );
}