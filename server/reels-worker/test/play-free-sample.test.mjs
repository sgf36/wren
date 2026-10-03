/**
 * The free first read on Android.
 *
 * iOS keys the sample on Apple's appTransactionId. Android has no such id, so
 * it keys on the device: SHA-256 of ANDROID_ID, bound into a Play Integrity
 * token so that only Play's own copy of the app on a genuine phone can name
 * it, plus device recall where Google has enabled it. Every test here is about
 * one of three ways that goes wrong -- a second free read, a free read for a
 * caller Google never vouched for, or a free read nobody recorded.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';

import {
  BUNDLE_ID, INTEGRITY_MAX_AGE_MS, INTEGRITY_SCOPE, identify, judgeIntegrity,
  nonceBinds, verifyPlayIntegrity, writeRecall,
} from '../src/index.js';

const URL_A = 'https://www.instagram.com/reel/ABC123/';
const URL_B = 'https://www.instagram.com/reel/XYZ789/';
const NOW = 1_800_000_000_000;

async function sha(text) {
  return new Uint8Array(await webcrypto.subtle.digest(
    'SHA-256', new TextEncoder().encode(text)));
}

const b64 = (bytes) => Buffer.from(bytes).toString('base64url');

/** What the app sends as `device`: base64url SHA-256 of its ANDROID_ID. */
async function deviceOf(androidId) {
  return b64(await sha(androidId));
}

const PHONE = await deviceOf('9774d56d682e549c');
const OTHER_PHONE = await deviceOf('0123456789abcdef');

async function nonceFor(url, device = PHONE, salt = 7) {
  const raw = new Uint8Array(80);
  raw.set(await sha(url), 0);
  raw.set(Buffer.from(device, 'base64url'), 32);
  raw.fill(salt, 64);
  return b64(raw);
}

async function verdict(over = () => {}, { recall = false } = {}) {
  const base = {
    requestDetails: {
      requestPackageName: BUNDLE_ID,
      nonce: await nonceFor(URL_A),
      timestampMillis: String(NOW - 5_000),
    },
    appIntegrity: {
      appRecognitionVerdict: 'PLAY_RECOGNIZED',
      packageName: BUNDLE_ID,
    },
    accountDetails: { appLicensingVerdict: 'LICENSED' },
    deviceIntegrity: {
      deviceRecognitionVerdict: ['MEETS_DEVICE_INTEGRITY'],
      ...(recall
        ? { deviceRecall: { values: { bitFirst: false }, writeDates: {} } }
        : {}),
    },
  };
  over(base);
  return base;
}

test('a genuine first share on a genuine phone is granted, recall or not', async () => {
  // The positive control: without it every refusal below is meaningless.
  const without = await judgeIntegrity(await verdict(), URL_A, PHONE, NOW);
  assert.deepEqual(without, { recall: false },
    'device recall is a beta; its absence must not refuse the read');
  const withRecall = await judgeIntegrity(
    await verdict(() => {}, { recall: true }), URL_A, PHONE, NOW);
  assert.deepEqual(withRecall, { recall: true });
});

test('a phone device recall says has had its read is refused', async () => {
  const v = await verdict((b) => {
    b.deviceIntegrity.deviceRecall.values.bitFirst = true;
  }, { recall: true });
  assert.equal(await judgeIntegrity(v, URL_A, PHONE, NOW), null);
});

test('the device sent must be the device the token was minted for', async () => {
  // A genuine token from one phone, with another phone's hash beside it: the
  // way to mint free reads by editing the request in flight.
  assert.equal(await judgeIntegrity(await verdict(), URL_A, OTHER_PHONE, NOW), null);
  for (const bad of [undefined, '', 'short', 'x'.repeat(44), PHONE + '=']) {
    assert.equal(await judgeIntegrity(await verdict(), URL_A, bad, NOW), null,
      `must refuse device ${JSON.stringify(bad)}`);
  }
});

test('a token minted for one link cannot be spent on another', async () => {
  assert.equal(await judgeIntegrity(await verdict(), URL_B, PHONE, NOW), null);
  assert.equal(await nonceBinds(await nonceFor(URL_A), URL_A, PHONE), true);
  assert.equal(await nonceBinds(await nonceFor(URL_A), URL_B, PHONE), false);
  assert.equal(await nonceBinds(await nonceFor(URL_A), URL_A, OTHER_PHONE), false);
  assert.equal(await nonceBinds('short', URL_A, PHONE), false);
  assert.equal(await nonceBinds('', URL_A, PHONE), false);
});

test('the 2.1.4 nonce, which named no device, is refused', async () => {
  // base64url(SHA-256(link) || 16 random bytes): what 2.1.4 and 2.1.5 send.
  const raw = new Uint8Array(48);
  raw.set(await sha(URL_A), 0);
  const old = await verdict((b) => { b.requestDetails.nonce = b64(raw); });
  assert.equal(await judgeIntegrity(old, URL_A, PHONE, NOW), null);
});

test('an old token is a replay', async () => {
  const stale = await verdict((b) => {
    b.requestDetails.timestampMillis = String(NOW - INTEGRITY_MAX_AGE_MS - 1);
  });
  assert.equal(await judgeIntegrity(stale, URL_A, PHONE, NOW), null);
  const future = await verdict((b) => {
    b.requestDetails.timestampMillis = String(NOW + 120_000);
  });
  assert.equal(await judgeIntegrity(future, URL_A, PHONE, NOW), null);
});

