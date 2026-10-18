import { spawn } from 'node:child_process';

const viteArguments = process.argv.slice(2);
const processes = [
  spawn(process.execPath, ['--watch', 'server/index.js'], { stdio: 'inherit' }),
  spawn('vite', viteArguments, { stdio: 'inherit', shell: process.platform === 'win32' }),
];

let stopping = false;
function stop(signal = 'SIGTERM') {
  if (stopping) return;
  stopping = true;
  for (const child of processes) {
    if (!child.killed) child.kill(signal);
  }
}

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => stop(signal));
}

for (const child of processes) {
  child.on('exit', (code) => {
    if (!stopping && code !== 0) process.exitCode = code ?? 1;
    stop();
  });
}
