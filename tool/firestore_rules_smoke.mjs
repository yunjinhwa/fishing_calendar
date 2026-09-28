const projectId = process.env.GCLOUD_PROJECT ?? 'fishingbuild';
const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST;
const firestoreHost = process.env.FIRESTORE_EMULATOR_HOST;

if (!authHost || !firestoreHost) {
  throw new Error(
    'Run this script through Firebase emulators:exec with auth and firestore.',
  );
}

const authBase = `http://${authHost}/identitytoolkit.googleapis.com/v1`;
const firestoreBase =
  `http://${firestoreHost}/v1/projects/${projectId}/databases/(default)/documents`;
const runId = Date.now();

async function createUser(label) {
  const response = await fetch(`${authBase}/accounts:signUp?key=fake-api-key`, {
    method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify({
      email: `${label}-${runId}@example.com`,
      password: 'Password1',
      returnSecureToken: true,
    }),
  });
  const body = await response.json();
  if (!response.ok) {
    throw new Error(`Auth signup failed (${response.status}): ${JSON.stringify(body)}`);
  }
  return {uid: body.localId, token: body.idToken};
}

function authHeaders(token) {
  return {
    authorization: `Bearer ${token}`,
    'content-type': 'application/json',
  };
}

async function request(path, {token, method = 'GET', body} = {}) {
  return fetch(`${firestoreBase}${path}`, {
    method,
    headers: authHeaders(token),
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

function stringValue(value) {
  return {stringValue: value};
}

function integerValue(value) {
  return {integerValue: String(value)};
}

function timestampValue(value) {
  return {timestampValue: value};
}

function recordFields(
  uid,
  recordId,
  outboxId = 'rules-create',
  overrides = {},
) {
  return {
    schemaVersion: integerValue(1),
    ownerUid: stringValue(uid),
    recordId: stringValue(recordId),
    recordStatus: stringValue('ACTIVE'),
    location: stringValue('규칙 테스트 방파제'),
    startAt: timestampValue('2026-09-22T00:00:00Z'),
    endAt: timestampValue('2026-09-22T02:00:00Z'),
    genreName: stringValue('바다낚시'),
    tide: {nullValue: null},
    weather: stringValue('맑음'),
    airTemperature: {doubleValue: 24.5},
    waterTemperature: {doubleValue: 20.5},
    catches: {
      arrayValue: {
        values: [
          {
            mapValue: {
              fields: {
                speciesName: stringValue('우럭'),
                lengthCm: {doubleValue: 31.2},
                weightG: integerValue(820),
              },
            },
          },
        ],
      },
    },
    memo: stringValue('Firestore 규칙 smoke test'),
    photoUploadPending: {booleanValue: false},
    versionNo: integerValue(1),
    clientModifiedAt: timestampValue('2026-09-22T00:00:00Z'),
    lastOutboxId: stringValue(outboxId),
    ...overrides,
  };
}

function receiptFields(uid, outboxId, recordId, operationType, versionNo) {
  return {
    ownerUid: stringValue(uid),
    outboxId: stringValue(outboxId),
    recordId: stringValue(recordId),
    operationType: stringValue(operationType),
    resultingVersionNo: integerValue(versionNo),
  };
}

function createCommit(
  uid,
  recordId,
  outboxId = 'rules-create',
  recordOverrides = {},
) {
  const recordName =
    `projects/${projectId}/databases/(default)/documents/users/${uid}/records/${recordId}`;
  const receiptName =
    `projects/${projectId}/databases/(default)/documents/users/${uid}/sync_receipts/${outboxId}`;
  return {
    writes: [
      {
        update: {
          name: recordName,
          fields: recordFields(uid, recordId, outboxId, recordOverrides),
        },
        updateTransforms: [
          {fieldPath: 'createdAt', setToServerValue: 'REQUEST_TIME'},
          {fieldPath: 'serverUpdatedAt', setToServerValue: 'REQUEST_TIME'},
        ],
      },
      {
        update: {
          name: receiptName,
          fields: receiptFields(uid, outboxId, recordId, 'create', 1),
        },
        updateTransforms: [
          {fieldPath: 'processedAt', setToServerValue: 'REQUEST_TIME'},
        ],
      },
    ],
  };
}

function recordOnlyCommit(uid, recordId) {
  const recordName =
    `projects/${projectId}/databases/(default)/documents/users/${uid}/records/${recordId}`;
  return {
    writes: [
      {
        update: {
          name: recordName,
          fields: recordFields(uid, recordId, 'record-only-outbox'),
        },
        updateTransforms: [
          {fieldPath: 'createdAt', setToServerValue: 'REQUEST_TIME'},
          {fieldPath: 'serverUpdatedAt', setToServerValue: 'REQUEST_TIME'},
        ],
      },
    ],
  };
}

function receiptOnlyCommit(uid, recordId) {
  const receiptName =
    `projects/${projectId}/databases/(default)/documents/users/${uid}/sync_receipts/receipt-only-outbox`;
  return {
    writes: [
      {
        update: {
          name: receiptName,
          fields: receiptFields(
            uid,
            'receipt-only-outbox',
            recordId,
            'create',
            1,
          ),
        },
        updateTransforms: [
          {fieldPath: 'processedAt', setToServerValue: 'REQUEST_TIME'},
        ],
      },
    ],
  };
}

function tombstoneCommit(uid, recordId, createdAt) {
  const recordName =
    `projects/${projectId}/databases/(default)/documents/users/${uid}/records/${recordId}`;
  const receiptName =
    `projects/${projectId}/databases/(default)/documents/users/${uid}/sync_receipts/rules-delete`;
  return {
    writes: [
      {
        update: {
          name: recordName,
          fields: {
            schemaVersion: integerValue(1),
            ownerUid: stringValue(uid),
            recordId: stringValue(recordId),
            recordStatus: stringValue('DELETED'),
            versionNo: integerValue(2),
            clientModifiedAt: timestampValue('2026-09-22T03:00:00Z'),
            createdAt,
            lastOutboxId: stringValue('rules-delete'),
          },
        },
        updateTransforms: [
          {fieldPath: 'serverUpdatedAt', setToServerValue: 'REQUEST_TIME'},
        ],
      },
      {
        update: {
          name: receiptName,
          fields: receiptFields(uid, 'rules-delete', recordId, 'delete', 2),
        },
        updateTransforms: [
          {fieldPath: 'processedAt', setToServerValue: 'REQUEST_TIME'},
        ],
      },
    ],
  };
}

async function expectStatus(label, response, expectedStatus) {
  if (response.status !== expectedStatus) {
    const body = await response.text();
    throw new Error(
      `${label}: expected ${expectedStatus}, received ${response.status}: ${body}`,
    );
  }
}

const owner = await createUser('owner');
const intruder = await createUser('intruder');
const recordId = 'rules-record';

await expectStatus(
  'record without matching receipt denied',
  await request(':commit', {
    token: owner.token,
    method: 'POST',
    body: recordOnlyCommit(owner.uid, 'record-without-receipt'),
  }),
  403,
);

await expectStatus(
  'receipt without matching record denied',
  await request(':commit', {
    token: owner.token,
    method: 'POST',
    body: receiptOnlyCommit(owner.uid, 'record-without-receipt'),
  }),
  403,
);

await expectStatus(
  'owner atomic create',
  await request(':commit', {
    token: owner.token,
    method: 'POST',
    body: createCommit(owner.uid, recordId),
  }),
  200,
);

await expectStatus(
  '200 character Korean location accepted',
  await request(':commit', {
    token: owner.token,
    method: 'POST',
    body: createCommit(
      owner.uid,
      'location-boundary-valid',
      'location-boundary-valid',
      {location: stringValue('가'.repeat(200))},
    ),
  }),
  200,
);

await expectStatus(
  '201 character Korean location denied',
  await request(':commit', {
    token: owner.token,
    method: 'POST',
    body: createCommit(
      owner.uid,
      'location-boundary-invalid',
      'location-boundary-invalid',
      {location: stringValue('가'.repeat(201))},
    ),
  }),
  403,
);

const ownerRead = await request(`/users/${owner.uid}/records/${recordId}`, {
  token: owner.token,
});
await expectStatus('owner get', ownerRead, 200);
const ownerDocument = await ownerRead.json();

await expectStatus(
  'intruder get denied',
  await request(`/users/${owner.uid}/records/${recordId}`, {
    token: intruder.token,
  }),
  403,
);

await expectStatus(
  'intruder list denied',
  await request(`/users/${owner.uid}/records`, {token: intruder.token}),
  403,
);

await expectStatus(
  'intruder write denied',
  await request(':commit', {
    token: intruder.token,
    method: 'POST',
    body: createCommit(owner.uid, 'intruder-record'),
  }),
  403,
);

await expectStatus(
  'hard delete denied',
  await request(`/users/${owner.uid}/records/${recordId}`, {
    token: owner.token,
    method: 'DELETE',
  }),
  403,
);

await expectStatus(
  'owner tombstone and receipt update',
  await request(':commit', {
    token: owner.token,
    method: 'POST',
    body: tombstoneCommit(
      owner.uid,
      recordId,
      ownerDocument.fields.createdAt,
    ),
  }),
  200,
);

console.log('Firestore rules smoke test passed.');
