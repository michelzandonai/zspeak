import { createApp, defaultDataFile } from './app.js';

const port = Number(process.env.PORT ?? 4174);
const host = process.env.HOST ?? '127.0.0.1';

const server = await createApp({
  dataFile: process.env.ZSPEAK_DATA_FILE ?? defaultDataFile(),
  downloadDirectory: process.env.ZSPEAK_DOWNLOAD_DIR,
});

server.listen(port, host, () => {
  console.log(`zspeak API disponível em http://${host}:${port}`);
});
