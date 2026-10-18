import { createServer } from 'node:http';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { hashPassword, verifyPassword } from './password.js';
import { FixedWindowRateLimiter } from './rate-limiter.js';
import { JsonStore, normalizeEmail } from './store.js';

const DEFAULT_SESSION_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_BODY_BYTES = 16 * 1024;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const ARTIFACT_PATTERN = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const SERVER_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));

function sendJson(response, status, payload, headers = {}) {
  const normalizedPayload = payload?.error && !payload.message
    ? { ...payload, message: payload.error }
    : payload;
  const body = JSON.stringify(normalizedPayload);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    ...headers,
  });
  response.end(body);
}

function safeUser(user) {
  return {
    id: user.id,
    email: user.email,
    name: user.name,
    entitlements: user.entitlements,
    createdAt: user.createdAt,
  };
}

function parseCookies(rawCookie = '') {
  const cookies = {};
  for (const part of rawCookie.split(';')) {
    const separator = part.indexOf('=');
    if (separator === -1) continue;
    const key = part.slice(0, separator).trim();
    const value = part.slice(separator + 1).trim();
    try {
      cookies[key] = decodeURIComponent(value);
    } catch {
      // Cookie malformado é ignorado.
    }
  }
  return cookies;
}

function requestOrigin(request) {
  const forwardedProto = request.headers['x-forwarded-proto'];
  const protocol = forwardedProto === 'https' ? 'https' : request.socket.encrypted ? 'https' : 'http';
  return `${protocol}://${request.headers.host}`;
}

function isSameOrigin(request) {
  const origin = request.headers.origin;
  if (!origin) return false;
  try {
    return new URL(origin).origin === new URL(requestOrigin(request)).origin;
  } catch {
    return false;
  }
}

async function readJson(request) {
  if (!request.headers['content-type']?.toLowerCase().startsWith('application/json')) {
    const error = new Error('Content-Type deve ser application/json');
    error.status = 415;
    throw error;
  }

  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      const error = new Error('Corpo da requisição excede o limite');
      error.status = 413;
      throw error;
    }
    chunks.push(chunk);
  }

  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    const error = new Error('JSON inválido');
    error.status = 400;
    throw error;
  }
}

function validateRegistration(input) {
  const name = typeof input?.name === 'string' ? input.name.trim() : '';
  const email = typeof input?.email === 'string' ? normalizeEmail(input.email) : '';
  const password = typeof input?.password === 'string' ? input.password : '';
  const errors = {};

  if (name.length < 2 || name.length > 80) errors.name = 'Informe um nome entre 2 e 80 caracteres';
  if (email.length > 254 || !EMAIL_PATTERN.test(email)) errors.email = 'Informe um e-mail válido';
  if (password.length < 12 || password.length > 128) errors.password = 'Use uma senha entre 12 e 128 caracteres';
  if (!/[a-z]/.test(password) || !/[A-Z]/.test(password) || !/\d/.test(password)) {
    errors.password = 'A senha deve conter letras minúsculas, maiúsculas e números';
  }

  return { valid: Object.keys(errors).length === 0, errors, value: { name, email, password } };
}

function validateLogin(input) {
  const email = typeof input?.email === 'string' ? normalizeEmail(input.email) : '';
  const password = typeof input?.password === 'string' ? input.password : '';
  return {
    valid: email.length <= 254 && EMAIL_PATTERN.test(email) && password.length >= 1 && password.length <= 128,
    value: { email, password },
  };
}

function clientAddress(request) {
  return request.socket.remoteAddress || 'unknown';
}

function safeDownloadUrl(value) {
  if (typeof value !== 'string' || value.length > 2048) return null;
  if (value.startsWith('/api/downloads/')) return value;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' ? url.href : null;
  } catch {
    return null;
  }
}

