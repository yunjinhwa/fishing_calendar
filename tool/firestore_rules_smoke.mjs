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
const fingerprint = 'a'.repeat(64);

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
    throw new Error(
      `Auth signup failed (${response.status}): ${JSON.stringify(body)}`,
    );
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

function activeRecordFields({
  uid,
  recordId,
  outboxId,
  versionNo,
  createdAt,
  location = '규칙 테스트 방파제',
}) {
  return {
    schemaVersion: integerValue(1),
    ownerUid: stringValue(uid),
    recordId: stringValue(recordId),
    recordStatus: stringValue('ACTIVE'),
    location: stringValue(location),
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
    versionNo: integerValue(versionNo),
    clientModifiedAt: timestampValue('2026-09-22T00:00:00Z'),
    ...(createdAt === undefined ? {} : {createdAt}),
    lastOutboxId: stringValue(outboxId),
  };
}

function deletedRecordFields({
  uid,
  recordId,
  outboxId,
  versionNo,
  createdAt,
}) {
  return {
    schemaVersion: integerValue(1),
    ownerUid: stringValue(uid),
    recordId: stringValue(recordId),
    recordStatus: stringValue('DELETED'),
    versionNo: integerValue(versionNo),
    clientModifiedAt: timestampValue('2026-09-22T03:00:00Z'),
    createdAt,
    lastOutboxId: stringValue(outboxId),
  };
}

function receiptFields({
  uid,
  outboxId,
  recordId,
  operationType,
  baseVersionNo,
  resultingVersionNo,
  mutationFingerprint = fingerprint,
  legacy = false,
}) {
  if (legacy) {
    return {
      ownerUid: stringValue(uid),
      outboxId: stringValue(outboxId),
      recordId: stringValue(recordId),
      operationType: stringValue(operationType),
      resultingVersionNo: integerValue(resultingVersionNo),
    };
  }
  return {
    schemaVersion: integerValue(2),
    ownerUid: stringValue(uid),
    outboxId: stringValue(outboxId),
    recordId: stringValue(recordId),
    operationType: stringValue(operationType),
    baseVersionNo: integerValue(baseVersionNo),
    resultingVersionNo: integerValue(resultingVersionNo),
    mutationFingerprint: stringValue(mutationFingerprint),
  };
}

function mutationCommit({
  uid,
  recordId,
  outboxId,
  operationType,
  baseVersionNo,
  resultingVersionNo,
  createdAt,
  recordStatus = 'ACTIVE',
  location,
  includeRecord = true,
  includeReceipt = true,
  mutationFingerprint,
  legacyReceipt = false,
}) {
  const recordName =
    `projects/${projectId}/databases/(default)/documents/users/${uid}/records/${recordId}`;
  const receiptName =
    `projects/${projectId}/databases/(default)/documents/users/${uid}/sync_receipts/${outboxId}`;
  const fields = recordStatus === 'DELETED'
    ? deletedRecordFields({
        uid,
        recordId,
        outboxId,
        versionNo: resultingVersionNo,
        createdAt,
      })
    : activeRecordFields({
        uid,
        recordId,
        outboxId,
        versionNo: resultingVersionNo,
        createdAt,
        location,
      });
  const writes = [];
  if (includeRecord) {
    writes.push({
      update: {name: recordName, fields},
      updateTransforms: [
        ...(createdAt === undefined
          ? [{fieldPath: 'createdAt', setToServerValue: 'REQUEST_TIME'}]
          : []),
        {fieldPath: 'serverUpdatedAt', setToServerValue: 'REQUEST_TIME'},
      ],
    });
  }
  if (includeReceipt) {
    writes.push({
      update: {
        name: receiptName,
        fields: receiptFields({
          uid,
          outboxId,
          recordId,
          operationType,
          baseVersionNo,
          resultingVersionNo,
          mutationFingerprint,
          legacy: legacyReceipt,
        }),
      },
      updateTransforms: [
        {fieldPath: 'processedAt', setToServerValue: 'REQUEST_TIME'},
      ],
    });
  }
  return {writes};
}

async function expectStatus(label, response, expectedStatus) {
  if (response.status !== expectedStatus) {
    const body = await response.text();
    throw new Error(
      `${label}: expected ${expectedStatus}, received ${response.status}: ${body}`,
    );
  }
}

async function commit(label, token, body, expectedStatus) {
  await expectStatus(
    label,
    await request(':commit', {token, method: 'POST', body}),
    expectedStatus,
  );
}

const owner = await createUser('owner');
const intruder = await createUser('intruder');
const recordId = 'rules-record';

await commit(
  'record without matching receipt denied',
  owner.token,
  mutationCommit({
    uid: owner.uid,
    recordId: 'record-without-receipt',
    outboxId: 'record-only',
    operationType: 'create',
    baseVersionNo: 0,
    resultingVersionNo: 1,
    includeReceipt: false,
  }),
  403,
);

await commit(
  'receipt without matching record denied',
  owner.token,
  mutationCommit({
    uid: owner.uid,
    recordId: 'receipt-without-record',
    outboxId: 'receipt-only',
    operationType: 'create',
    baseVersionNo: 0,
    resultingVersionNo: 1,
    includeRecord: false,
  }),
  403,
);