test('not Play\'s copy, not licensed, or not a real device: refused', async () => {
  const cases = [
    (b) => { b.requestDetails.requestPackageName = 'com.example.clone'; },
    (b) => { b.appIntegrity.packageName = 'com.example.clone'; },
    (b) => { b.appIntegrity.appRecognitionVerdict = 'UNRECOGNIZED_VERSION'; },
    (b) => { b.accountDetails.appLicensingVerdict = 'UNLICENSED'; },
    (b) => { b.accountDetails.appLicensingVerdict = 'UNEVALUATED'; },
    (b) => { b.deviceIntegrity.deviceRecognitionVerdict = []; },
    (b) => { b.deviceIntegrity.deviceRecognitionVerdict = ['MEETS_VIRTUAL_INTEGRITY']; },
  ];
  for (const c of cases) {
    assert.equal(await judgeIntegrity(await verdict(c), URL_A, PHONE, NOW),
      null, String(c));
  }
});

test('FREE_REELS=0 withdraws the Android sample too', async () => {
  assert.equal(await identify({ FREE_REELS: '0' },
    { kind: 'playintegrity', token: 'x', device: PHONE }, URL_A), null);
});

test('no token, no device, or no service account is a refusal, not a crash', async () => {
  for (const auth of [
    { kind: 'playintegrity' },
    { kind: 'playintegrity', token: '' },
    { kind: 'playintegrity', token: 'x' },
    { kind: 'playintegrity', token: 'x', device: PHONE },
  ]) {
    assert.equal(await identify({}, auth, URL_A), null);
  }
});

/* ---------------------------------------------------- against a fake Google */

/**
 * Stands in for minting a Google bearer token. The real minter signs a JWT with
 * the service account's private key; nothing here needs one, and a test that
 * carried key material would be the thing CI's committed-key guard exists to
 * stop. Records the scope so a wrong one is caught.
 */
function fakeMint(scopes) {
  return async (_key, scope) => {
    scopes.push(scope);
    return 'bearer';
  };
}

function fakeGoogle(payload, calls) {
  return async (url, init) => {
    calls.push({ url: String(url), body: init?.body });
    if (String(url).endsWith(':decodeIntegrityToken')) {
      return new Response(JSON.stringify({ tokenPayloadExternal: payload }));
    }
    if (String(url).endsWith('/deviceRecall:write')) {
      return new Response('{}');
    }
    return new Response('no', { status: 404 });
  };
}

test('a granted token becomes a free identity keyed on the phone', async () => {
  const v = await verdict((b) => {
    b.requestDetails.timestampMillis = String(Date.now() - 1000);
  });
  const calls = [];
  const scopes = [];
  const who = await verifyPlayIntegrity(
    {}, 'tok', URL_A, PHONE, fakeGoogle(v, calls), fakeMint(scopes));
  assert.ok(who);
  // One per phone: a second token from the same phone lands on the same key,
  // which the lifetime quota has already counted.
  assert.equal(who.key, `free:android:${PHONE}`);
  assert.equal(who.store, 'free');
  assert.equal(who.integrityToken, null,
    'no recall in the verdict, so nothing to mark: a write would fail');
  assert.deepEqual(scopes, [INTEGRITY_SCOPE]);
  const decode = calls.find((c) => c.url.endsWith(':decodeIntegrityToken'));
  assert.ok(decode.url.includes(BUNDLE_ID));
  assert.deepEqual(JSON.parse(decode.body), { integrity_token: 'tok' });
});

test('with recall in the verdict, the token travels so the bit is marked', async () => {
  const v = await verdict((b) => {
    b.requestDetails.timestampMillis = String(Date.now() - 1000);
  }, { recall: true });
  const who = await verifyPlayIntegrity(
    {}, 'tok', URL_A, PHONE, fakeGoogle(v, []), fakeMint([]));
  assert.equal(who.key, `free:android:${PHONE}`);
  assert.equal(who.integrityToken, 'tok');
});

test('a verdict Google decoded but the judge refuses grants nothing', async () => {
  const spent = await verdict((b) => {
    b.requestDetails.timestampMillis = String(Date.now() - 1000);
    b.deviceIntegrity.deviceRecall.values.bitFirst = true;
  }, { recall: true });
  assert.equal(await verifyPlayIntegrity(
    {}, 'tok', URL_A, PHONE, fakeGoogle(spent, []), fakeMint([])), null);
});

test('no bearer token, or no device, means nothing is sent to Google', async () => {
  const calls = [];
  assert.equal(await verifyPlayIntegrity(
    {}, 'tok', URL_A, PHONE, fakeGoogle({}, calls), async () => null), null);
  assert.equal(await verifyPlayIntegrity(
    {}, 'tok', URL_A, undefined, fakeGoogle({}, calls), fakeMint([])), null);
  assert.equal(calls.length, 0, 'nothing may be sent without credentials');
});

test('writeRecall touches bitFirst and nothing else', async () => {
  const calls = [];
  const mint = fakeMint([]);
  assert.equal(await writeRecall({}, 'tok', true, fakeGoogle({}, calls), mint), true);
  assert.equal(await writeRecall({}, 'tok', false, fakeGoogle({}, calls), mint), true);
  const writes = calls.filter((c) => c.url.endsWith('/deviceRecall:write'))
    .map((c) => JSON.parse(c.body));
  // The other two bits belong to whichever other app on the developer account
  // claims them. Naming them here, even as false, would clear theirs.
  assert.deepEqual(writes, [
    { integrityToken: 'tok', newValues: { bitFirst: true } },
    { integrityToken: 'tok', newValues: { bitFirst: false } },
  ]);
});

test('a failed write reports failure', async () => {
  const denied = async () => new Response('denied', { status: 403 });
  assert.equal(await writeRecall({}, 'tok', true, denied, fakeMint([])), false);
});
