import test from 'node:test';
import assert from 'node:assert/strict';
import { loadAccountDeletionClient } from '../auth_web/account-deletion/request.mjs';

const config = { apiKey: `AIza${'a'.repeat(35)}`, projectId: 'fishingbuild' };
const email = 'angler@example.test';
const password = '  existing-password  ';
const localId = 'user_123';
const idToken = 'header.payload.signature';
const account = { localId, idToken, refreshToken: 'private-refresh-token', email };
const documents = 'projects/fishingbuild/databases/(default)/documents';
const name = `${documents}/web_account_deletion_requests/${localId}`;
const saved = {
  name,
  fields: {
    schemaVersion: { integerValue: '1' },
    status: { stringValue: 'REQUESTED' },
    requestedAt: { timestampValue: '2026-11-23T11:00:00Z' },
  },
};
const response = (data, status = 200) => Response.json(data, { status });
const error = (message, status = 400) => response({ error: { message } }, status);

function mockFetch(...steps) {
  const calls = [];
  const fetchImplementation = async function (target, options) {
    assert.equal(this, globalThis);
    const step = steps[calls.length];
    calls.push({ target, options });
    if (step instanceof Error) throw step;
    assert.ok(step, 'Unexpected network request');
    return step;
  };
  return { calls, fetchImplementation };
}

async function openClient(...steps) {
  const mock = mockFetch(response(config), ...steps);
  const client = await loadAccountDeletionClient(mock.fetchImplementation);
  return { ...mock, client };
}

test('authenticates at the fixed provider and creates a minimal single request', async () => {
  const { calls, client } = await openClient(response(account), response({}));
  assert.equal(await client.requestDeletion(` ${email} `, password), 'submitted');
  assert.equal(calls.length, 3);
  const [setup, authentication, commit] = calls;
  assert.equal(setup.target, '/firebase-config.json');
  const authUrl = new URL(authentication.target);
  assert.equal(authUrl.origin, 'https://identitytoolkit.googleapis.com');
  assert.equal(authUrl.pathname, '/v1/accounts:signInWithPassword');
  assert.deepEqual([...authUrl.searchParams], [['key', config.apiKey]]);
  assert.deepEqual(JSON.parse(authentication.options.body), { email, password, returnSecureToken: true });
  assert.equal(commit.target, `https://firestore.googleapis.com/v1/${documents}:commit`);
  assert.equal(commit.options.headers.Authorization, `Bearer ${idToken}`);
  assert.deepEqual(JSON.parse(commit.options.body), {
    writes: [{
      update: {
        name,
        fields: { schemaVersion: { integerValue: '1' }, status: { stringValue: 'REQUESTED' } },
      },
      updateTransforms: [{ fieldPath: 'requestedAt', setToServerValue: 'REQUEST_TIME' }],
      currentDocument: { exists: false },
    }],
  });
  for (const { target, options } of calls) {
    assert.equal(options.credentials, 'omit');
    assert.equal(options.redirect, 'error');
    assert.equal(options.cache, 'no-store');
    assert.equal(options.referrerPolicy, 'no-referrer');
    assert.ok(options.signal instanceof AbortSignal);
    for (const value of [email, password, idToken, account.refreshToken]) {
      assert.ok(!target.includes(value));
    }
  }
  assert.ok(!authentication.options.headers.Authorization);
});

test('invalid settings fail before sending personal data', async () => {
  for (const settings of [
    response(null), response({ ...config, apiKey: 'https://invalid.test/' }),
    response({ ...config, projectId: 'example/../other' }),
    response({ ...config, apiKey: [config.apiKey] }),
    new Response('invalid JSON'), new Response('', { status: 404 }),
  ]) {
    const { calls, fetchImplementation } = mockFetch(settings);
    await assert.rejects(loadAccountDeletionClient(fetchImplementation), { code: 'configuration' });
    assert.equal(calls.length, 1);
  }
});

test('validates email and password without imposing new password rules', async () => {
  const { calls, client } = await openClient();
  for (const [badEmail, badPassword] of [[null, password], ['bad-email', password], [email, ''], [email, undefined]]) {
    await assert.rejects(client.requestDeletion(badEmail, badPassword), { code: 'invalid-input' });
  }
  await assert.rejects(client.requestPasswordReset('bad-email'), { code: 'invalid-input' });
  assert.equal(calls.length, 1);
});

