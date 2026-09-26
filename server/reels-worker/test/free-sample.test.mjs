/**
 * The free first read.
 *
 * Wren's pitch is that a shared post becomes places on a map, and until
 * 2026-09-26 nobody saw that happen without paying £14.99 first. Thirteen
 * downloads produced no purchases at all. This grants one read so the pitch can
 * demonstrate itself, and every test here is about the two ways that goes wrong:
 * giving away more than one, or giving one away to a caller Apple never vouched
 * for.
 */
import test from 'node:test';
import assert from 'node:assert/strict';

import { isFree, quotaState, identify } from '../src/index.js';

/**
 * D1 as quotaState uses it: a count of one identity's rows since a cutoff.
 *
 * The cutoff is asserted rather than ignored, because the whole difference
 * between a lifetime allowance and a rolling one is the value bound here. A
 * fake that accepted any `since` would pass whichever behaviour shipped.
 */
function fakeDb(rows, seen = {}) {
  return {
    prepare(sql) {
      return {
        bind(key, since) {
          seen.key = key;
          seen.since = since;
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

const NOW = 1_800_000_000_000;
const SEC = Math.floor(NOW / 1000);
const FREE = 'free:abc123';
const PAID = 'appstore:2000000999';

test('a free key is recognised, a purchase key is not', () => {
  assert.equal(isFree(FREE), true);
  assert.equal(isFree(PAID), false);
  assert.equal(isFree('comp:XYZ'), false);
  // The positive control for the negative checks below: if isFree ever returned
  // true for everything, the "purchases are unaffected" tests would still pass
  // while the quota collapsed to one for every paying customer.
  assert.equal(isFree(undefined), false);
});

test('the free allowance is one, and spending it exhausts it', async () => {
  const empty = await quotaState({}, fakeDb([]), FREE, NOW);
  assert.equal(empty.limit, 1);
  assert.equal(empty.used, 0);
  assert.equal(empty.free, true);
  assert.equal(empty.exhausted, false, 'a new identity must get its free read');

  const spent = await quotaState(
    {}, fakeDb([{ auth_key: FREE, ts: SEC - 10 }]), FREE, NOW);
  assert.equal(spent.used, 1);
  assert.equal(spent.exhausted, true, 'the second read must be refused');
});

test('the free allowance never rolls over', async () => {
  // Two years old. Under the thirty-day window this would have aged out and
  // handed back a second free read, which is a price change rather than a
  // sample.
  const ancient = [{ auth_key: FREE, ts: SEC - 730 * 24 * 60 * 60 }];
  const seen = {};
  const q = await quotaState({}, fakeDb(ancient, seen), FREE, NOW);

  assert.equal(seen.since, 0, 'a lifetime allowance must count from the start');
  assert.equal(q.exhausted, true, 'an old free read still counts');
  assert.equal(q.resetsAt, null, 'nothing that never resets may name a date');
});

test('FREE_REELS sets the allowance', async () => {
  const two = await quotaState(
    { FREE_REELS: '2' }, fakeDb([{ auth_key: FREE, ts: SEC - 10 }]), FREE, NOW);
  assert.equal(two.limit, 2);
  assert.equal(two.exhausted, false);
});

test('a purchase still gets 250 on a rolling thirty days', async () => {
  const seen = {};
  const q = await quotaState({}, fakeDb([], seen), PAID, NOW);
  assert.equal(q.limit, 250);
  assert.equal(q.free, false);
  assert.notEqual(seen.since, 0, 'a purchase must keep its rolling window');
  assert.equal(seen.since, SEC - 30 * 24 * 60 * 60);

  // And an old call must still age out for a paying customer.
  const old = [{ auth_key: PAID, ts: SEC - 40 * 24 * 60 * 60 }];
  const aged = await quotaState({}, fakeDb(old), PAID, NOW);
  assert.equal(aged.used, 0, 'a call older than the window must not count');
});

test('an unsigned caller gets nothing, whatever it claims to be', async () => {
  // The shape the first attempt at this feature used: an id the client invented.
  // It must not resolve to an identity now that a signed route exists, or the
  // signed route is decoration.
  for (const auth of [
    { kind: 'trial', id: 'a'.repeat(32) },
    { kind: 'free', id: 'a'.repeat(32) },
    { kind: 'apptransaction' },
    { kind: 'apptransaction', jws: '' },
    { kind: 'apptransaction', jws: 'not.a.jws' },
    { kind: 'nonsense' },
    null,
  ]) {
    assert.equal(await identify({}, auth), null,
      `must refuse ${JSON.stringify(auth)}`);
  }
});

test('FREE_REELS=0 withdraws the identity rather than granting an empty one', async () => {
  // Granting the identity and letting the quota refuse it would answer
  // "allowance exhausted" to somebody who never had one.
  assert.equal(
    await identify({ FREE_REELS: '0' },
      { kind: 'apptransaction', jws: 'anything' }),
    null);
});
