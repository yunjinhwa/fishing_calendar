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

async function adminRequest(path, {method = 'GET', body} = {}) {
  return fetch(`${firestoreBase}${path}`, {
    method,
    headers: {
      authorization: 'Bearer owner',
      'content-type': 'application/json',
    },
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

function nullValue() {
  return {nullValue: null};
}

function entitlementFields({planType, status, expiresAt}) {
  return {
    planType: stringValue(planType),
    status: stringValue(status),
    ...(expiresAt === undefined
      ? {}
      : {expiresAt: expiresAt === null ? nullValue() : timestampValue(expiresAt)}),
  };
}

async function seedEntitlement(
  uid,
  {planType = 'PAID', status = 'ACTIVE', expiresAt} = {},
) {
  await expectStatus(
    `seed entitlement for ${uid}`,
    await adminRequest(`/plan_entitlements/${uid}`, {
      method: 'PATCH',
      body: {fields: entitlementFields({planType, status, expiresAt})},
    }),
    200,
  );
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

function accountDeletionRequestCommit({
  documentUid,
  claimedUid = documentUid,
  schemaVersion = 1,
  status = 'REQUESTED',
  extraFields = {},
}) {
  const name =
    `projects/${projectId}/databases/(default)/documents/account_deletion_requests/${documentUid}`;
  return {
    writes: [
      {
        update: {
          name,
          fields: {
            schemaVersion: integerValue(schemaVersion),
            uid: stringValue(claimedUid),
            status: stringValue(status),
            ...extraFields,
          },
        },
        updateTransforms: [
          {fieldPath: 'requestedAt', setToServerValue: 'REQUEST_TIME'},
        ],
      },
    ],
  };
}

async function listAllDocuments(label, path, token, pageSize = 10) {
  const documents = [];
  let pageToken;
  do {
    const query = new URLSearchParams({pageSize: String(pageSize)});
    if (pageToken) {
      query.set('pageToken', pageToken);
    }
    const response = await request(`${path}?${query}`, {token});
    await expectStatus(label, response, 200);
    const body = await response.json();
    documents.push(...(body.documents ?? []));
    pageToken = body.nextPageToken;
  } while (pageToken);
  return documents;
}

function hardDeleteCommit(documents) {
  return {
    writes: documents.map((document) => ({delete: document.name})),
  };
}

async function hardDeleteInBatches(label, token, documents, batchSize = 15) {
  for (let index = 0; index < documents.length; index += batchSize) {
    await commit(
      `${label} batch ${Math.floor(index / batchSize) + 1}`,
      token,
      hardDeleteCommit(documents.slice(index, index + batchSize)),
      200,
    );
  }
}

const owner = await createUser('owner');
const intruder = await createUser('intruder');
const freeMember = await createUser('free-member');
const expiredMember = await createUser('expired-member');
const inactiveMember = await createUser('inactive-member');
const nullExpiryMember = await createUser('null-expiry-member');
const futureExpiryMember = await createUser('future-expiry-member');
const recordId = 'rules-record';

await seedEntitlement(owner.uid);
await seedEntitlement(freeMember.uid, {planType: 'FREE'});
await seedEntitlement(expiredMember.uid, {
  expiresAt: '2000-01-01T00:00:00Z',
});
await seedEntitlement(inactiveMember.uid, {status: 'EXPIRED'});
await seedEntitlement(nullExpiryMember.uid, {expiresAt: null});
await seedEntitlement(futureExpiryMember.uid, {
  expiresAt: '2099-01-01T00:00:00Z',
});

await expectStatus(
  'owner can read own entitlement',
  await request(`/plan_entitlements/${owner.uid}`, {token: owner.token}),
  200,
);
await expectStatus(
  'another member cannot read owner entitlement',
  await request(`/plan_entitlements/${owner.uid}`, {token: intruder.token}),
  403,
);
await expectStatus(
  'entitlement list is denied',
  await request('/plan_entitlements', {token: owner.token}),
  403,
);
await expectStatus(
  'member cannot create own entitlement',
  await request(`/plan_entitlements/${intruder.uid}`, {
    token: intruder.token,
    method: 'PATCH',
    body: {
      fields: entitlementFields({planType: 'PAID', status: 'ACTIVE'}),
    },
  }),
  403,
);
await expectStatus(
  'member cannot update own entitlement',
  await request(`/plan_entitlements/${owner.uid}`, {
    token: owner.token,
    method: 'PATCH',
    body: {
      fields: entitlementFields({planType: 'FREE', status: 'ACTIVE'}),
    },
  }),
  403,
);
await expectStatus(
  'member cannot delete own entitlement',
  await request(`/plan_entitlements/${owner.uid}`, {
    token: owner.token,
    method: 'DELETE',
  }),
  403,
);

for (const [label, member] of [
  ['missing entitlement', intruder],
  ['free entitlement', freeMember],
  ['expired entitlement', expiredMember],
  ['inactive entitlement', inactiveMember],
]) {
  await expectStatus(
    `${label} record read denied`,
    await request(`/users/${member.uid}/records/blocked-record`, {
      token: member.token,
    }),
    403,
  );
  await expectStatus(
    `${label} receipt read denied`,
    await request(`/users/${member.uid}/sync_receipts/blocked-record`, {
      token: member.token,
    }),
    403,
  );
  await commit(
    `${label} record write denied`,
    member.token,
    mutationCommit({
      uid: member.uid,
      recordId: 'blocked-record',
      outboxId: 'blocked-record',
      operationType: 'create',
      baseVersionNo: 0,
      resultingVersionNo: 1,
    }),
    403,
  );
}

for (const [label, member] of [
  ['null expiry entitlement', nullExpiryMember],
  ['future expiry entitlement', futureExpiryMember],
]) {
  await commit(
    `${label} record write allowed`,
    member.token,
    mutationCommit({
      uid: member.uid,
      recordId: 'allowed-record',
      outboxId: 'allowed-record',
      operationType: 'create',
      baseVersionNo: 0,
      resultingVersionNo: 1,
    }),
    200,
  );
  await expectStatus(
    `${label} record read allowed`,
    await request(`/users/${member.uid}/records/allowed-record`, {
      token: member.token,
    }),
    200,
  );
}

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
  'owner receipt get',
  await request(`/users/${owner.uid}/sync_receipts/rules-create`, {
    token: owner.token,
  }),
  200,
);

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

const deletionMember = await createUser('deletion-member');
await seedEntitlement(deletionMember.uid);

await commit(
  'deletion marker with an invalid status is denied',
  deletionMember.token,
  accountDeletionRequestCommit({
    documentUid: deletionMember.uid,
    status: 'CANCELLED',
  }),
  403,
);
await commit(
  'deletion marker with an extra field is denied',
  deletionMember.token,
  accountDeletionRequestCommit({
    documentUid: deletionMember.uid,
    extraFields: {reason: stringValue('not allowed')},
  }),
  403,
);
await commit(
  'member cannot create a deletion marker for another uid',
  deletionMember.token,
  accountDeletionRequestCommit({
    documentUid: intruder.uid,
    claimedUid: deletionMember.uid,
  }),
  403,
);
await commit(
  'member cannot spoof the uid in their deletion marker',
  deletionMember.token,
  accountDeletionRequestCommit({
    documentUid: deletionMember.uid,
    claimedUid: intruder.uid,
  }),
  403,
);

await commit(
  'deletion member can create a record before requesting deletion',
  deletionMember.token,
  mutationCommit({
    uid: deletionMember.uid,
    recordId: 'deletion-record-00',
    outboxId: 'deletion-receipt-00',
    operationType: 'create',
    baseVersionNo: 0,
    resultingVersionNo: 1,
  }),
  200,
);

const deletionSeedWrites = [];
for (let index = 1; index < 25; index += 1) {
  const suffix = String(index).padStart(2, '0');
  deletionSeedWrites.push(
    ...mutationCommit({
      uid: deletionMember.uid,
      recordId: `deletion-record-${suffix}`,
      outboxId: `deletion-receipt-${suffix}`,
      operationType: 'create',
      baseVersionNo: 0,
      resultingVersionNo: 1,
    }).writes,
  );
}
await expectStatus(
  'seed more than twenty records and receipts for deletion pagination',
  await adminRequest(':commit', {
    method: 'POST',
    body: {writes: deletionSeedWrites},
  }),
  200,
);

await commit(
  'member can create their own valid deletion marker',
  deletionMember.token,
  accountDeletionRequestCommit({documentUid: deletionMember.uid}),
  200,
);
await expectStatus(
  'member can read their own deletion marker',
  await request(`/account_deletion_requests/${deletionMember.uid}`, {
    token: deletionMember.token,
  }),
  200,
);
await expectStatus(
  'another member cannot read a deletion marker',
  await request(`/account_deletion_requests/${deletionMember.uid}`, {
    token: intruder.token,
  }),
  403,
);
await commit(
  'deletion marker is immutable',
  deletionMember.token,
  accountDeletionRequestCommit({documentUid: deletionMember.uid}),
  403,
);
await expectStatus(
  'deletion marker cannot be removed by its owner',
  await request(`/account_deletion_requests/${deletionMember.uid}`, {
    token: deletionMember.token,
    method: 'DELETE',
  }),
  403,
);

await commit(
  'deletion marker blocks normal record writes',
  deletionMember.token,
  mutationCommit({
    uid: deletionMember.uid,
    recordId: 'write-after-deletion-request',
    outboxId: 'write-after-deletion-request',
    operationType: 'create',
    baseVersionNo: 0,
    resultingVersionNo: 1,
  }),
  403,
);
await expectStatus(
  'intruder cannot delete deletion member entitlement',
  await request(`/plan_entitlements/${deletionMember.uid}`, {
    token: intruder.token,
    method: 'DELETE',
  }),
  403,
);
await expectStatus(
  'deletion member can delete own entitlement',
  await request(`/plan_entitlements/${deletionMember.uid}`, {
    token: deletionMember.token,
    method: 'DELETE',
  }),
  200,
);

const deletionRecords = await listAllDocuments(
  'deletion member can page through own records',
  `/users/${deletionMember.uid}/records`,
  deletionMember.token,
);
if (deletionRecords.length !== 25) {
  throw new Error(
    `deletion record pagination: expected 25 documents, received ${deletionRecords.length}`,
  );
}
const deletionReceipts = await listAllDocuments(
  'deletion member can page through own receipts',
  `/users/${deletionMember.uid}/sync_receipts`,
  deletionMember.token,
);
if (deletionReceipts.length !== 25) {
  throw new Error(
    `deletion receipt pagination: expected 25 documents, received ${deletionReceipts.length}`,
  );
}

await expectStatus(
  'intruder cannot hard delete deletion member record',
  await request(`/users/${deletionMember.uid}/records/deletion-record-00`, {
    token: intruder.token,
    method: 'DELETE',
  }),
  403,
);
await expectStatus(
  'intruder cannot hard delete deletion member receipt',
  await request(
    `/users/${deletionMember.uid}/sync_receipts/deletion-receipt-00`,
    {token: intruder.token, method: 'DELETE'},
  ),
  403,
);
await hardDeleteInBatches(
  'deletion member can hard delete own records',
  deletionMember.token,
  deletionRecords,
);
await hardDeleteInBatches(
  'deletion member can hard delete own receipts',
  deletionMember.token,
  deletionReceipts,
);

const recordsAfterDeletion = await listAllDocuments(
  'deleted record collection remains listable',
  `/users/${deletionMember.uid}/records`,
  deletionMember.token,
);
const receiptsAfterDeletion = await listAllDocuments(
  'deleted receipt collection remains listable',
  `/users/${deletionMember.uid}/sync_receipts`,
  deletionMember.token,
);
if (recordsAfterDeletion.length !== 0 || receiptsAfterDeletion.length !== 0) {
  throw new Error('account deletion cleanup left records or receipts behind');
}

// Exercise the same ordered, timestamp-inclusive query as the Dart gateway.
// A batch gives all three documents an equal server timestamp, so using only
// timestamp startAfter would skip records at the page boundary.
const incrementalMember = await createUser('incremental-reader');
await seedEntitlement(incrementalMember.uid);
const incrementalIds = ['a', 'b', 'c'];
await commit(
  'incremental baseline batch',
  incrementalMember.token,
  {
    writes: incrementalIds.flatMap((id) => mutationCommit({
      uid: incrementalMember.uid,
      recordId: id,
      outboxId: `incremental-create-${id}`,
      operationType: 'create',
      baseVersionNo: 0,
      resultingVersionNo: 1,
    }).writes),
  },
  200,
);

const incrementalDocumentResponse = await request(
  `/users/${incrementalMember.uid}/records/a`,
  {token: incrementalMember.token},
);
await expectStatus('incremental baseline timestamp', incrementalDocumentResponse, 200);
const incrementalDocument = await incrementalDocumentResponse.json();
const incrementalTime = incrementalDocument.fields.serverUpdatedAt;
const incrementalHeadResponse = await request(
  `/users/${incrementalMember.uid}:runQuery`,
  {
    token: incrementalMember.token,
    method: 'POST',
    body: {
      structuredQuery: {
        from: [{collectionId: 'records'}],
        orderBy: [
          {field: {fieldPath: 'serverUpdatedAt'}, direction: 'DESCENDING'},
          {field: {fieldPath: '__name__'}, direction: 'DESCENDING'},
        ],
        limit: 1,
      },
    },
  },
);
await expectStatus('incremental server head query', incrementalHeadResponse, 200);
const incrementalHead = (await incrementalHeadResponse.json())
  .find((row) => row.document)?.document;
if (incrementalHead?.name.split('/').at(-1) !== 'c') {
  throw new Error('incremental head did not include the same-time highest ID');
}
await commit(
  'a later write cannot extend the captured incremental page range',
  incrementalMember.token,
  mutationCommit({
    uid: incrementalMember.uid,
    recordId: 'z-after-head',
    outboxId: 'incremental-after-head',
    operationType: 'create',
    baseVersionNo: 0,
    resultingVersionNo: 1,
  }),
  200,
);

async function incrementalQuery({after, token = incrementalMember.token} = {}) {
  const response = await request(`/users/${incrementalMember.uid}:runQuery`, {
    token,
    method: 'POST',
    body: {
      structuredQuery: {
        from: [{collectionId: 'records'}],
        orderBy: [
          {field: {fieldPath: 'serverUpdatedAt'}, direction: 'ASCENDING'},
          {field: {fieldPath: '__name__'}, direction: 'ASCENDING'},
        ],
        startAt: {
          values: after
            ? [after.fields.serverUpdatedAt, {referenceValue: after.name}]
            : [incrementalTime],
          before: after === undefined,
        },
        endAt: {
          values: [
            incrementalHead.fields.serverUpdatedAt,
            {referenceValue: incrementalHead.name},
          ],
          before: false,
        },
        limit: 2,
      },
    },
  });
  return response;
}

const incrementalFirstResponse = await incrementalQuery();
await expectStatus('incremental timestamp-inclusive first page', incrementalFirstResponse, 200);
const incrementalFirst = (await incrementalFirstResponse.json())
  .filter((row) => row.document).map((row) => row.document);
if (incrementalFirst.map((doc) => doc.name.split('/').at(-1)).join(',') !== 'a,b') {
  throw new Error('incremental first page did not preserve document ID ordering');
}
const incrementalNextResponse = await incrementalQuery({after: incrementalFirst.at(-1)});
await expectStatus('incremental tuple-exclusive next page', incrementalNextResponse, 200);
const incrementalNext = (await incrementalNextResponse.json())
  .filter((row) => row.document).map((row) => row.document);
if (incrementalNext.map((doc) => doc.name.split('/').at(-1)).join(',') !== 'c') {
  throw new Error('incremental next page lost a same-timestamp document');
}
const incrementalReplayResponse = await incrementalQuery();
await expectStatus('incremental restart replays the checkpoint bucket', incrementalReplayResponse, 200);
const incrementalReplay = (await incrementalReplayResponse.json())
  .filter((row) => row.document).map((row) => row.document);
if (incrementalReplay[0]?.name.split('/').at(-1) !== 'a') {
  throw new Error('incremental replay failed to include a lower document ID');
}
await expectStatus(
  'incremental query does not bypass ownership rules',
  await incrementalQuery({token: intruder.token}),
  403,
);

console.log('Firestore rules smoke test passed.');
