/**
 * Who is allowed to spend money, and how much of it.
 *
 * Two things are being defended. One is revenue: /process costs real money per
 * call, so anything that says yes when it should say no is a bill. The other is
 * the opposite failure, which is worse — a verifier that says no to a genuine
 * purchase produces a paying customer looking at a paywall they already paid,
 * and that arrives as a refund and a one-star review rather than as an alert.
 *
 * The Apple path is not tested here. It delegates to Apple's own library over a
 * real certificate chain, and a test that stubs the library would assert that
 * the stub works. It needs fixture transactions from a sandbox purchase, which
 * is a device task.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  verifiedComp, identify, quotaState, THIRTY_DAYS, REEL_PRODUCTS,
} from '../src/index.js';

const b64 = (bytes) => Buffer.from(bytes).toString('base64');
const b64url = (bytes) =>
  Buffer.from(bytes).toString('base64url').replace(/=+$/, '');

/** A signing pair, and the `env` a Worker holding its public half would see. */
async function pair() {
  const keys = await crypto.subtle.generateKey({ name: 'Ed25519' }, true,
    ['sign', 'verify']);
  const raw = await crypto.subtle.exportKey('raw', keys.publicKey);
  return { keys, env: { WREN_PUBLIC_KEY: b64(raw) } };
}

/** A token shaped exactly as wren-codes mints one. */
async function token(keys, claims) {
  const body = new TextEncoder().encode(JSON.stringify(claims));
  const sig = await crypto.subtle.sign({ name: 'Ed25519' }, keys.privateKey,
    body);
  return `${b64url(body)}.${b64url(sig)}`;
}

/**
 * D1, as far as this Worker uses it. Only quotaState reads, and it reads one
 * aggregate, so the fake counts rows the same way rather than pretending to be
 * SQLite.
 */
function fakeDb(rows) {
  return {
    prepare(sql) {
      return {
        bind(key, since) {
          return {
            async first() {
              if (!/FROM usage/.test(sql)) throw new Error(`unexpected: ${sql}`);
              const mine = rows.filter((r) => r.auth_key === key && r.ts >= since);
              return {
                n: mine.length,
                oldest: mine.length ? Math.min(...mine.map((r) => r.ts)) : null,
              };
            },
          };
        },
      };
    },
  };
}

test('a comp token this project signed reads back as its claims', async () => {
  const { keys, env } = await pair();
  const claims = { v: 1, d: 'device-1', c: 'ABCD-EFGH', r: 'unlock', t: 1 };
  assert.deepEqual(await verifiedComp(env, await token(keys, claims)), claims);
});

test('a tampered comp token verifies as nothing', async () => {
  const { keys, env } = await pair();
  const good = await token(keys, { v: 1, d: 'device-1', c: 'ABCD-EFGH' });
  const [body, sig] = good.split('.');
  // The payload rewritten to name a different code, keeping the old signature.
  // This is the whole attack: a signature that was valid for something else.
  const forged = b64url(Buffer.from(
    JSON.stringify({ v: 1, d: 'device-1', c: 'ZZZZ-ZZZZ' })));
  assert.equal(await verifiedComp(env, `${forged}.${sig}`), null);
  assert.equal(await verifiedComp(env, `${body}.${sig.slice(0, -4)}AAAA`), null);
});

test('a token signed by somebody else verifies as nothing', async () => {
  const mine = await pair();
  const theirs = await pair();
  const forged = await token(theirs.keys, { v: 1, d: 'd', c: 'ABCD-EFGH' });
  assert.equal(await verifiedComp(mine.env, forged), null);
});

test('App Review reaches the feature, because comp grants everything', async () => {
  // The comp code in the review notes has to unlock reels as well as guides. A
  // reviewer who follows the notes and hits a paywall rejects the build, and
  // the rejection reads as something else entirely.
  const { keys, env } = await pair();
  const who = await identify(env,
    { kind: 'comp', token: await token(keys, { v: 1, d: 'd', c: 'REVIEW-1' }) });
  assert.equal(who.store, 'comp');
  assert.equal(who.key, 'comp:REVIEW-1');
});

test('every unrecognised or malformed identity fails closed', async () => {
  const { env } = await pair();
  const refused = [
    undefined,
    null,
    {},
    { kind: 'nonsense' },
    { kind: 'comp' },
    { kind: 'comp', token: '' },
    { kind: 'comp', token: 'not.a.token' },
    { kind: 'comp', token: 'aaaa' },
    // No purchase token at all. Reaching Google with an empty handle would
    // still be a network call made on an anonymous caller's say-so.
    { kind: 'play', productId: REEL_PRODUCTS[2] },
    // A real product with no key configured must not become a free unlock.
    { kind: 'play', purchaseToken: 'x', productId: REEL_PRODUCTS[2] },
    // A product that grants nothing, presented as though it did.
    { kind: 'play', purchaseToken: 'x', productId: 'com.spencerfields.littlebird.unlimited' },
  ];
  for (const auth of refused) {
    assert.equal(await identify(env, auth), null,
      `accepted ${JSON.stringify(auth)}`);
  }
});

test('quota counts the trailing thirty days and nothing older', async () => {
  const now = 1_800_000_000_000;
  const s = Math.floor(now / 1000);
  const rows = [
    { auth_key: 'k', ts: s - 10 },
    { auth_key: 'k', ts: s - THIRTY_DAYS + 60 },   // just inside
    { auth_key: 'k', ts: s - THIRTY_DAYS - 60 },   // just outside
    { auth_key: 'other', ts: s - 10 },             // somebody else's
  ];
  const q = await quotaState({ QUOTA_PER_30_DAYS: '250' }, fakeDb(rows), 'k', now);
  assert.equal(q.used, 2);
  assert.equal(q.limit, 250);
  assert.equal(q.exhausted, false);
});

test('quota reports when it frees up, not a calendar date', async () => {
  // The copy says "resets on <date>", and on a rolling window that date is when
  // the oldest call ages out. A month boundary would be a different number and
  // the wrong one.
  const now = 1_800_000_000_000;
  const s = Math.floor(now / 1000);
  const oldest = s - THIRTY_DAYS + 3600;
  const q = await quotaState({}, fakeDb([{ auth_key: 'k', ts: oldest }]), 'k', now);
  assert.equal(q.resetsAt, (oldest + THIRTY_DAYS) * 1000);
});

test('an identity that has spent nothing has no reset date', async () => {
  const q = await quotaState({}, fakeDb([]), 'k', Date.now());
  assert.equal(q.used, 0);
  assert.equal(q.resetsAt, null);
  assert.equal(q.exhausted, false);
});

test('the limit is reached at the limit, not one past it', async () => {
  const now = 1_800_000_000_000;
  const s = Math.floor(now / 1000);
  const rows = Array.from({ length: 3 }, () => ({ auth_key: 'k', ts: s - 10 }));
  const q = await quotaState({ QUOTA_PER_30_DAYS: '3' }, fakeDb(rows), 'k', now);
  assert.equal(q.exhausted, true);
});

test('this Worker and wren-codes verify against the same key', () => {
  // Two Workers, two wrangler.toml files, one signing pair. If they drift, comp
  // codes keep working for guides and stop working for reels — which presents
  // as "the reel feature is broken", not as a configuration mistake.
  const key = (path) => readFileSync(new URL(path, import.meta.url), 'utf8')
    .match(/WREN_PUBLIC_KEY = "([^"]+)"/)[1];
  assert.equal(
    key('../wrangler.toml'),
    key('../../comp-codes-worker/wrangler.toml'),
  );
});
