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
  BUNDLE_ID, INTEGRITY_MAX_AGE_MS, identify, judgeIntegrity, nonceBindsUrl,
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

async function serviceAccount() {
  const pair = await webcrypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true, ['sign', 'verify']);
  const der = Buffer.from(await webcrypto.subtle.exportKey('pkcs8', pair.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${der.toString('base64')}\n-----END PRIVATE KEY-----\n`;
  return JSON.stringify({ client_email: 'sa@example.iam.gserviceaccount.com',
    private_key: pem });
}

function fakeGoogle(payload, calls) {
  return async (url, init) => {
    calls.push({ url: String(url), body: init?.body });
    if (String(url).startsWith('https://oauth2.googleapis.com/token')) {
      return new Response(JSON.stringify({ access_token: 'bearer' }));
    }
    if (String(url).endsWith(':decodeIntegrityToken')) {
      return new Response(JSON.stringify({ tokenPayloadExternal: payload }));
    }
    if (String(url).endsWith('/deviceRecall:write')) {
      return new Response('{}');
    }
    return new Response('no', { status: 404 });
  };
}

test('a granted token becomes a free identity keyed on its nonce', async (t) => {
  const v = await verdict((b) => {
    b.requestDetails.timestampMillis = String(Date.now() - 1000);
  });
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = fakeGoogle(v, calls);
  t.after(() => { globalThis.fetch = real; });

  const env = { PLAY_SA_KEY: await serviceAccount() };
  const who = await verifyPlayIntegrity(env, 'tok', URL_A, globalThis.fetch);
  assert.ok(who);
  assert.equal(who.key, `free:play:${v.requestDetails.nonce}`);
  assert.equal(who.store, 'free');
  assert.equal(who.integrityToken, 'tok');
  const decode = calls.find((c) => c.url.endsWith(':decodeIntegrityToken'));
  assert.ok(decode.url.includes(BUNDLE_ID));
  assert.deepEqual(JSON.parse(decode.body), { integrity_token: 'tok' });
});

test('writeRecall touches bitFirst and nothing else', async (t) => {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = fakeGoogle({}, calls);
  t.after(() => { globalThis.fetch = real; });

  const env = { PLAY_SA_KEY: await serviceAccount() };
  assert.equal(await writeRecall(env, 'tok', true, globalThis.fetch), true);
  assert.equal(await writeRecall(env, 'tok', false, globalThis.fetch), true);
  const writes = calls.filter((c) => c.url.endsWith('/deviceRecall:write'))
    .map((c) => JSON.parse(c.body));
  // The other two bits belong to whichever other app on the developer account
  // claims them. Naming them here, even as false, would clear theirs.
  assert.deepEqual(writes, [
    { integrityToken: 'tok', newValues: { bitFirst: true } },
    { integrityToken: 'tok', newValues: { bitFirst: false } },
  ]);
});

test('a failed write reports failure', async (t) => {
  const real = globalThis.fetch;
  globalThis.fetch = async (url) => (String(url).includes('oauth2')
    ? new Response(JSON.stringify({ access_token: 'b' }))
    : new Response('denied', { status: 403 }));
  t.after(() => { globalThis.fetch = real; });
  const env = { PLAY_SA_KEY: await serviceAccount() };
  assert.equal(await writeRecall(env, 'tok', true, globalThis.fetch), false);
});
