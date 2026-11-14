import test from 'node:test';
import assert from 'node:assert/strict';
import { parseActionLink, validatePassword, defaultActionUrl, PasswordResetController } from '../auth_web/reset.mjs';

const apiKey = `AIza${'a'.repeat(35)}`;
const otherKey = `AIza${'b'.repeat(35)}`;
const config = { apiKey, projectId: 'fishingbuild' };
const code = 'safe-reset-code-123';
const email = 'angler@example.test';
const verified = { email, requestType: 'PASSWORD_RESET' };
const url = (extra = '') => `https://reset.example.test/?mode=resetPassword&oobCode=${code}&apiKey=${apiKey}${extra}`;
const link = () => parseActionLink(url());
const response = (body, ok = true) => ({ ok, json: async () => body });
const failure = (name) => response({ error: { message: name } }, false);
const deferred = () => { let resolve; const promise = new Promise((done) => { resolve = done; }); return { promise, resolve }; };

test('parses required values while discarding continueUrl and unrelated data', () => {
  assert.deepEqual(parseActionLink(url('&continueUrl=https://evil.test/&email=private')), {
    mode: 'resetPassword', oobCode: code, apiKey, lang: '',
  });
  for (const input of [url('&mode=resetPassword'), url('&oobCode=other'), url('&apiKey=other'),
    url().replace('resetPassword', 'unknown'), url().replace(code, ''), url().replace(apiKey, 'https://evil.test/key')]) {
    assert.deepEqual(parseActionLink(input), { error: 'invalid' });
  }
});

test('known non-reset modes use only the fixed Firebase action URL', async () => {
  for (const mode of ['verifyEmail', 'recoverEmail', 'verifyAndChangeEmail', 'revertSecondFactorAddition']) {
    const action = parseActionLink(url('&lang=ko&continueUrl=https://evil.test/&extra=secret').replace('resetPassword', mode));
    const target = new URL(defaultActionUrl(action, config));
    assert.equal(target.origin, 'https://fishingbuild.firebaseapp.com');
    assert.equal(target.pathname, '/__/auth/action');
    assert.deepEqual([...target.searchParams.keys()], ['mode', 'oobCode', 'apiKey', 'lang']);
    assert.equal(target.searchParams.get('mode'), mode);
    assert.equal(target.searchParams.get('lang'), 'ko');
    const controller = new PasswordResetController({ link: action, config, fetchImpl: () => assert.fail('No REST call for handoff') });
    assert.equal(await controller.verify(), true);
    assert.equal(controller.state.phase, 'handoff');
    assert.equal(await controller.submit('abcde123', 'abcde123'), false);
  }
  assert.throws(() => defaultActionUrl(link(), config));
});

test('password rule allows either ASCII letter case, optional symbols, and UTF-16 length', () => {
  for (const password of ['abcde123', 'ABCDE123', 'Abcde123', 'abc123!!', '😀😀a123', 'abc123\n\n']) {
    assert.deepEqual(validatePassword(password, password), {});
  }
  for (const password of ['abc1234', 'abcdefgh', '12345678', '한글한글1234', 'абвгд123', 'abcde１２３']) {
    assert.ok(validatePassword(password, password).password);
  }
  assert.ok(validatePassword('abcde123', 'abcde124').confirmation);
  assert.ok(validatePassword('abcde123', '').confirmation);
});

test('configuration and query keys must match the intended project before any API request', async () => {
  for (const supplied of [{ ...config, apiKey: otherKey }, { ...config, projectId: 'other' }, { ...config, apiKey: 'https://evil.test' }]) {
    const controller = new PasswordResetController({ link: link(), config: supplied, fetchImpl: () => assert.fail('Unexpected request') });
    assert.equal(await controller.verify(), false);
    assert.equal(controller.state.phase, 'error');
    assert.equal(await controller.submit('abcde123', 'abcde123'), false);
  }
});

test('loads only the local public config and uses fixed REST origin with private fetch options', async () => {
  const calls = [];
  const controller = new PasswordResetController({ link: link(), fetchImpl: async (target, options) => {
    calls.push({ target, options });
    return response(calls.length === 1 ? config : calls.length === 2 ? verified : { email });
  } });
  assert.equal(await controller.verify(), true);
  assert.equal(calls[0].target, '/firebase-config.json');
  assert.equal(await controller.submit('abcde123', 'abcde123'), true);
  assert.equal(controller.state.phase, 'success');
  for (const { target, options } of calls) {
    assert.equal(options.credentials, 'omit'); assert.equal(options.redirect, 'error');
    assert.equal(options.cache, 'no-store'); assert.equal(options.referrerPolicy, 'no-referrer');
    assert.ok(!target.includes(code)); assert.ok(!target.includes('abcde123'));
  }
  for (const call of calls.slice(1)) {
    assert.equal(new URL(call.target).origin, 'https://identitytoolkit.googleapis.com');
    assert.equal(new URL(call.target).pathname, '/v1/accounts:resetPassword');
  }
  assert.deepEqual(JSON.parse(calls[1].options.body), { oobCode: code });
  assert.deepEqual(JSON.parse(calls[2].options.body), { oobCode: code, newPassword: 'abcde123' });
  assert.equal(controller.state.email, '');
});