test('wrong credentials and account existence return the same error and never reach Firestore', async () => {
  for (const reason of ['EMAIL_NOT_FOUND', 'INVALID_PASSWORD', 'INVALID_LOGIN_CREDENTIALS', 'USER_DISABLED']) {
    const { calls, client } = await openClient(error(`${reason}: private detail ${email}`));
    await assert.rejects(client.requestDeletion(email, password), {
      code: 'invalid-credentials', message: 'invalid-credentials',
    });
    assert.equal(calls.length, 2);
  }
});

test('rejects malformed authentication responses without constructing a write', async () => {
  for (const authenticated of [null, {}, { ...account, localId: '../other' }, { ...account, idToken: 'unexpected\r\nheader' }]) {
    const { calls, client } = await openClient(response(authenticated));
    await assert.rejects(client.requestDeletion(email, password), { code: 'unavailable' });
    assert.equal(calls.length, 2);
  }
});

test('allows the Auth emulator token shape when testing against local services', async () => {
  const { client } = await openClient(response({ ...account, idToken: 'header.payload.' }), response({}));
  assert.equal(await client.requestDeletion(email, 'old'), 'submitted');
});

test('maps rate limits, configuration failures and network errors to safe codes', async () => {
  for (const [failure, code] of [
    [error('TOO_MANY_ATTEMPTS_TRY_LATER'), 'rate-limited'],
    [new Response('', { status: 429 }), 'rate-limited'],
    [error('OPERATION_NOT_ALLOWED'), 'configuration'],
    [new Error(`private error ${password}`), 'unavailable'],
  ]) {
    const { calls, client } = await openClient(failure);
    await assert.rejects(client.requestDeletion(email, password), { code, message: code });
    assert.equal(calls.length, 2);
  }
});

test('verifies one existing request for a duplicate or a committed write with a lost response', async () => {
  for (const failure of [error('ALREADY_EXISTS', 409), error('PERMISSION_DENIED', 403), new Error('lost response')]) {
    const { calls, client } = await openClient(response(account), failure, response(saved));
    assert.equal(await client.requestDeletion(email, password), 'alreadySubmitted');
    assert.equal(calls.length, 4);
    const lookup = calls[3];
    assert.equal(lookup.target, `https://firestore.googleapis.com/v1/${name}`);
    assert.equal(lookup.options.headers.Authorization, `Bearer ${idToken}`);
    assert.equal(lookup.options.body, undefined);
  }
});

test('a commit failure is never treated as success without a valid matching request', async () => {
  for (const lookup of [
    error('NOT_FOUND', 404), response({ name }),
    response({ ...saved, name: `${documents}/web_account_deletion_requests/another` }),
    response({ ...saved, fields: { ...saved.fields, requestedAt: { timestampValue: 'invalid' } } }),
  ]) {
    const { client } = await openClient(response(account), error('PERMISSION_DENIED', 403), lookup);
    await assert.rejects(client.requestDeletion(email, password), { code: 'unavailable' });
  }
});

test('does not reissue Firestore traffic after a rate-limited write', async () => {
  const { calls, client } = await openClient(response(account), error('RESOURCE_EXHAUSTED', 429));
  await assert.rejects(client.requestDeletion(email, password), { code: 'rate-limited' });
  assert.equal(calls.length, 3);
});

test('password recovery uses only the existing auth email flow and hides account existence', async () => {
  for (const result of [response({ email }), error('EMAIL_NOT_FOUND'), error('USER_DISABLED')]) {
    const { calls, client } = await openClient(result);
    assert.equal(await client.requestPasswordReset(` ${email} `), undefined);
    assert.equal(calls.length, 2);
    const reset = calls[1];
    const url = new URL(reset.target);
    assert.equal(url.origin, 'https://identitytoolkit.googleapis.com');
    assert.equal(url.pathname, '/v1/accounts:sendOobCode');
    assert.deepEqual(JSON.parse(reset.options.body), { requestType: 'PASSWORD_RESET', email });
  }
});

test('password recovery surfaces actionable rate limits without exposing provider details', async () => {
  const { client } = await openClient(error(`RESET_PASSWORD_EXCEED_LIMIT: ${email}`));
  await assert.rejects(client.requestPasswordReset(email), { code: 'rate-limited', message: 'rate-limited' });
});
