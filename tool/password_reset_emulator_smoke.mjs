import assert from 'node:assert/strict';
import { PasswordResetController, parseActionLink } from '../auth_web/reset.mjs';

// No production fallback: this tool must run in a local demo Auth Emulator.
const projectId = process.env.GCLOUD_PROJECT;
const emulatorHost = process.env.FIREBASE_AUTH_EMULATOR_HOST;
if (!projectId?.startsWith('demo-') || !emulatorHost) {
  throw new Error('Run through emulators:exec with a demo- project and Auth Emulator.');
}
const emulator = new URL(`http://${emulatorHost}`);
if (!['127.0.0.1', 'localhost', '[::1]'].includes(emulator.hostname)
  || emulator.username || emulator.password || emulator.pathname !== '/'
  || emulator.search || emulator.hash) {
  throw new Error('Only a loopback Auth Emulator is supported.');
}

// Synthetic credentials satisfy the web parser; they are never sent to Firebase
// production. Every fetch below targets the checked loopback origin.
const apiKey = `AIza${'a'.repeat(35)}`;
const config = { projectId: 'fishingbuild', apiKey };
const email = `password-reset-${Date.now()}@example.test`;
const oldPassword = 'OriginalPassword123';
const displayName = 'Password reset smoke test';
const restBase = `${emulator.origin}/identitytoolkit.googleapis.com/v1`;
const resetUrl = `https://identitytoolkit.googleapis.com/v1/accounts:resetPassword?key=${apiKey}`;
let resetRequests = 0;

async function authRequest(method, body) {
  assert.match(method, /^accounts:[A-Za-z]+$/);
  const response = await fetch(`${restBase}/${method}?key=${apiKey}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    redirect: 'error',
    signal: AbortSignal.timeout(10000),
  });
  return { response, data: await response.json() };
}

async function successfulRequest(method, body) {
  const { response, data } = await authRequest(method, body);
  // Keep passwords, tokens, emails, and action codes out of diagnostics.
  assert.equal(response.status, 200, `${method} should succeed`);
  return data;
}

async function emulatorFetch(target, options) {
  assert.equal(String(target), resetUrl, 'Unexpected controller endpoint');
  assert.equal(options.method, 'POST');
  assert.equal(options.redirect, 'error');
  assert.equal(options.credentials, 'omit');
  resetRequests += 1;
  return fetch(`${restBase}/accounts:resetPassword?key=${apiKey}`, {
    ...options,
    signal: AbortSignal.timeout(10000),
  });
}

function controllerFor(code) {
  const url = new URL('https://reset.example.test/');
  url.searchParams.set('mode', 'resetPassword');
  url.searchParams.set('apiKey', apiKey);
  url.searchParams.set('oobCode', code);
  return new PasswordResetController({
    link: parseActionLink(url.href), config, fetchImpl: emulatorFetch,
  });
}

async function requestResetCode() {
  await successfulRequest('accounts:sendOobCode', {
    requestType: 'PASSWORD_RESET', email,
  });
  const response = await fetch(
    `${emulator.origin}/emulator/v1/projects/${encodeURIComponent(projectId)}/oobCodes`,
    { redirect: 'error', signal: AbortSignal.timeout(10000) },
  );
  assert.equal(response.status, 200, 'Emulator action-code lookup should succeed');
  const data = await response.json();
  const code = data.oobCodes?.findLast(
    (entry) => entry.email === email && entry.requestType === 'PASSWORD_RESET',
  );
  assert.ok(code?.oobCode, 'The emulator should issue a password-reset code');
  return code.oobCode;
}

const account = await successfulRequest('accounts:signUp', {
  email, password: oldPassword, returnSecureToken: true,
});
await successfulRequest('accounts:update', {
  idToken: account.idToken, displayName, returnSecureToken: true,
});

const code = await requestResetCode();
const controller = controllerFor(code);
assert.equal(await controller.verify(), true, 'Real reset response should verify');
assert.equal(controller.state.phase, 'ready');
assert.equal(controller.state.email, email);
console.log('PASS: issued reset code verifies through the web controller.');

const beforeValidation = resetRequests;
for (const [password, confirmation] of [
  ['onlyletters', 'onlyletters'], ['12345678', '12345678'],
  ['abc123', 'abc123'], ['NewPassword123', 'DifferentPassword123'],
]) {
  assert.equal(await controller.submit(password, confirmation), false);
}
assert.equal(resetRequests, beforeValidation, 'Invalid input must not reach Auth');
console.log('PASS: letter/number/length/confirmation validation prevents submission.');

const newPassword = 'NEWPASSWORD123';
assert.equal(await controller.submit(newPassword, newPassword), true);
assert.equal(controller.state.phase, 'success');
const signedIn = await successfulRequest('accounts:signInWithPassword', {
  email, password: newPassword, returnSecureToken: true,
});
assert.equal(signedIn.localId, account.localId, 'Password reset must preserve UID');
const lookup = await successfulRequest('accounts:lookup', { idToken: signedIn.idToken });
assert.equal(lookup.users?.[0]?.displayName, displayName);
const previousLogin = await authRequest('accounts:signInWithPassword', {
  email, password: oldPassword, returnSecureToken: true,
});
assert.equal(previousLogin.response.status, 400, 'The old password must be rejected');
const previousError = String(previousLogin.data?.error?.message ?? '').split(/[\s:]/)[0];
assert.ok(['INVALID_PASSWORD', 'INVALID_LOGIN_CREDENTIALS'].includes(previousError),
  'Old-password failure must be a credential error rather than a service failure');
console.log('PASS: new-password login preserves UID/profile and rejects the old password.');

const replay = controllerFor(code);
assert.equal(await replay.verify(), false, 'Used reset code must not verify');
assert.equal(replay.state.phase, 'error');
assert.equal(await replay.submit('AnotherPassword123', 'AnotherPassword123'), false);
const invalid = controllerFor('invalid-emulator-reset-code');
assert.equal(await invalid.verify(), false, 'Unknown reset code must not verify');
assert.equal(invalid.state.phase, 'error');
console.log('PASS: used and invalid reset codes cannot enable another password change.');

const second = controllerFor(await requestResetCode());
assert.equal(await second.verify(), true);
const lowercasePassword = 'newpassword123';
assert.equal(await second.submit(lowercasePassword, lowercasePassword), true);
const lowercaseLogin = await successfulRequest('accounts:signInWithPassword', {
  email, password: lowercasePassword, returnSecureToken: true,
});
assert.equal(lowercaseLogin.localId, account.localId);
console.log('PASS: uppercase or lowercase letters with digits are both accepted.');
console.log('Password reset Auth Emulator smoke test passed (local demo accounts only).');
