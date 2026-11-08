const API_KEY = /^AIza[A-Za-z0-9_-]{35,76}$/;
const OTHER_MODES = new Set(['verifyEmail', 'recoverEmail', 'verifyAndChangeEmail', 'revertSecondFactorAddition']);
const API = 'https://identitytoolkit.googleapis.com/v1/accounts:resetPassword';
const MESSAGES = {
  invalid: '유효하지 않은 링크입니다. 앱에서 새 인증 메일을 요청해 주세요.',
  expired: '링크의 유효 기간이 만료되었습니다. 앱에서 새 인증 메일을 요청해 주세요.',
  configuration: '인증 설정을 확인할 수 없습니다. 앱에서 새 인증 메일을 요청해 주세요.',
  network: '네트워크 연결을 확인한 후 다시 시도해 주세요.',
  tooMany: '요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.',
  weak: '이 비밀번호를 사용할 수 없습니다. 영문과 숫자를 포함해 8자 이상으로 다시 입력해 주세요.',
  service: '현재 인증 서비스를 이용할 수 없습니다. 잠시 후 다시 시도해 주세요.',
};

export function parseActionLink(input) {
  try {
    const url = new URL(input);
    if (!['https:', 'http:'].includes(url.protocol)) return { error: 'invalid' };
    const query = url.searchParams;
    if (['mode', 'oobCode', 'apiKey'].some((name) => query.getAll(name).length !== 1)
      || query.getAll('lang').length > 1) return { error: 'invalid' };
    const mode = query.get('mode');
    const oobCode = query.get('oobCode');
    const apiKey = query.get('apiKey');
    const lang = query.get('lang') || '';
    if ((mode !== 'resetPassword' && !OTHER_MODES.has(mode))
      || !/^[A-Za-z0-9_-]{1,4096}$/.test(oobCode) || !API_KEY.test(apiKey)
      || (lang && !/^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8})?$/.test(lang))) return { error: 'invalid' };
    return { mode, oobCode, apiKey, lang };
  } catch { return { error: 'invalid' }; }
}

export function validatePassword(password, confirmation) {
  const errors = {};
  // JavaScript length counts UTF-16 code units, matching Dart String.length.
  if (typeof password !== 'string' || password.length < 8
    || !/[A-Za-z]/.test(password) || !/[0-9]/.test(password)) {
    errors.password = '영문과 숫자를 포함해 8자 이상으로 입력해 주세요.';
  }
  if (!confirmation) errors.confirmation = '새 비밀번호를 한 번 더 입력해 주세요.';
  else if (password !== confirmation) errors.confirmation = '비밀번호가 일치하지 않습니다.';
  return errors;
}

function validateConfig(config, link) {
  if (link.error) throw new ActionError('invalid');
  if (!config || config.projectId !== 'fishingbuild' || !API_KEY.test(config.apiKey)
    || config.apiKey !== link.apiKey) throw new ActionError('configuration');
  return config.apiKey;
}

export function defaultActionUrl(link, config) {
  validateConfig(config, link);
  if (!OTHER_MODES.has(link.mode)) throw new ActionError('invalid');
  const url = new URL('https://fishingbuild.firebaseapp.com/__/auth/action');
  for (const key of ['mode', 'oobCode', 'apiKey', 'lang']) {
    if (link[key]) url.searchParams.set(key, link[key]);
  }
  return url.href;
}

class ActionError extends Error {
  constructor(code) { super(MESSAGES[code] || MESSAGES.service); this.code = code; }
}

const requestOptions = { credentials: 'omit', redirect: 'error', cache: 'no-store', referrerPolicy: 'no-referrer' };
const retryable = (code) => ['network', 'tooMany', 'service'].includes(code);

export class PasswordResetController {
  #fetch; #link; #config; #key; #busy = false; #onChange;
  #state = { phase: 'idle', email: '', error: '', fieldErrors: {}, retryable: false, actionUrl: '' };

