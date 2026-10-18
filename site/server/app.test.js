import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { afterEach, beforeEach, test } from 'node:test';
import { createApp } from './app.js';
import { FixedWindowRateLimiter } from './rate-limiter.js';
import { JsonStore } from './store.js';

let baseUrl;
let origin;
let server;
let temporaryDirectory;

beforeEach(async () => {
  temporaryDirectory = await mkdtemp(path.join(tmpdir(), 'zspeak-api-'));
  const downloadDirectory = path.join(temporaryDirectory, 'downloads');
  await mkdir(downloadDirectory);
  await writeFile(path.join(downloadDirectory, 'zspeak.dmg'), 'artefato de teste');
  server = await createApp({
    dataFile: path.join(temporaryDirectory, 'data.json'),
    downloadDirectory,
    rateLimit: { limit: 3, windowMs: 60_000 },
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  baseUrl = `http://127.0.0.1:${address.port}`;
  origin = baseUrl;
});

afterEach(async () => {
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  await rm(temporaryDirectory, { recursive: true, force: true });
});

function jsonRequest(pathname, body, options = {}) {
  return fetch(`${baseUrl}${pathname}`, {
    method: options.method ?? 'POST',
    headers: {
      Origin: options.origin ?? origin,
      'Content-Type': 'application/json',
      ...(options.cookie ? { Cookie: options.cookie } : {}),
    },
    body: JSON.stringify(body ?? {}),
  });
}

function cookieFrom(response) {
  return response.headers.getSetCookie()[0].split(';', 1)[0];
}

async function register(overrides = {}, options = {}) {
  return jsonRequest('/api/auth/register', {
    name: 'Michel Zandonai',
    email: 'michel@example.com',
    password: 'SenhaLocal1234',
    ...overrides,
  }, options);
}

test('health é público e cadastro cria sessão HttpOnly', async () => {
  const health = await fetch(`${baseUrl}/api/health`);
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), { status: 'ok' });

  const response = await register();
  assert.equal(response.status, 200);
  const payload = await response.json();
  assert.equal(payload.user.email, 'michel@example.com');
  assert.equal('passwordHash' in payload.user, false);
  assert.match(response.headers.get('set-cookie'), /HttpOnly; SameSite=Strict/);

  const me = await fetch(`${baseUrl}/api/auth/me`, { headers: { Cookie: cookieFrom(response) } });
  assert.equal(me.status, 200);
  assert.equal((await me.json()).user.name, 'Michel Zandonai');

  const persisted = await readFile(path.join(temporaryDirectory, 'data.json'), 'utf8');
  assert.doesNotMatch(persisted, /SenhaLocal1234/);
  assert.doesNotMatch(persisted, new RegExp(cookieFrom(response).split('=')[1]));
  assert.match(persisted, /scrypt\$32768\$8\$1\$/);
});

test('cookie de produção usa prefixo __Host e flag Secure', async () => {
  const productionServer = await createApp({
    dataFile: path.join(temporaryDirectory, 'production-data.json'),
    production: true,
  });
  await new Promise((resolve) => productionServer.listen(0, '127.0.0.1', resolve));
  const address = productionServer.address();
  const productionBaseUrl = `http://127.0.0.1:${address.port}`;

  try {
    const response = await fetch(`${productionBaseUrl}/api/auth/register`, {
      method: 'POST',
      headers: { Origin: productionBaseUrl, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        name: 'Pessoa Produção',
        email: 'production@example.com',
        password: 'SenhaLocal1234',
      }),
    });
    assert.equal(response.status, 200);
    assert.match(response.headers.get('set-cookie'), /^__Host-zspeak_session=/);
    assert.match(response.headers.get('set-cookie'), /; Secure$/);
  } finally {
    await new Promise((resolve, reject) => productionServer.close((error) => error ? reject(error) : resolve()));
  }
});

