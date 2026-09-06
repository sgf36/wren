/**
 * What a code is allowed to grant.
 *
 * This is the only place the values are held. The live table was given its
 * role column by ALTER TABLE, which cannot add a constraint, so the CHECK in
 * schema.sql applies to a fresh database and to nothing that is running. If
 * roleOf lets a value through, it reaches D1 and comes back out again on every
 * later read.
 *
 * The direction of the default is the point. Every failure here should land on
 * the least privilege: a typo, an older client that sends no role at all, and
 * a claim someone has tampered with must all read as an ordinary unlock rather
 * than as an administrator or as the expensive half of the app.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ROLES, roleOf } from '../src/index.js';

test('the ladder is the three known roles, lowest first', () => {
  // Order is meaningful: it is the order the console offers them in, and it is
  // how anyone reading this decides which role is the generous one.
  assert.deepEqual(ROLES, ['unlock', 'everything', 'admin']);
});

test('each known role survives a round trip', () => {
  for (const role of ROLES) assert.equal(roleOf(role), role);
});

test('everything else is an ordinary unlock', () => {
  const wrong = [
    undefined,          // a token minted before roles existed
    null,
    '',
    'Admin',            // case matters, and nearly-right is still wrong
    'ADMIN',
    'administrator',
    'root',
    'Everything',
    'reels',            // a role that sounds plausible and was never created
    'unlock ',
    0,
    1,
    true,
    {},
    ['admin'],
  ];
  for (const value of wrong) {
    assert.equal(roleOf(value), 'unlock', `${JSON.stringify(value)} was promoted`);
  }
});

test('no unrecognised value can reach the expensive half of the app', () => {
  // The reels Worker grants its feature to 'everything' and 'admin'. Anything
  // that normalises to 'unlock' therefore cannot reach it, and this is the
  // assertion that keeps the two Workers honest about the same ladder: a role
  // added here without being considered there would fail this.
  const reachesReels = ['everything', 'admin'];
  for (const role of ROLES) {
    const grants = reachesReels.includes(roleOf(role));
    assert.equal(grants, role !== 'unlock', role);
  }
});
