import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { createServer as createViteServer } from 'vite';
import viteConfig from '../vite.config.js';
import { createApp } from './app.js';

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  return `http://127.0.0.1:${address.port}`;
}

test('proxy local preserva o cadastro same-origin observado pelo navegador', async (context) => {
  const tempDirectory = await mkdtemp(path.join(tmpdir(), 'zspeak-site-proxy-'));
  const apiServer = await createApp({ dataFile: path.join(tempDirectory, 'data.json') });
  const apiOrigin = await listen(apiServer);
  const viteServer = await createViteServer({
    ...viteConfig,
    configFile: false,
    logLevel: 'silent',
    server: {
      ...viteConfig.server,
      host: '127.0.0.1',
      port: 0,
      proxy: {
        '/api': {
          ...viteConfig.server.proxy['/api'],
          target: apiOrigin,
          headers: { Origin: apiOrigin },
        },
      },
    },
  });

  await viteServer.listen();
  const viteAddress = viteServer.httpServer.address();
  const siteOrigin = `http://127.0.0.1:${viteAddress.port}`;

  context.after(async () => {
    await viteServer.close();
    await new Promise((resolve) => apiServer.close(resolve));
    await rm(tempDirectory, { recursive: true, force: true });
  });

  const response = await fetch(`${siteOrigin}/api/auth/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Origin: siteOrigin },
    body: JSON.stringify({
      name: 'Teste Proxy',
      email: 'proxy@local.test',
      password: 'SenhaLocal123',
    }),
  });

  assert.equal(response.status, 200);
  assert.match(response.headers.get('set-cookie') ?? '', /HttpOnly/);
});
