import { cp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';

// Use the project's public backend key, which is also placed in email links.
// No CLI login, access token or service-account key is bundled in this page.
const projectId = 'fishingbuild';
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const configFile = process.argv.slice(2).find(value => value.startsWith('--firebase-config='));
let config;
if (configFile) {
  config = JSON.parse(await readFile(resolve(root, configFile.split('=').slice(1).join('=')), 'utf8'));
} else {
  const response = await fetch(
    'https://fishingbuild-password-reset.web.app/__/firebase/init.json',
    { signal: AbortSignal.timeout(15000), redirect: 'error' },
  );
  if (!response.ok) throw new Error('Firebase public configuration is unavailable.');
  config = await response.json();
}
if (config.projectId !== projectId ||
    !/^AIza[A-Za-z0-9_-]{35,76}$/.test(config.apiKey ?? '')) {
  throw new Error('Firebase public configuration does not match this project.');
}
const destination = join(root, '.dart_tool', 'auth_web_public');
await mkdir(destination, { recursive: true });
await cp(join(root, 'auth_web'), destination, { recursive: true });
await writeFile(join(destination, 'firebase-config.json'),
  `${JSON.stringify({ apiKey: config.apiKey, projectId }, null, 2)}\n`);
console.log('Prepared password reset page with public Firebase configuration.');