export async function createApp(options = {}) {
  const dataFile = options.dataFile ?? path.resolve(SERVER_DIRECTORY, '../data/zspeak.json');
  const downloadDirectory = path.resolve(options.downloadDirectory ?? path.resolve(SERVER_DIRECTORY, '../downloads'));
  const store = options.store ?? await new JsonStore(dataFile).init();
  const rateLimiter = options.rateLimiter ?? new FixedWindowRateLimiter(options.rateLimit);
  const sessionTtlMs = options.sessionTtlMs ?? DEFAULT_SESSION_TTL_MS;
  const production = options.production ?? process.env.NODE_ENV === 'production';
  const cookieName = production ? '__Host-zspeak_session' : 'zspeak_session';
  const configuredDownloads = options.downloads ?? {
    macos: process.env.ZSPEAK_MACOS_DOWNLOAD_URL,
    windows: process.env.ZSPEAK_WINDOWS_DOWNLOAD_URL,
  };
  const platforms = [
    { id: 'macos', name: 'macOS', url: safeDownloadUrl(configuredDownloads.macos) },
    { id: 'windows', name: 'Windows', url: safeDownloadUrl(configuredDownloads.windows) },
  ].map((platform) => ({
    ...platform,
    statusLabel: platform.url ? 'Download disponível' : 'Publicação em preparação',
  }));
  // Evita revelar por tempo de resposta se um e-mail existe.
  const dummyPasswordHash = await hashPassword('DummyPassword-Only-For-Timing-123');

  async function authenticatedUser(request) {
    const token = parseCookies(request.headers.cookie)[cookieName];
    const session = store.findSession(token);
    if (!session) return null;
    return { user: store.findUserById(session.userId), token };
  }

  function sessionCookie(token, maxAgeSeconds) {
    const attributes = [
      `${cookieName}=${encodeURIComponent(token)}`,
      'Path=/',
      'HttpOnly',
      'SameSite=Strict',
      `Max-Age=${maxAgeSeconds}`,
    ];
    if (production) attributes.push('Secure');
    return attributes.join('; ');
  }

  async function issueSession(response, user) {
    const session = await store.createSession(user.id, sessionTtlMs);
    sendJson(response, 200, { user: safeUser(user) }, {
      'Set-Cookie': sessionCookie(session.token, Math.floor(sessionTtlMs / 1000)),
    });
  }

  return createServer(async (request, response) => {
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('X-Frame-Options', 'DENY');
    response.setHeader('Referrer-Policy', 'no-referrer');
    response.setHeader('Cross-Origin-Resource-Policy', 'same-origin');

    try {
      const url = new URL(request.url, requestOrigin(request));
      const method = request.method ?? 'GET';

      if (request.headers.origin && !isSameOrigin(request)) {
        return sendJson(response, 403, { error: 'Origem não permitida' });
      }
      if (['POST', 'PUT', 'PATCH', 'DELETE'].includes(method) && !isSameOrigin(request)) {
        return sendJson(response, 403, { error: 'Verificação CSRF falhou' });
      }

      if (method === 'GET' && url.pathname === '/api/health') {
        return sendJson(response, 200, { status: 'ok' });
      }

      if (method === 'POST' && url.pathname === '/api/auth/register') {
        const attempt = rateLimiter.consume(`register:${clientAddress(request)}`);
        if (!attempt.allowed) {
          return sendJson(response, 429, { error: 'Muitas tentativas. Tente novamente mais tarde.' }, {
            'Retry-After': attempt.retryAfterSeconds,
          });
        }

        const validation = validateRegistration(await readJson(request));
        if (!validation.valid) return sendJson(response, 422, { error: 'Dados inválidos', fields: validation.errors });

        const passwordHash = await hashPassword(validation.value.password);
        const user = await store.createUser({ ...validation.value, passwordHash });
        if (!user) return sendJson(response, 409, { error: 'Não foi possível criar a conta com este e-mail' });
        return await issueSession(response, user);
      }

      if (method === 'POST' && url.pathname === '/api/auth/login') {
        const body = await readJson(request);
        const validation = validateLogin(body);
        const emailKey = validation.value.email || 'invalid';
        const address = clientAddress(request);
        const ipAttempt = rateLimiter.consume(`login-ip:${address}`);
        const accountAttempt = rateLimiter.consume(`login-account:${address}:${emailKey}`);
        if (!ipAttempt.allowed || !accountAttempt.allowed) {
          const retryAfterSeconds = Math.max(ipAttempt.retryAfterSeconds, accountAttempt.retryAfterSeconds);
          return sendJson(response, 429, { error: 'Muitas tentativas. Tente novamente mais tarde.' }, {
            'Retry-After': retryAfterSeconds,
          });
        }

        if (!validation.valid) return sendJson(response, 401, { error: 'E-mail ou senha inválidos' });
        const user = store.findUserByEmail(validation.value.email);
        const passwordMatches = await verifyPassword(
          validation.value.password,
          user?.passwordHash ?? dummyPasswordHash,
        );
        if (!user || !passwordMatches) return sendJson(response, 401, { error: 'E-mail ou senha inválidos' });
        return await issueSession(response, user);
      }

      if (method === 'POST' && url.pathname === '/api/auth/logout') {
        const auth = await authenticatedUser(request);
        if (auth) await store.deleteSession(auth.token);
        return sendJson(response, 200, { success: true }, {
          'Set-Cookie': sessionCookie('', 0),
        });
      }

      if (method === 'GET' && url.pathname === '/api/auth/me') {
        const auth = await authenticatedUser(request);
        if (!auth?.user) return sendJson(response, 401, { error: 'Autenticação necessária' });
        return sendJson(response, 200, { user: safeUser(auth.user) });
      }

      if (method === 'GET' && url.pathname === '/api/entitlements') {
        const auth = await authenticatedUser(request);
        if (!auth?.user) return sendJson(response, 401, { error: 'Autenticação necessária' });
        return sendJson(response, 200, { entitlements: auth.user.entitlements });
      }

      if (method === 'GET' && url.pathname === '/api/downloads') {
        const auth = await authenticatedUser(request);
        if (!auth?.user) return sendJson(response, 401, { error: 'Autenticação necessária' });
        if (!auth.user.entitlements.includes('zspeak-desktop')) {
          return sendJson(response, 403, { error: 'Downloads não incluídos na sua conta' });
        }
        return sendJson(response, 200, { platforms });
      }

      const downloadMatch = method === 'GET' && url.pathname.match(/^\/api\/downloads\/([^/]+)$/);
      if (downloadMatch) {
        const auth = await authenticatedUser(request);
        if (!auth?.user) return sendJson(response, 401, { error: 'Autenticação necessária' });
        if (!auth.user.entitlements.includes('zspeak-desktop')) {
          return sendJson(response, 403, { error: 'Download não incluído na sua conta' });
        }

        let artifact;
        try {
          artifact = decodeURIComponent(downloadMatch[1]);
        } catch {
          return sendJson(response, 404, { error: 'Download não encontrado' });
        }
        if (!ARTIFACT_PATTERN.test(artifact)) return sendJson(response, 404, { error: 'Download não encontrado' });
        const filePath = path.resolve(downloadDirectory, artifact);
        if (path.dirname(filePath) !== downloadDirectory) return sendJson(response, 404, { error: 'Download não encontrado' });

        let metadata;
        try {
          metadata = await stat(filePath);
        } catch (error) {
          if (error.code === 'ENOENT') return sendJson(response, 404, { error: 'Download não encontrado' });
          throw error;
        }
        if (!metadata.isFile()) return sendJson(response, 404, { error: 'Download não encontrado' });

        response.writeHead(200, {
          'Content-Type': 'application/octet-stream',
          'Content-Length': metadata.size,
          'Content-Disposition': `attachment; filename="${artifact}"`,
          'Cache-Control': 'private, no-store',
        });
        return createReadStream(filePath).pipe(response);
      }

      if (url.pathname.startsWith('/api/')) return sendJson(response, 404, { error: 'Endpoint não encontrado' });
      return sendJson(response, 404, { error: 'Recurso não encontrado' });
    } catch (error) {
      if (error.status) return sendJson(response, error.status, { error: error.message });
      console.error(error);
      return sendJson(response, 500, { error: 'Erro interno' });
    }
  });
}

export function defaultDataFile() {
  return path.resolve(SERVER_DIRECTORY, '../data/zspeak.json');
}
