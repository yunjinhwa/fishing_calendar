import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';
import { hasEffectiveDate, renderLegalPage } from './render_legal_web.mjs';

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
const preview = process.argv.includes('--preview-legal');
const destination = join(root, '.dart_tool', preview ? 'auth_web_preview' : 'auth_web_public');
await mkdir(destination, { recursive: true });
await cp(join(root, 'auth_web'), destination, { recursive: true });
await writeFile(join(destination, 'firebase-config.json'),
  `${JSON.stringify({ apiKey: config.apiKey, projectId }, null, 2)}\n`);
const documents = [];
for (const name of ['privacy', 'terms']) {
  const source = await readFile(join(root, 'assets', 'legal', `${name}.txt`), 'utf8');
  documents.push({ name, source });
}
const includePolicies = preview || documents.every(({ source }) => hasEffectiveDate(source));
for (const { name, source } of documents) {
  const pageDirectory = join(destination, name);
  const outputFile = join(pageDirectory, 'index.html');
  if (includePolicies) {
    await mkdir(pageDirectory, { recursive: true });
    await writeFile(outputFile, renderLegalPage(source));
  } else {
    // The directory is generated staging. Remove only our two known page outputs.
    await rm(outputFile, { force: true });
  }
}
console.log(`Prepared ${destination}. Policy pages ${includePolicies ? 'included' : 'omitted (review copies)'}.`);
