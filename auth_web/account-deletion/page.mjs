import { loadAccountDeletionClient } from './request.mjs';

const messages = {
  'invalid-input': '입력한 내용을 확인하고 다시 시도해 주세요.',
  'invalid-credentials': '본인 확인에 실패했습니다. 이메일과 비밀번호를 확인해 주세요.',
  'rate-limited': '요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.',
  configuration: '현재 요청 서비스를 이용할 수 없습니다. 잠시 후 다시 시도해 주세요.',
  unavailable: '요청을 처리하지 못했습니다. 연결을 확인하고 다시 시도해 주세요.',
};
const byId = (id) => document.getElementById(id);
const form = byId('deletion-form');
const fields = byId('request-fields');
const email = byId('email');
const password = byId('password');
const submit = byId('submit');
const reset = byId('send-reset-email');
const status = byId('status');
const error = byId('error');
const retryConnection = byId('retry-connection');

let client;
let action = '';
let nextResetAt = 0;

function renderControls() {
  form.setAttribute('aria-busy', String(Boolean(action)));
  fields.disabled = !client || Boolean(action);
  submit.textContent = action === 'submit' ? '접수 중…' : '본인 확인 및 삭제 요청';
  const waitingForReset = Date.now() < nextResetAt;
  reset.disabled = waitingForReset;
  reset.textContent = action === 'reset'
    ? '메일 요청 중…'
    : waitingForReset
      ? '재설정 메일 재요청 대기 중'
      : '비밀번호 재설정 메일 보내기';
}

function showStatus(message) {
  status.textContent = message;
  status.hidden = !message;
}

function showError(message) {
  error.textContent = message;
  error.hidden = !message;
}

async function connect() {
  if (action) return;
  action = 'connect';
  retryConnection.hidden = true;
  showError('');
  showStatus('접수 서비스에 연결하고 있습니다.');
  renderControls();
  try {
    client = await loadAccountDeletionClient();
    showStatus('');
  } catch (failure) {
    showStatus('');
    showError(messages[failure?.code] ?? messages.unavailable);
    retryConnection.hidden = false;
  } finally {
    action = '';
    renderControls();
  }
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!client || action || form.hidden || !form.reportValidity()) return;

  const submittedPassword = password.value;
  password.value = '';
  action = 'submit';
  showError('');
  showStatus('본인 확인 후 삭제 요청을 접수하고 있습니다.');
  renderControls();
  try {
    const result = await client.requestDeletion(email.value.trim(), submittedPassword);
    form.reset();
    form.hidden = true;
    byId('success').hidden = false;
    const title = byId('success-title');
    title.textContent = result === 'alreadySubmitted'
      ? '이미 접수된 삭제 요청이 있습니다.'
      : '계정 삭제 요청을 접수했습니다.';
    title.focus();
  } catch (failure) {
    showError(messages[failure?.code] ?? messages.unavailable);
  } finally {
    action = '';
    showStatus('');
    renderControls();
  }
});

reset.addEventListener('click', async () => {
  if (!client || action || Date.now() < nextResetAt || !email.reportValidity()) return;

  password.value = '';
  action = 'reset';
  showError('');
  showStatus('비밀번호 재설정 메일을 요청하고 있습니다.');
  renderControls();
  try {
    await client.requestPasswordReset(email.value.trim());
    nextResetAt = Date.now() + 60000;
    setTimeout(renderControls, 60000);
    showStatus('가입된 이메일이라면 재설정 링크를 받을 수 있습니다. 1분 후에 다시 요청할 수 있습니다.');
  } catch (failure) {
    showStatus('');
    showError(messages[failure?.code] ?? messages.unavailable);
  } finally {
    action = '';
    renderControls();
  }
});

retryConnection.addEventListener('click', connect);
window.addEventListener('pagehide', () => { password.value = ''; });
void connect();
