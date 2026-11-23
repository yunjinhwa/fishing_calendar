const AUTH_ACCOUNTS = 'https://identitytoolkit.googleapis.com/v1/accounts:';
const FIRESTORE = 'https://firestore.googleapis.com/v1/';
const API_KEY = /^AIza[A-Za-z0-9_-]{35,76}$/;
const PROJECT_ID = /^[a-z][a-z0-9-]{4,28}[a-z0-9]$/;
const USER_ID = /^[A-Za-z0-9_-]{1,128}$/;
const ID_TOKEN = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const accountErrors = new Set([
  'EMAIL_NOT_FOUND', 'INVALID_CREDENTIAL', 'INVALID_EMAIL',
  'INVALID_LOGIN_CREDENTIALS', 'INVALID_PASSWORD', 'USER_DISABLED',
]);
const rateErrors = new Set([
  'QUOTA_EXCEEDED', 'RESET_PASSWORD_EXCEED_LIMIT', 'RESOURCE_EXHAUSTED',
  'TOO_MANY_ATTEMPTS_TRY_LATER', 'TOO_MANY_REQUESTS',
]);
const configurationErrors = new Set([
  'API_KEY_INVALID', 'API_KEY_SERVICE_BLOCKED', 'CONFIGURATION_NOT_FOUND',
  'INVALID_API_KEY', 'OPERATION_NOT_ALLOWED', 'PROJECT_NOT_FOUND',
]);

class AccountDeletionRequestError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function normalizeEmail(value) {
  const email = typeof value === 'string' ? value.trim() : '';
  if (email.length > 320 || !EMAIL.test(email)) {
    throw new AccountDeletionRequestError('invalid-input');
  }
  return email;
}

async function readJson(response, errorCode = 'unavailable') {
  try {
    return await response.json();
  } catch {
    throw new AccountDeletionRequestError(errorCode);
  }
}

function isSubmittedDocument(data, name) {
  const fields = data?.fields;
  const requestedAt = fields?.requestedAt?.timestampValue;
  return data?.name === name &&
    fields?.schemaVersion?.integerValue === '1' &&
    fields?.status?.stringValue === 'REQUESTED' &&
    typeof requestedAt === 'string' && Number.isFinite(Date.parse(requestedAt));
}

export async function loadAccountDeletionClient(fetchImplementation = globalThis.fetch) {
  async function request(url, options) {
    try {
      return await fetchImplementation.call(globalThis, url, {
        credentials: 'omit',
        redirect: 'error',
        cache: 'no-store',
        referrerPolicy: 'no-referrer',
        signal: AbortSignal.timeout(15000),
        ...options,
        headers: { Accept: 'application/json', ...options?.headers },
      });
    } catch {
      throw new AccountDeletionRequestError('unavailable');
    }
  }

  const configResponse = await request('/firebase-config.json');
  if (!configResponse.ok) {
    throw new AccountDeletionRequestError(configResponse.status === 404 ? 'configuration' : 'unavailable');
  }
  const config = await readJson(configResponse, 'configuration');
  const { apiKey, projectId } = config ?? {};
  if (typeof apiKey !== 'string' || !API_KEY.test(apiKey) ||
      typeof projectId !== 'string' || !PROJECT_ID.test(projectId)) {
    throw new AccountDeletionRequestError('configuration');
  }
  const documents = `projects/${projectId}/databases/(default)/documents`;

  async function authRequest(action, body) {
    const response = await request(`${AUTH_ACCOUNTS}${action}?key=${encodeURIComponent(apiKey)}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (response.status === 429) throw new AccountDeletionRequestError('rate-limited');
    const data = await readJson(response);
    if (response.ok) return data;

    const reason = typeof data?.error?.message === 'string'
      ? data.error.message.split(/[\s:]/, 1)[0]
      : '';
    if (rateErrors.has(reason)) throw new AccountDeletionRequestError('rate-limited');
    if (configurationErrors.has(reason)) throw new AccountDeletionRequestError('configuration');
    if (accountErrors.has(reason)) throw new AccountDeletionRequestError('invalid-credentials');
    throw new AccountDeletionRequestError('unavailable');
  }

  async function requestDeletion(value, password) {
    const email = normalizeEmail(value);
    if (typeof password !== 'string' || !password) {
      throw new AccountDeletionRequestError('invalid-input');
    }

    const account = await authRequest('signInWithPassword', {
      email, password, returnSecureToken: true,
    });
    const { localId, idToken } = account ?? {};
    if (typeof localId !== 'string' || !USER_ID.test(localId) ||
        typeof idToken !== 'string' || !ID_TOKEN.test(idToken)) {
      throw new AccountDeletionRequestError('unavailable');
    }

    const name = `${documents}/web_account_deletion_requests/${localId}`;
    const headers = { Authorization: `Bearer ${idToken}` };
    let failure = 'unavailable';
    try {
      const response = await request(`${FIRESTORE}${documents}:commit`, {
        method: 'POST',
        headers: { ...headers, 'Content-Type': 'application/json' },
        body: JSON.stringify({ writes: [{
          update: {
            name,
            fields: {
              schemaVersion: { integerValue: '1' },
              status: { stringValue: 'REQUESTED' },
            },
          },
          updateTransforms: [{ fieldPath: 'requestedAt', setToServerValue: 'REQUEST_TIME' }],
          currentDocument: { exists: false },
        }] }),
      });
      if (response.ok) return 'submitted';
      if (response.status === 429) failure = 'rate-limited';
    } catch {
      // A lost response may follow a committed write.
    }

    if (failure !== 'rate-limited') {
      try {
        const response = await request(`${FIRESTORE}${name}`, { headers });
        if (response.ok && isSubmittedDocument(await readJson(response), name)) {
          return 'alreadySubmitted';
        }
      } catch {
        // Report the original failure when the existing request cannot be verified.
      }
    }
    throw new AccountDeletionRequestError(failure);
  }

  async function requestPasswordReset(value) {
    const email = normalizeEmail(value);
    try {
      await authRequest('sendOobCode', { requestType: 'PASSWORD_RESET', email });
    } catch (error) {
      if (!(error instanceof AccountDeletionRequestError) || error.code !== 'invalid-credentials') {
        throw error;
      }
    }
  }

  return { requestDeletion, requestPasswordReset };
}
