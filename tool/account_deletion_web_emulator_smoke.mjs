import assert from 'node:assert/strict';
import { loadAccountDeletionClient } from '../auth_web/account-deletion/request.mjs';

const projectId = process.env.GCLOUD_PROJECT;
assert.match(projectId ?? '', /^demo-[a-z0-9-]+$/, 'Use a demo Firebase project.');

function emulatorOrigin(variable) {
  assert.ok(process.env[variable], `Missing ${variable}.`);
  const url = new URL(`http://${process.env[variable]}`);
  assert.ok(
    ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) &&
      url.port && !url.username && !url.password && url.pathname === '/' &&
      !url.search && !url.hash,
    `Use a loopback ${variable}.`,
  );
  return url.origin;
}

const authOrigin = emulatorOrigin('FIREBASE_AUTH_EMULATOR_HOST');
const firestoreOrigin = emulatorOrigin('FIRESTORE_EMULATOR_HOST');
const apiKey = `AIza${'a'.repeat(35)}`;
const email = `web-account-deletion-${Date.now()}@example.test`;
const password = 'LocalDeletionTest123';
const firestorePath = `/v1/projects/${projectId}/databases/(default)/documents`;

async function authRequest(action, body) {
  const response = await fetch(
    `${authOrigin}/identitytoolkit.googleapis.com/v1/accounts:${action}?key=${apiKey}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      redirect: 'error',
      signal: AbortSignal.timeout(10000),
    },
  );
  assert.equal(response.status, 200, `Local Auth ${action} failed.`);
  return response.json();
}

const { localId: uid } = await authRequest('signUp', {
  email, password, returnSecureToken: true,
});
const requestPath = `${firestorePath}/web_account_deletion_requests/${uid}`;

async function emulatorFetch(input, options) {
  if (String(input) === '/firebase-config.json') {
    return Response.json({ apiKey, projectId });
  }
  const url = new URL(input);
  if (url.origin === 'https://identitytoolkit.googleapis.com') {
    assert.match(url.pathname, /^\/v1\/accounts:(signInWithPassword|sendOobCode)$/);
    return fetch(`${authOrigin}/identitytoolkit.googleapis.com${url.pathname}${url.search}`, options);
  }
  assert.equal(url.origin, 'https://firestore.googleapis.com');
  assert.ok([`${firestorePath}:commit`, requestPath].includes(url.pathname));
  return fetch(`${firestoreOrigin}${url.pathname}${url.search}`, options);
}

async function adminGet(path) {
  return fetch(`${firestoreOrigin}${path}`, {
    headers: { Authorization: 'Bearer owner' },
    redirect: 'error',
    signal: AbortSignal.timeout(10000),
  });
}

const client = await loadAccountDeletionClient(emulatorFetch);
await assert.rejects(client.requestDeletion(email, 'WrongPassword123'), {
  code: 'invalid-credentials',
});
assert.equal((await adminGet(requestPath)).status, 404);

const outcomes = await Promise.all([
  client.requestDeletion(email, password),
  client.requestDeletion(email, password),
]);
assert.deepEqual(outcomes.sort(), ['alreadySubmitted', 'submitted']);
const stored = await adminGet(requestPath);
assert.equal(stored.status, 200);
const { fields } = await stored.json();
assert.deepEqual(Object.keys(fields).sort(), ['requestedAt', 'schemaVersion', 'status']);
assert.equal(fields.schemaVersion.integerValue, '1');
assert.equal(fields.status.stringValue, 'REQUESTED');
assert.ok(Number.isFinite(Date.parse(fields.requestedAt.timestampValue)));
assert.equal((await adminGet(`${firestorePath}/account_deletion_requests/${uid}`)).status, 404);
const login = await authRequest('signInWithPassword', {
  email, password, returnSecureToken: true,
});
assert.equal(login.localId, uid, 'Intake keeps the account active.');

await client.requestPasswordReset(email);
const resetCodes = await fetch(`${authOrigin}/emulator/v1/projects/${projectId}/oobCodes`, {
  redirect: 'error',
  signal: AbortSignal.timeout(10000),
});
assert.equal(resetCodes.status, 200);
const { oobCodes } = await resetCodes.json();
assert.ok(oobCodes.some((entry) => entry.email === email && entry.requestType === 'PASSWORD_RESET'));
console.log('Web intake passed with local Firebase Auth and Firestore emulators.');