  constructor({ link, config, fetchImpl = globalThis.fetch, onChange = () => {} }) {
    this.#link = link; this.#config = config; this.#fetch = fetchImpl.bind(globalThis); this.#onChange = onChange;
  }
  get state() { return { ...this.#state, fieldErrors: { ...this.#state.fieldErrors } }; }
  #set(changes) { this.#state = { ...this.#state, ...changes }; this.#onChange(this.state); }

  async #post(body) {
    let response;
    try {
      response = await this.#fetch(`${API}?key=${encodeURIComponent(this.#key)}`, {
        ...requestOptions, method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify(body),
      });
    } catch { throw new ActionError('network'); }
    let data;
    try { data = await response.json(); } catch { throw new ActionError('service'); }
    if (!response.ok) {
      const name = String(data?.error?.message || '').split(/[\s:]/)[0];
      const code = ({ EXPIRED_OOB_CODE: 'expired', INVALID_OOB_CODE: 'invalid', EMAIL_NOT_FOUND: 'invalid',
        USER_DISABLED: 'invalid', WEAK_PASSWORD: 'weak', PASSWORD_DOES_NOT_MEET_REQUIREMENTS: 'weak',
        TOO_MANY_ATTEMPTS_TRY_LATER: 'tooMany', TOO_MANY_REQUESTS: 'tooMany' })[name] || 'service';
      throw new ActionError(code);
    }
    if (!data || typeof data.email !== 'string' || !data.email || data.email.length > 320) throw new ActionError('service');
    return data;
  }

  async verify() {
    if (this.#busy || ['success', 'handoff'].includes(this.#state.phase)) return false;
    this.#busy = true;
    this.#set({ phase: 'verifying', email: '', error: '', fieldErrors: {}, retryable: false });
    try {
      if (this.#link.error) throw new ActionError('invalid');
      if (!this.#config) {
        let response;
        try { response = await this.#fetch('/firebase-config.json', { ...requestOptions, headers: { Accept: 'application/json' } }); }
        catch { throw new ActionError('network'); }
        if (!response.ok) throw new ActionError('service');
        try { this.#config = await response.json(); } catch { throw new ActionError('configuration'); }
      }
      this.#key = validateConfig(this.#config, this.#link);
      if (this.#link.mode !== 'resetPassword') {
        this.#set({ phase: 'handoff', actionUrl: defaultActionUrl(this.#link, this.#config) });
      } else {
        const data = await this.#post({ oobCode: this.#link.oobCode });
        if (data.requestType !== 'PASSWORD_RESET') throw new ActionError('invalid');
        this.#set({ phase: 'ready', email: data.email });
      }
      return true;
    } catch (error) {
      const code = error instanceof ActionError ? error.code : 'service';
      this.#set({ phase: 'error', error: MESSAGES[code], retryable: retryable(code) });
      return false;
    } finally { this.#busy = false; }
  }

  async submit(password, confirmation) {
    if (this.#busy || this.#state.phase !== 'ready') return false;
    const fieldErrors = validatePassword(password, confirmation);
    if (Object.keys(fieldErrors).length) { this.#set({ fieldErrors, error: '' }); return false; }
    this.#busy = true;
    this.#set({ phase: 'submitting', error: '', fieldErrors: {} });
    try {
      const data = await this.#post({ oobCode: this.#link.oobCode, newPassword: password });
      if (data.email !== this.#state.email) throw new ActionError('service');
      this.#link = null; this.#key = null; this.#config = null;
      this.#set({ phase: 'success', email: '' });
      return true;
    } catch (error) {
      const code = error instanceof ActionError ? error.code : 'service';
      const invalid = ['invalid', 'expired'].includes(code);
      this.#set({ phase: invalid ? 'error' : 'ready', error: MESSAGES[code],
        fieldErrors: code === 'weak' ? { password: MESSAGES.weak } : {}, retryable: false });
      return false;
    } finally { this.#busy = false; }
  }
}

function mount() {
  const link = parseActionLink(window.location.href);
  window.history.replaceState(null, '', window.location.pathname);
  const byId = (id) => document.getElementById(id);
  const password = byId('password');
  const confirmation = byId('confirmation');
  const form = byId('reset-form');
  const render = (state) => {
    const busy = ['verifying', 'submitting'].includes(state.phase);
    form.setAttribute('aria-busy', String(busy));
    form.hidden = ['success', 'handoff'].includes(state.phase);
    byId('password-fields').disabled = state.phase !== 'ready';
    byId('submit').textContent = state.phase === 'submitting' ? '변경 중…' : '비밀번호 변경';
    byId('status').textContent = ({ verifying: '재설정 링크를 확인하고 있습니다.', ready: '아래에 새 비밀번호를 입력해 주세요.',
      submitting: '비밀번호를 변경하고 있습니다.', handoff: '계정 인증 링크입니다. 아래 버튼을 눌러 인증을 계속해 주세요.' })[state.phase] || '';
    byId('account').textContent = state.email ? `계정: ${state.email}` : '';
    byId('account').hidden = !state.email;
    byId('error').textContent = state.error;
    byId('error').hidden = !state.error;
    byId('retry').hidden = !state.retryable || state.phase !== 'error';
    byId('continue-auth').hidden = state.phase !== 'handoff';
    if (state.actionUrl) byId('continue-auth').href = state.actionUrl;
    byId('success').hidden = state.phase !== 'success';
    for (const [name, input] of [['password', password], ['confirmation', confirmation]]) {
      const message = state.fieldErrors[name] || '';
      input.setAttribute('aria-invalid', String(Boolean(message)));
      byId(`${name}-error`).textContent = message;
      byId(`${name}-error`).hidden = !message;
    }
  };
  const controller = new PasswordResetController({ link, onChange: render });
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    await controller.submit(password.value, confirmation.value);
    const state = controller.state;
    if (state.phase === 'success') { password.value = ''; confirmation.value = ''; byId('success-title').tabIndex = -1; byId('success-title').focus(); }
    else if (state.fieldErrors.password) password.focus();
    else if (state.fieldErrors.confirmation) confirmation.focus();
  });
  byId('retry').addEventListener('click', () => controller.verify());
  void controller.verify();
}

if (typeof document !== 'undefined' && typeof window !== 'undefined') mount();
