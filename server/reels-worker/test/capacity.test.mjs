/**
 * The global ceiling.
 *
 * The per-identity quota bounds what one customer can cost; this bounds the
 * total. It exists for the two cases that are not a customer behaving normally
 * -- a purchase token shared around, and a bug that retries -- because the
 * feature spends real money per call and the bill arrives afterwards.
 */
import test from 'node:test';
import assert from 'node:assert/strict';

import { globalUsage } from '../src/index.js';

/**
 * D1 as globalUsage uses it: one aggregate over every row in the window,
 * regardless of whose it is. It binds a single argument, unlike quotaState,
 * which is the whole point of the query and so of the fake.
 */
function fakeDb(rows) {
  return {
    prepare(sql) {
      return {
        bind(since) {
          return {
            async first() {
              if (!/FROM usage/.test(sql)) throw new Error(`unexpected: ${sql}`);
              if (/auth_key/.test(sql)) {
                throw new Error('the global count must not filter by identity');
              }
              return { n: rows.filter((r) => r.ts >= since).length };
            },
          };
        },
      };
    },
  };
}

const DAY = 24 * 60 * 60;

test('counts everybody, not just one identity', async () => {
  const now = Date.now();
  const ts = Math.floor(now / 1000) - 60;
  const rows = [
    { auth_key: 'a', ts }, { auth_key: 'b', ts }, { auth_key: 'c', ts },
  ];
  const g = await globalUsage({ GLOBAL_DAILY_LIMIT: '10' }, fakeDb(rows), now);
  assert.equal(g.used, 3);
  assert.equal(g.exhausted, false);
});

test('anything older than the window does not count', async () => {
  const now = Date.now();
  const seconds = Math.floor(now / 1000);
  const rows = [
    { auth_key: 'a', ts: seconds - DAY - 1 },   // aged out
    { auth_key: 'a', ts: seconds - DAY + 60 },  // still inside
  ];
  const g = await globalUsage({ GLOBAL_DAILY_LIMIT: '10' }, fakeDb(rows), now);
  assert.equal(g.used, 1);
});

test('exhausted at the limit, not one past it', async () => {
  const now = Date.now();
  const ts = Math.floor(now / 1000) - 60;
  const rows = Array.from({ length: 4 }, (_, i) => ({ auth_key: `k${i}`, ts }));

  const at = await globalUsage({ GLOBAL_DAILY_LIMIT: '4' }, fakeDb(rows), now);
  assert.equal(at.exhausted, true, 'the limit is a ceiling, not a target');

  const under = await globalUsage({ GLOBAL_DAILY_LIMIT: '5' }, fakeDb(rows), now);
  assert.equal(under.exhausted, false);
});

test('an unset limit still has one', async () => {
  const g = await globalUsage({}, fakeDb([]), Date.now());
  assert.equal(g.limit, 1000, 'a missing var must not mean unlimited spending');
  assert.equal(g.exhausted, false);
});

test('a nonsense limit does not read as unlimited', async () => {
  const now = Date.now();
  const ts = Math.floor(now / 1000) - 60;
  const rows = [{ auth_key: 'a', ts }];
  // Number('') is 0 and Number('abc') is NaN. The first would refuse everybody
  // and the second would refuse nobody -- NaN >= NaN is false -- so the falsy
  // check has to happen before the coercion, which is what `||` does here.
  const blank = await globalUsage({ GLOBAL_DAILY_LIMIT: '' }, fakeDb(rows), now);
  assert.equal(blank.limit, 1000, 'an empty var falls back rather than to zero');
  assert.equal(blank.exhausted, false);
});
