import { randomBytes, scrypt as scryptCallback, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';

const scrypt = promisify(scryptCallback);
const KEY_LENGTH = 64;
const PARAMETERS = Object.freeze({ N: 32768, r: 8, p: 1, maxmem: 64 * 1024 * 1024 });

export async function hashPassword(password) {
  const salt = randomBytes(16);
  const derivedKey = await scrypt(password, salt, KEY_LENGTH, PARAMETERS);

  return [
    'scrypt',
    PARAMETERS.N,
    PARAMETERS.r,
    PARAMETERS.p,
    salt.toString('base64url'),
    Buffer.from(derivedKey).toString('base64url'),
  ].join('$');
}

export async function verifyPassword(password, encodedHash) {
  try {
    const [algorithm, rawN, rawR, rawP, rawSalt, rawExpected] = encodedHash.split('$');
    if (algorithm !== 'scrypt') return false;

    const expected = Buffer.from(rawExpected, 'base64url');
    const salt = Buffer.from(rawSalt, 'base64url');
    const parameters = {
      N: Number(rawN),
      r: Number(rawR),
      p: Number(rawP),
      maxmem: 64 * 1024 * 1024,
    };

    if (expected.length !== KEY_LENGTH || salt.length < 16) return false;
    if (parameters.N !== PARAMETERS.N || parameters.r !== PARAMETERS.r || parameters.p !== PARAMETERS.p) {
      return false;
    }

    const actual = Buffer.from(await scrypt(password, salt, expected.length, parameters));
    return timingSafeEqual(actual, expected);
  } catch {
    return false;
  }
}
