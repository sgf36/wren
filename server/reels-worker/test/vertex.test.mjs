/**
 * Calling the model through Vertex rather than AI Studio.
 *
 * Not a preference. AI Studio bills Gemini through a separate prepay payments
 * account even when the Cloud billing account behind it is postpay; that prepay
 * account is created by one dialog; that dialog does not render; and nothing
 * else can fund what it never created. Vertex serves the same models and bills
 * through the ordinary Cloud account, so the prepay mechanism is not worked
 * around here — it is not in the path at all.
 *
 * Nothing below reaches Google. What is worth testing without an account is the
 * shape of the request and the refusals, because those are the parts that decide
 * what a user sees and what a call costs.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  vertexEndpoint, readPlaces, accessToken,
  PLAY_SCOPE, VERTEX_SCOPE, FAILURES,
} from '../src/index.js';

const parts = [{ text: 'read the places' }];
const PROJECT = 'gen-lang-client-0475397099';

test('the endpoint names the project, the region and the model', () => {
  const url = vertexEndpoint({ VERTEX_PROJECT: PROJECT }, 'gemini-3.5-flash-lite');
  assert.match(url, /^https:\/\/europe-west1-aiplatform\.googleapis\.com\//);
  assert.ok(url.includes(`/projects/${PROJECT}/`));
  assert.ok(url.endsWith('/gemini-3.5-flash-lite:generateContent'));
});

test('the region is overridable, and the host follows it', () => {
  // Vertex prices by region and the host carries the region, so these two must
  // never disagree — a europe-west1 host serving a us-central1 path is a 404
  // that reads like a permissions problem.
  const url = vertexEndpoint(
    { VERTEX_PROJECT: PROJECT, VERTEX_LOCATION: 'us-central1' },
    'gemini-3.5-flash-lite',
  );
  assert.ok(url.startsWith('https://us-central1-aiplatform.googleapis.com/'));
  assert.ok(url.includes('/locations/us-central1/'));
});

test('no project means no endpoint, rather than a malformed one', () => {
  assert.equal(vertexEndpoint({}, 'gemini-3.5-flash-lite'), null);
});

test('the two service accounts ask for different scopes', () => {
  // Deliberately separate accounts: the one that reads Play purchases has no
  // business reaching a model, and the one that reaches a model has no business
  // reading purchases.
  assert.notEqual(PLAY_SCOPE, VERTEX_SCOPE);
  assert.equal(VERTEX_SCOPE, 'https://www.googleapis.com/auth/cloud-platform');
});

test('an absent service-account key mints nothing rather than throwing', async () => {
  for (const key of [undefined, null, '']) {
    assert.equal(await accessToken(key, VERTEX_SCOPE), null);
  }
});

test('unconfigured Vertex refuses, and says so in the app\'s own words', async () => {
  // No project and no key. The app localises on these codes, so a refusal here
  // has to be one of them rather than a thrown TypeError reaching the client.
  await assert.rejects(
    () => readPlaces({}, parts),
    (err) => err.code === FAILURES.modelFailed,
  );
});

test('a model nobody costed is refused before any network call', async () => {
  // modelRequest throws first, so a mistyped model cannot reach Vertex even
  // with a project and a key configured. The order matters: the guard is
  // worthless if the request is built after the call is made.
  await assert.rejects(
    () => readPlaces(
      { VERTEX_PROJECT: PROJECT, VERTEX_SA_KEY: 'x', GEMINI_MODEL: 'gemini-3.1-pro' },
      parts,
    ),
    (err) => err.code === FAILURES.modelFailed,
  );
});
