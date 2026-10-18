import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rename, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { JsonStore } from './store.js';

test('gravação rejeitada não publica usuário ou sessão e a fila se recupera', async (context) => {
  const directory = await mkdtemp(path.join(tmpdir(), 'zspeak-store-'));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const filePath = path.join(directory, 'data.json');
  const savedPath = path.join(directory, 'saved.json');
  const store = await new JsonStore(filePath).init();
  const user = { name: 'Pessoa Teste', email: 'store@example.com', passwordHash: 'hash-de-teste' };

  // Um diretório no destino força falha de rename em vez de depender de permissões/root.
  await rename(filePath, savedPath);
  await mkdir(filePath);
  await assert.rejects(store.createUser(user));
  assert.equal(store.findUserByEmail(user.email), null);

  await rm(filePath, { recursive: true });
  await rename(savedPath, filePath);
  const created = await store.createUser(user);
  assert.ok(created);
  const session = await store.createSession(created.id, 60_000);

  await rename(filePath, savedPath);
  await mkdir(filePath);
  await assert.rejects(store.deleteSession(session.token));
  assert.equal(store.findSession(session.token).userId, created.id);

  await rm(filePath, { recursive: true });
  await rename(savedPath, filePath);
  assert.equal(await store.deleteSession(session.token), true);
  assert.equal(store.findSession(session.token), null);
  const persisted = JSON.parse(await readFile(filePath, 'utf8'));
  assert.equal(persisted.users.length, 1);
  assert.equal(persisted.sessions.length, 0);
});

test('cadastros concorrentes do mesmo e-mail confirmam um único usuário', async (context) => {
  const directory = await mkdtemp(path.join(tmpdir(), 'zspeak-store-'));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const filePath = path.join(directory, 'data.json');
  const store = await new JsonStore(filePath).init();
  const createUser = () => store.createUser({ name: 'Pessoa Teste', email: 'unique@example.com', passwordHash: 'hash-de-teste' });
  const users = await Promise.all([createUser(), createUser()]);
  assert.equal(users.filter(Boolean).length, 1);
  const reopened = await new JsonStore(filePath).init();
  assert.equal(reopened.findUserByEmail('unique@example.com').id, users.find(Boolean).id);
});