test('validação e e-mail duplicado são rejeitados', async () => {
  const invalid = await register({ password: 'fraca' });
  assert.equal(invalid.status, 422);

  assert.equal((await register()).status, 200);
  const duplicate = await register({ email: 'MICHEL@example.com' });
  assert.equal(duplicate.status, 409);
});

test('login rejeita credenciais inválidas e aceita senha correta', async () => {
  await register();
  const invalid = await jsonRequest('/api/auth/login', {
    email: 'michel@example.com',
    password: 'SenhaErrada1234',
  });
  assert.equal(invalid.status, 401);
  assert.deepEqual(await invalid.json(), {
    error: 'E-mail ou senha inválidos',
    message: 'E-mail ou senha inválidos',
  });

  const valid = await jsonRequest('/api/auth/login', {
    email: 'michel@example.com',
    password: 'SenhaLocal1234',
  });
  assert.equal(valid.status, 200);
  assert.match(valid.headers.get('set-cookie'), /^zspeak_session=/);
});

test('entitlements e downloads exigem sessão válida', async () => {
  assert.equal((await fetch(`${baseUrl}/api/entitlements`)).status, 401);
  assert.equal((await fetch(`${baseUrl}/api/downloads`)).status, 401);
  assert.equal((await fetch(`${baseUrl}/api/downloads/zspeak.dmg`)).status, 401);

  const registration = await register();
  const cookie = cookieFrom(registration);
  const entitlements = await fetch(`${baseUrl}/api/entitlements`, { headers: { Cookie: cookie } });
  assert.deepEqual(await entitlements.json(), { entitlements: ['zspeak-desktop'] });

  const platforms = await fetch(`${baseUrl}/api/downloads`, { headers: { Cookie: cookie } });
  assert.deepEqual(await platforms.json(), {
    platforms: [
      { id: 'macos', name: 'macOS', statusLabel: 'Publicação em preparação', url: null },
      { id: 'windows', name: 'Windows', statusLabel: 'Publicação em preparação', url: null },
    ],
  });

  const download = await fetch(`${baseUrl}/api/downloads/zspeak.dmg`, { headers: { Cookie: cookie } });
  assert.equal(download.status, 200);
  assert.equal(await download.text(), 'artefato de teste');
  assert.match(download.headers.get('content-disposition'), /attachment/);
});

test('logout revoga a sessão persistida', async () => {
  const registration = await register();
  const cookie = cookieFrom(registration);
  const logout = await jsonRequest('/api/auth/logout', {}, { cookie });
  assert.equal(logout.status, 200);
  assert.match(logout.headers.get('set-cookie'), /Max-Age=0/);
  assert.equal((await fetch(`${baseUrl}/api/auth/me`, { headers: { Cookie: cookie } })).status, 401);
});

test('origem cruzada e POST sem Origin falham por CORS/CSRF', async () => {
  const crossOrigin = await register({ email: 'cross@example.com' }, { origin: 'https://evil.example' });
  assert.equal(crossOrigin.status, 403);

  const missingOrigin = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: 'michel@example.com', password: 'SenhaLocal1234' }),
  });
  assert.equal(missingOrigin.status, 403);
});

test('rate limit bloqueia a quarta tentativa de login por origem e e-mail', async () => {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const response = await jsonRequest('/api/auth/login', {
      email: 'nobody@example.com',
      password: 'SenhaErrada1234',
    });
    assert.equal(response.status, 401);
  }

  const blocked = await jsonRequest('/api/auth/login', {
    email: 'nobody@example.com',
    password: 'SenhaErrada1234',
  });
  assert.equal(blocked.status, 429);
  assert.ok(Number(blocked.headers.get('retry-after')) >= 1);
});

test('rate limit por IP não é contornado alternando e-mails', async () => {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const response = await jsonRequest('/api/auth/login', {
      email: `nobody-${attempt}@example.com`,
      password: 'SenhaErrada1234',
    });
    assert.equal(response.status, 401);
  }

  const blocked = await jsonRequest('/api/auth/login', {
    email: 'another-account@example.com',
    password: 'SenhaErrada1234',
  });
  assert.equal(blocked.status, 429);
});

