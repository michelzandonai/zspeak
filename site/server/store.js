import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';

function emptyDatabase() {
  return { version: 1, users: [], sessions: [] };
}

export function normalizeEmail(value) {
  return value.trim().toLocaleLowerCase('en-US');
}

export function hashSessionToken(token) {
  return createHash('sha256').update(token).digest('base64url');
}

export class JsonStore {
  #filePath;
  #data = emptyDatabase();
  #writeQueue = Promise.resolve();

  constructor(filePath) {
    this.#filePath = filePath;
  }

  async init() {
    await mkdir(path.dirname(this.#filePath), { recursive: true, mode: 0o700 });

    try {
      const raw = await readFile(this.#filePath, 'utf8');
      const parsed = JSON.parse(raw);
      if (parsed?.version !== 1 || !Array.isArray(parsed.users) || !Array.isArray(parsed.sessions)) {
        throw new Error('Formato do banco local inválido');
      }
      this.#data = parsed;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      await this.#persist();
    }

    return this;
  }

  async createUser({ email, name, passwordHash, entitlement = 'zspeak-desktop' }) {
    return this.#mutate((data) => {
      const normalizedEmail = normalizeEmail(email);
      if (data.users.some((user) => user.email === normalizedEmail)) return null;

      const now = new Date().toISOString();
      const user = {
        id: randomUUID(),
        email: normalizedEmail,
        name,
        passwordHash,
        entitlements: entitlement ? [entitlement] : [],
        createdAt: now,
      };
      data.users.push(user);
      return structuredClone(user);
    });
  }

  findUserByEmail(email) {
    const normalizedEmail = normalizeEmail(email);
    const user = this.#data.users.find((candidate) => candidate.email === normalizedEmail);
    return user ? structuredClone(user) : null;
  }

  findUserById(id) {
    const user = this.#data.users.find((candidate) => candidate.id === id);
    return user ? structuredClone(user) : null;
  }

  async createSession(userId, ttlMs) {
    return this.#mutate((data) => {
      const token = randomBytes(32).toString('base64url');
      const session = {
        tokenHash: hashSessionToken(token),
        userId,
        expiresAt: new Date(Date.now() + ttlMs).toISOString(),
        createdAt: new Date().toISOString(),
      };
      data.sessions = data.sessions.filter((candidate) => Date.parse(candidate.expiresAt) > Date.now());
      data.sessions.push(session);
      return { token, expiresAt: session.expiresAt };
    });
  }

  findSession(token) {
    if (!token) return null;
    const session = this.#data.sessions.find((candidate) => candidate.tokenHash === hashSessionToken(token));
    if (!session || Date.parse(session.expiresAt) <= Date.now()) return null;
    return structuredClone(session);
  }

  async deleteSession(token) {
    if (!token) return false;
    return this.#mutate((data) => {
      const tokenHash = hashSessionToken(token);
      const before = data.sessions.length;
      data.sessions = data.sessions.filter((session) => session.tokenHash !== tokenHash);
      return data.sessions.length !== before;
    });
  }

  async #mutate(callback) {
    const operation = this.#writeQueue.then(async () => {
      // Só expõe a alteração em memória depois de confirmar a gravação atômica.
      const updated = structuredClone(this.#data);
      const result = callback(updated);
      await this.#persist(updated);
      this.#data = updated;
      return result;
    });
    this.#writeQueue = operation.catch(() => {});
    return operation;
  }

  async #persist(data = this.#data) {
    const temporaryPath = `${this.#filePath}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`;
    await writeFile(temporaryPath, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600 });
    await rename(temporaryPath, this.#filePath);
  }
}