test('fetch receives the global receiver for configuration and REST requests', async () => {
  let calls = 0;
  const controller = new PasswordResetController({ link: link(), fetchImpl: async function () {
    assert.equal(this, globalThis);
    calls += 1;
    return response(calls === 1 ? config : calls === 2 ? verified : { email });
  } });
  assert.equal(await controller.verify(), true);
  assert.equal(await controller.submit('abcde123', 'abcde123'), true);
  assert.equal(calls, 3);
});

test('invalid fields never submit and duplicate verify/submit calls are guarded', async () => {
  const pendingVerify = deferred(); const pendingSubmit = deferred(); const calls = [];
  const controller = new PasswordResetController({ link: link(), config, fetchImpl: (target, options) => {
    calls.push({ target, options }); return calls.length === 1 ? pendingVerify.promise : pendingSubmit.promise;
  } });
  const verifying = controller.verify();
  assert.equal(await controller.verify(), false);
  assert.equal(await controller.submit('abcde123', 'abcde123'), false);
  assert.equal(calls.length, 1);
  pendingVerify.resolve(response(verified)); await verifying;
  assert.equal(await controller.submit('12345678', '12345678'), false);
  assert.equal(await controller.submit('abcde123', 'different'), false);
  assert.equal(calls.length, 1);
  const submitting = controller.submit('abcde123', 'abcde123');
  assert.equal(await controller.submit('abcde123', 'abcde123'), false);
  assert.equal(await controller.verify(), false);
  assert.equal(calls.length, 2);
  pendingSubmit.resolve(response({ email })); assert.equal(await submitting, true);
  assert.equal(await controller.submit('abcde123', 'abcde123'), false);
});

test('expired and invalid links cannot enable form or report success', async () => {
  for (const name of ['EXPIRED_OOB_CODE', 'INVALID_OOB_CODE']) {
    const controller = new PasswordResetController({ link: link(), config, fetchImpl: async () => failure(name) });
    assert.equal(await controller.verify(), false);
    assert.equal(controller.state.phase, 'error');
    assert.equal(controller.state.retryable, false);
    assert.equal(await controller.submit('abcde123', 'abcde123'), false);
    assert.ok(controller.state.error.includes(name.startsWith('EXPIRED') ? '만료' : '유효하지'));
  }
});

test('verification rejects missing or different action types before enabling password changes', async () => {
  for (const requestType of [undefined, 'VERIFY_EMAIL', 'RECOVER_EMAIL', 'VERIFY_AND_CHANGE_EMAIL']) {
    let calls = 0;
    const controller = new PasswordResetController({ link: link(), config, fetchImpl: async () => {
      calls += 1; return response({ email, requestType });
    } });
    assert.equal(await controller.verify(), false);
    assert.equal(controller.state.phase, 'error');
    assert.equal(await controller.submit('abcde123', 'abcde123'), false);
    assert.equal(calls, 1);
  }
});

test('network verification failure can retry using the code retained only in memory', async () => {
  const bodies = []; let attempts = 0;
  const controller = new PasswordResetController({ link: link(), config, fetchImpl: async (_target, options) => {
    bodies.push(JSON.parse(options.body));
    if (++attempts === 1) throw new TypeError('synthetic network failure');
    return response(verified);
  } });
  assert.equal(await controller.verify(), false);
  assert.equal(controller.state.retryable, true);
  assert.equal(controller.state.phase, 'error');
  assert.equal(await controller.verify(), true);
  assert.equal(controller.state.phase, 'ready');
  assert.deepEqual(bodies, [{ oobCode: code }, { oobCode: code }]);
});

test('failed commit never reports success and handles weak, rate, expired, and network failures', async () => {
  for (const name of ['WEAK_PASSWORD : synthetic detail', 'TOO_MANY_ATTEMPTS_TRY_LATER', 'EXPIRED_OOB_CODE', 'INVALID_OOB_CODE', 'network']) {
    let calls = 0;
    const controller = new PasswordResetController({ link: link(), config, fetchImpl: async () => {
      if (++calls === 1) return response(verified);
      if (name === 'network') throw new TypeError('synthetic failure');
      return failure(name);
    } });
    await controller.verify();
    assert.equal(await controller.submit('abcde123', 'abcde123'), false);
    assert.notEqual(controller.state.phase, 'success');
    assert.ok(controller.state.error);
    if (name.startsWith('WEAK')) assert.ok(controller.state.fieldErrors.password);
  }
});

test('malformed or inconsistent server successes fail closed without leaking server details', async () => {
  for (const badResponse of [response({}), response({ email: 'different@example.test' }), { ok: true, json: async () => { throw new Error(code); } }]) {
    let calls = 0;
    const controller = new PasswordResetController({ link: link(), config, fetchImpl: async () => ++calls === 1 ? response(verified) : badResponse });
    await controller.verify();
    assert.equal(await controller.submit('abcde123', 'abcde123'), false);
    assert.notEqual(controller.state.phase, 'success');
    assert.ok(!controller.state.error.includes(code));
  }
});

test('controller never logs code, password, email, or raw errors', async () => {
  const calls = []; const original = {};
  for (const method of ['log', 'info', 'warn', 'error', 'debug']) { original[method] = console[method]; console[method] = (...args) => calls.push(args); }
  try {
    let requests = 0;
    const controller = new PasswordResetController({ link: link(), config, fetchImpl: async () => {
      if (++requests === 1) return response(verified);
      throw new Error(`${code} abcde123 ${email}`);
    } });
    await controller.verify(); await controller.submit('abcde123', 'abcde123');
    assert.deepEqual(calls, []);
  } finally { for (const method of Object.keys(original)) console[method] = original[method]; }
});
