const projectId = process.env.GCLOUD_PROJECT ?? '';
const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST;
const firestoreHost = process.env.FIRESTORE_EMULATOR_HOST;

function requireLocalHost(value, label) {
  const host = value && new URL(`http://${value}`).hostname;
  if (!['localhost', '127.0.0.1', '[::1]'].includes(host)) {
    throw new Error(`${label} must point to a local emulator.`);
  }
}

if (!projectId.startsWith('demo-')) {
  throw new Error('Use a demo- project through Firebase emulators:exec.');
}
requireLocalHost(authHost, 'FIREBASE_AUTH_EMULATOR_HOST');
requireLocalHost(firestoreHost, 'FIRESTORE_EMULATOR_HOST');

const authBase = `http://${authHost}/identitytoolkit.googleapis.com/v1`;
const firestoreBase =
  `http://${firestoreHost}/v1/projects/${projectId}/databases/(default)/documents`;
const documentBase = `projects/${projectId}/databases/(default)/documents`;
const runId = Date.now();
let passed = 0;

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
  if (!response.ok) throw new Error(`Auth signup failed: ${JSON.stringify(body)}`);
  return {uid: body.localId, token: body.idToken};
}

async function request(path, {token, method = 'GET', body} = {}) {
  return fetch(`${firestoreBase}${path}`, {
    method,
    headers: {
      ...(token ? {authorization: `Bearer ${token}`} : {}),
      'content-type': 'application/json',
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function expectStatus(label, response, status) {
  if (response.status !== status) {
    throw new Error(
      `${label}: expected ${status}, got ${response.status}: ${await response.text()}`,
    );
  }
  passed++;
  return response;
}

async function commit(label, member, writes, status = 200) {
  return expectStatus(label, await request(':commit', {
    token: member.token,
    method: 'POST',
    body: {writes},
  }), status);
}

function fields(uid, nickname) {
  return {
    uid: {stringValue: uid},
    nickname: {stringValue: nickname},
    nicknameKey: {stringValue: nickname.trim().toLowerCase()},
  };
}

function document(collection, id) {
  return `${documentBase}/${collection}/${id}`;
}

function profileWrites(uid, nickname, {
  oldNickname,
  deleteOld = true,
  includeProfile = true,
  includeClaim = true,
  claimNickname = nickname,
} = {}) {
  const key = nickname.trim().toLowerCase();
  const result = [];
  if (includeProfile) {
    result.push({update: {
      name: document('user_profiles', uid),
      fields: fields(uid, nickname),
    }});
  }
  if (includeClaim) {
    result.push({update: {
      name: document('nickname_claims', key),
      fields: fields(uid, claimNickname),
    }});
  }
  if (oldNickname && deleteOld && oldNickname.toLowerCase() !== key) {
    result.push({delete: document('nickname_claims', oldNickname.toLowerCase())});
  }
  return result;
}

function deleteProfileWrites(uid, nickname) {
  return [
    {delete: document('user_profiles', uid)},
    {delete: document('nickname_claims', nickname.toLowerCase())},
  ];
}

async function expectProfile(member, nickname) {
  const response = await expectStatus('profile readback', await request(
    `/user_profiles/${member.uid}`, {token: member.token},
  ), 200);
  const actual = (await response.json()).fields;
  if (actual.nickname.stringValue !== nickname ||
      actual.nicknameKey.stringValue !== nickname.toLowerCase()) {
    throw new Error('The original profile was changed by a rejected write.');
  }
}

async function expectClaim(member, nickname, ownerUid = member.uid) {
  const response = await expectStatus('claim readback', await request(
    `/nickname_claims/${nickname.toLowerCase()}`, {token: member.token},
  ), 200);
  const actual = (await response.json()).fields;
  if (actual.uid.stringValue !== ownerUid || actual.nickname.stringValue !== nickname) {
    throw new Error('Nickname ownership or display value does not match.');
  }
}

async function expectClaimAbsent(member, nickname) {
  await expectStatus('released claim is absent', await request(
    `/nickname_claims/${nickname.toLowerCase()}`, {token: member.token},
  ), 404);
}

const first = await createUser('profile-first');
const second = await createUser('profile-second');
const third = await createUser('profile-third');
const oldName = `Old_${runId}`;
const newName = `New_${runId}`;
const reservedName = `Held_${runId}`;
const spareName = `Spare_${runId}`;

await commit('registration creates one matching profile and claim', first,
  profileWrites(first.uid, oldName));
await commit('a second member reserves their own nickname', second,
  profileWrites(second.uid, reservedName));
await commit('profile without a claim is denied', third,
  profileWrites(third.uid, spareName, {includeClaim: false}), 403);
await commit('orphan claim is denied', third,
  profileWrites(third.uid, spareName, {includeProfile: false}), 403);
await commit('another uid cannot rename the first member', second,
  profileWrites(first.uid, newName, {oldNickname: oldName}), 403);
await commit('profile-only rename is denied', first,
  profileWrites(first.uid, newName, {includeClaim: false}), 403);
await commit('new claim without switching the profile is denied', first,
  profileWrites(first.uid, newName, {includeProfile: false}), 403);
await commit('releasing the active claim alone is denied', first,
  [{delete: document('nickname_claims', oldName.toLowerCase())}], 403);
await commit('switching without releasing the old claim is denied', first,
  profileWrites(first.uid, newName, {deleteOld: false}), 403);
await commit('a claimed nickname cannot be stolen', first,
  profileWrites(first.uid, reservedName, {oldNickname: oldName}), 403);
await commit('profile and claim must use the same display value', first,
  profileWrites(first.uid, newName, {
    oldNickname: oldName,
    claimNickname: newName.toLowerCase(),
  }), 403);
await expectProfile(first, oldName);
await expectClaim(first, oldName);
await expectClaim(second, reservedName);
await expectClaimAbsent(first, newName);

await commit('atomic rename switches both documents and releases the old claim', first,
  profileWrites(first.uid, newName, {oldNickname: oldName}));
await expectProfile(first, newName);
await expectClaim(first, newName);
await expectClaimAbsent(first, oldName);
await commit('another member can reuse the released nickname', second,
  profileWrites(second.uid, oldName, {oldNickname: reservedName}));
await expectProfile(second, oldName);
await expectClaimAbsent(second, reservedName);

const upperName = newName.toUpperCase();
await commit('same canonical key permits a matching case-only display change', first,
  profileWrites(first.uid, upperName));
await expectProfile(first, upperName);
await expectClaim(first, upperName);
await commit('case-only profile write without its claim is denied', first,
  profileWrites(first.uid, newName, {includeClaim: false}), 403);
await commit('case-only claim write without its profile is denied', first,
  profileWrites(first.uid, newName, {includeProfile: false}), 403);
await expectProfile(first, upperName);
await expectClaim(first, upperName);

await expectStatus('other uid profile read is denied', await request(
  `/user_profiles/${first.uid}`, {token: second.token},
), 403);
await expectStatus('profile listing is denied', await request(
  '/user_profiles', {token: first.token},
), 403);
await expectStatus('claim listing is denied', await request(
  '/nickname_claims', {token: first.token},
), 403);
await expectStatus('unauthenticated claim read is denied', await request(
  `/nickname_claims/${upperName.toLowerCase()}`,
), 403);
await commit('invalid nickname characters are denied', third,
  profileWrites(third.uid, 'invalid!'), 403);
await commit('nickname surrounding whitespace is denied', third,
  profileWrites(third.uid, ' padded '), 403);

await commit('request account deletion', first, [{
  update: {
    name: document('account_deletion_requests', first.uid),
    fields: {
      schemaVersion: {integerValue: '1'},
      uid: {stringValue: first.uid},
      status: {stringValue: 'REQUESTED'},
    },
  },
  updateTransforms: [{fieldPath: 'requestedAt', setToServerValue: 'REQUEST_TIME'}],
}]);
await commit('deletion lock rejects renaming', first,
  profileWrites(first.uid, spareName, {oldNickname: upperName}), 403);
await commit('deletion lock rejects case-only changes', first,
  profileWrites(first.uid, newName), 403);
await commit('deletion cleanup may release profile and claim atomically', first,
  deleteProfileWrites(first.uid, upperName));
await expectClaimAbsent(first, upperName);
await expectStatus('deleted profile is absent', await request(
  `/user_profiles/${first.uid}`, {token: first.token},
), 404);
await commit('a released deleted-account nickname can be reused', third,
  profileWrites(third.uid, newName));
await commit('registration rollback can release both documents without a tombstone', third,
  deleteProfileWrites(third.uid, newName));
await expectClaimAbsent(third, newName);

const racerA = await createUser('profile-racer-a');
const racerB = await createUser('profile-racer-b');
const racerAName = `RaceA_${runId}`;
const racerBName = `RaceB_${runId}`;
const raceName = `Race_${runId}`;
await commit('seed first racing profile', racerA,
  profileWrites(racerA.uid, racerAName));
await commit('seed second racing profile', racerB,
  profileWrites(racerB.uid, racerBName));
const racing = await Promise.all([
  request(':commit', {token: racerA.token, method: 'POST', body: {writes:
    profileWrites(racerA.uid, raceName, {oldNickname: racerAName})}}),
  request(':commit', {token: racerB.token, method: 'POST', body: {writes:
    profileWrites(racerB.uid, raceName, {oldNickname: racerBName})}}),
]);
const statuses = racing.map((response) => response.status).sort();
if (statuses[0] !== 200 || statuses[1] !== 403) {
  throw new Error(`Concurrent nickname requests must have one winner: ${statuses}`);
}
passed += 2;
const firstWon = racing[0].status === 200;
const winner = firstWon ? racerA : racerB;
const loser = firstWon ? racerB : racerA;
const loserName = firstWon ? racerBName : racerAName;
await expectClaim(winner, raceName);
await expectProfile(loser, loserName);
await expectClaim(loser, loserName);

console.log(`Profile nickname rules smoke passed (${passed} status checks).`);