test('rate limiter limita memória e falha fechado quando saturado', () => {
  const limiter = new FixedWindowRateLimiter({ limit: 3, windowMs: 60_000, maxEntries: 2 });
  assert.equal(limiter.consume('primeira').allowed, true);
  assert.equal(limiter.consume('segunda').allowed, true);
  assert.equal(limiter.consume('terceira').allowed, false);
  assert.equal(limiter.consume('primeira').allowed, true);
});

test('download com URI malformada responde 404 sem expor erro interno', async () => {
  const registration = await register();
  const response = await fetch(`${baseUrl}/api/downloads/%E0%A4%A`, {
    headers: { Cookie: cookieFrom(registration) },
  });
  assert.equal(response.status, 404);
  assert.deepEqual(await response.json(), {
    error: 'Download não encontrado',
    message: 'Download não encontrado',
  });
});

test('catálogo expõe URL somente quando configurada explicitamente', async () => {
  const dataFile = path.join(temporaryDirectory, 'configured-data.json');
  const configuredServer = await createApp({
    dataFile,
    downloads: {
      macos: 'https://downloads.example.com/zspeak.dmg',
      windows: 'http://inseguro.example.com/zspeak.exe',
    },
  });
  await new Promise((resolve) => configuredServer.listen(0, '127.0.0.1', resolve));
  const address = configuredServer.address();
  const configuredBaseUrl = `http://127.0.0.1:${address.port}`;

  try {
    const registration = await fetch(`${configuredBaseUrl}/api/auth/register`, {
      method: 'POST',
      headers: { Origin: configuredBaseUrl, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        name: 'Pessoa Teste',
        email: 'configured@example.com',
        password: 'SenhaLocal1234',
      }),
    });
    const cookie = cookieFrom(registration);
    const response = await fetch(`${configuredBaseUrl}/api/downloads`, { headers: { Cookie: cookie } });
    const payload = await response.json();
    assert.equal(payload.platforms[0].url, 'https://downloads.example.com/zspeak.dmg');
    assert.equal(payload.platforms[0].statusLabel, 'Download disponível');
    assert.equal(payload.platforms[1].url, null);
  } finally {
    await new Promise((resolve, reject) => configuredServer.close((error) => error ? reject(error) : resolve()));
  }
});

test('persistência local mantém usuários e sessões após reinício', async () => {
  const registration = await register();
  const cookie = cookieFrom(registration);
  const dataFile = path.join(temporaryDirectory, 'data.json');
  const downloadDirectory = path.join(temporaryDirectory, 'downloads');

  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  server = await createApp({ dataFile, downloadDirectory });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  baseUrl = `http://127.0.0.1:${address.port}`;
  origin = baseUrl;

  const me = await fetch(`${baseUrl}/api/auth/me`, { headers: { Cookie: cookie } });
  assert.equal(me.status, 200);
  assert.equal((await me.json()).user.email, 'michel@example.com');
});

test('falha ao salvar sessão retorna HTTP 500 no cadastro e no login', async (context) => {
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  const store = await new JsonStore(path.join(temporaryDirectory, 'data.json')).init();
  context.mock.method(store, 'createSession', async () => {
    throw new Error('Falha de gravação simulada');
  });
  const loggedErrors = context.mock.method(console, 'error', () => {});
  server = await createApp({ store });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
  origin = baseUrl;

  const registration = await register();
  assert.equal(registration.status, 500);
  assert.deepEqual(await registration.json(), { error: 'Erro interno', message: 'Erro interno' });
  assert.equal(registration.headers.get('set-cookie'), null);

  const login = await jsonRequest('/api/auth/login', {
    email: 'michel@example.com',
    password: 'SenhaLocal1234',
  });
  assert.equal(login.status, 500);
  assert.equal(login.headers.get('set-cookie'), null);
  assert.equal(loggedErrors.mock.callCount(), 2);
  assert.equal((await fetch(`${baseUrl}/api/health`)).status, 200);
});
