/**
 * The free first read on Android.
 *
 * iOS keys the sample on Apple's appTransactionId. Android has no such id, so
 * it keys on Play Integrity's device recall: one bit, held by Google, that
 * survives reinstalling the app and resetting the phone. Every test here is
 * about one of three ways that goes wrong -- a second free read, a free read
 * for a caller Google never vouched for, or a free read nobody recorded.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';

import {
  BUNDLE_ID, INTEGRITY_MAX_AGE_MS, INTEGRITY_SCOPE, identify, judgeIntegrity, nonceBindsUrl,
  verifyPlayIntegrity, writeRecall,
} from '../src/index.js';

const URL_A = 'https://www.instagram.com/reel/ABC123/';
const URL_B = 'https://www.instagram.com/reel/XYZ789/';
const NOW = 1_800_000_000_000;

async function nonceFor(url, salt = 7) {
  const hash = new Uint8Array(await webcrypto.subtle.digest(
    'SHA-256', new TextEncoder().encode(url)));
  const raw = new Uint8Array(48);
  raw.set(hash, 0);
  raw.fill(salt, 32);
  return Buffer.from(raw).toString('base64url');
}

async function verdict(over = {}) {
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
      deviceRecall: { values: { bitFirst: false }, writeDates: {} },
    },
  };
  return over(base) ?? base;
}

test('a genuine first share on a genuine device is granted', async () => {
  const v = await verdict((b) => b);
  const got = await judgeIntegrity(v, URL_A, NOW);
  assert.ok(got, 'the positive control: without it every refusal below is meaningless');
  assert.equal(got.nonce, v.requestDetails.nonce);
});

test('a device that has had its read is refused', async () => {
  const v = await verdict((b) => {
    b.deviceIntegrity.deviceRecall.values.bitFirst = true;
  });
  assert.equal(await judgeIntegrity(v, URL_A, NOW), null);
});

test('no device recall in the verdict means no free read', async () => {
  // What every token looks like until the beta is granted and switched on in
  // Play Console. It must behave exactly as Android did before: paywall first.
  for (const strip of [
    (b) => { delete b.deviceIntegrity.deviceRecall; },
    (b) => { b.deviceIntegrity.deviceRecall = {}; },
  ]) {
    assert.equal(await judgeIntegrity(await verdict(strip), URL_A, NOW), null);
  }
});

test('a token minted for one link cannot be spent on another', async () => {
  assert.equal(await judgeIntegrity(await verdict((b) => b), URL_B, NOW), null);
  assert.equal(await nonceBindsUrl(await nonceFor(URL_A), URL_A), true);
  assert.equal(await nonceBindsUrl(await nonceFor(URL_A), URL_B), false);
  assert.equal(await nonceBindsUrl('short', URL_A), false);
  assert.equal(await nonceBindsUrl('', URL_A), false);
});

test('an old token is a replay', async () => {
  const stale = await verdict((b) => {
    b.requestDetails.timestampMillis = String(NOW - INTEGRITY_MAX_AGE_MS - 1);
  });
  assert.equal(await judgeIntegrity(stale, URL_A, NOW), null);
  const future = await verdict((b) => {
    b.requestDetails.timestampMillis = String(NOW + 120_000);
  });
  assert.equal(await judgeIntegrity(future, URL_A, NOW), null);
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
    assert.equal(await judgeIntegrity(await verdict(c), URL_A, NOW), null, String(c));
  }
});

test('FREE_REELS=0 withdraws the Android sample too', async () => {
  assert.equal(await identify({ FREE_REELS: '0' },
    { kind: 'playintegrity', token: 'x' }, URL_A), null);
});

test('no token, or no service account, is a refusal and not a crash', async () => {
  for (const auth of [
    { kind: 'playintegrity' },
    { kind: 'playintegrity', token: '' },
    { kind: 'playintegrity', token: 'x' },
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

test('a granted token becomes a free identity keyed on its nonce', async () => {
  const v = await verdict((b) => {
    b.requestDetails.timestampMillis = String(Date.now() - 1000);
  });
  const calls = [];
  const scopes = [];
  const who = await verifyPlayIntegrity(
    {}, 'tok', URL_A, fakeGoogle(v, calls), fakeMint(scopes));
  assert.ok(who);
  assert.equal(who.key, `free:play:${v.requestDetails.nonce}`);
  assert.equal(who.store, 'free');
  assert.equal(who.integrityToken, 'tok');
  assert.deepEqual(scopes, [INTEGRITY_SCOPE]);
  const decode = calls.find((c) => c.url.endsWith(':decodeIntegrityToken'));
  assert.ok(decode.url.includes(BUNDLE_ID));
  assert.deepEqual(JSON.parse(decode.body), { integrity_token: 'tok' });
});

test('a verdict Google decoded but the judge refuses grants nothing', async () => {
  const spent = await verdict((b) => {
    b.requestDetails.timestampMillis = String(Date.now() - 1000);
    b.deviceIntegrity.deviceRecall.values.bitFirst = true;
  });
  assert.equal(await verifyPlayIntegrity(
    {}, 'tok', URL_A, fakeGoogle(spent, []), fakeMint([])), null);
});

test('no bearer token means no decode and no free read', async () => {
  const calls = [];
  assert.equal(await verifyPlayIntegrity(
    {}, 'tok', URL_A, fakeGoogle({}, calls), async () => null), null);
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