await commit(
  'update operation cannot create a record',
  owner.token,
  mutationCommit({
    uid: owner.uid,
    recordId: 'wrong-create-operation',
    outboxId: 'wrong-create-operation',
    operationType: 'update',
    baseVersionNo: 0,
    resultingVersionNo: 1,
  }),
  403,
);

await commit(
  'resulting version must equal base plus one',
  owner.token,
  mutationCommit({
    uid: owner.uid,
    recordId: 'bad-result-version',
    outboxId: 'bad-result-version',
    operationType: 'create',
    baseVersionNo: 0,
    resultingVersionNo: 2,
  }),
  403,
);

await commit(
  'fingerprint must be a sha256 hex string',
  owner.token,
  mutationCommit({
    uid: owner.uid,
    recordId: 'bad-fingerprint',
    outboxId: 'bad-fingerprint',
    operationType: 'create',
    baseVersionNo: 0,
    resultingVersionNo: 1,
    mutationFingerprint: 'invalid',
  }),
  403,
);

await commit(
  'owner atomic create',
  owner.token,
  mutationCommit({
    uid: owner.uid,
    recordId,
    outboxId: 'rules-create',
    operationType: 'create',
    baseVersionNo: 0,
    resultingVersionNo: 1,
  }),
  200,
);

await commit(
  'legacy v1 receipt remains writable during app rollout',
  owner.token,
  mutationCommit({
    uid: owner.uid,
    recordId: 'legacy-receipt-create',
    outboxId: 'legacy-receipt-create',
    operationType: 'create',
    baseVersionNo: 0,
    resultingVersionNo: 1,
    legacyReceipt: true,
  }),
  200,
);

await commit(
  '200 character Korean location accepted',
  owner.token,
  mutationCommit({
    uid: owner.uid,
    recordId: 'location-boundary-valid',
    outboxId: 'location-boundary-valid',
    operationType: 'create',
    baseVersionNo: 0,
    resultingVersionNo: 1,
    location: '가'.repeat(200),
  }),
  200,
);

await commit(
  '201 character Korean location denied',
  owner.token,
  mutationCommit({
    uid: owner.uid,
    recordId: 'location-boundary-invalid',
    outboxId: 'location-boundary-invalid',
    operationType: 'create',
    baseVersionNo: 0,
    resultingVersionNo: 1,
    location: '가'.repeat(201),
  }),
  403,
);

let ownerRead = await request(`/users/${owner.uid}/records/${recordId}`, {
  token: owner.token,
});
await expectStatus('owner get', ownerRead, 200);
let ownerDocument = await ownerRead.json();
const createdAt = ownerDocument.fields.createdAt;

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
await commit(
  'intruder write denied',
  intruder.token,
  mutationCommit({
    uid: owner.uid,
    recordId: 'intruder-record',
    outboxId: 'intruder-record',
    operationType: 'create',
    baseVersionNo: 0,
    resultingVersionNo: 1,
  }),
  403,
);

await commit(
  'valid update from current base',
  owner.token,
  mutationCommit({
    uid: owner.uid,
    recordId,
    outboxId: 'rules-update',
    operationType: 'update',
    baseVersionNo: 1,
    resultingVersionNo: 2,
    createdAt,
    location: '수정된 방파제',
  }),
  200,
);

await commit(
  'stale update denied',
  owner.token,
  mutationCommit({
    uid: owner.uid,
    recordId,
    outboxId: 'rules-stale-update',
    operationType: 'update',
    baseVersionNo: 1,
    resultingVersionNo: 2,
    createdAt,
    location: '오래된 변경',
  }),
  403,
);

await commit(
  'create operation cannot update a record',
  owner.token,
  mutationCommit({
    uid: owner.uid,
    recordId,
    outboxId: 'rules-wrong-update-operation',
    operationType: 'create',
    baseVersionNo: 2,
    resultingVersionNo: 3,
    createdAt,
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

await commit(
  'valid tombstone from current base',
  owner.token,
  mutationCommit({
    uid: owner.uid,
    recordId,
    outboxId: 'rules-delete',
    operationType: 'delete',
    baseVersionNo: 2,
    resultingVersionNo: 3,
    createdAt,
    recordStatus: 'DELETED',
  }),
  200,
);

await commit(
  'stale delete denied',
  owner.token,
  mutationCommit({
    uid: owner.uid,
    recordId,
    outboxId: 'rules-stale-delete',
    operationType: 'delete',
    baseVersionNo: 2,
    resultingVersionNo: 3,
    createdAt,
    recordStatus: 'DELETED',
  }),
  403,
);

await commit(
  'valid update can restore a tombstone',
  owner.token,
  mutationCommit({
    uid: owner.uid,
    recordId,
    outboxId: 'rules-restore',
    operationType: 'update',
    baseVersionNo: 3,
    resultingVersionNo: 4,
    createdAt,
    location: '복원된 방파제',
  }),
  200,
);

console.log('Firestore rules smoke test passed.');
