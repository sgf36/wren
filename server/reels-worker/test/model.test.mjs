/**
 * The two settings that decide what this feature costs.
 *
 * Gemini charges for video by the second, so the model and the media resolution
 * are not tuning knobs — they are the difference between $0.0016 a reel and
 * about $4.50. A premium model at full resolution reads a forty-five second reel
 * for roughly the price of the app itself, on a feature bought once and used for
 * ever, and it would arrive as a bill rather than as an error.
 *
 * Nothing here talks to Google. That is the point: the assertion has to hold
 * before there is an account, because by the time there is one the mistake is
 * already costing money.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  ALLOWED_MODELS, MEDIA_RESOLUTION, RESPONSE_SCHEMA, modelRequest, FAILURES,
} from '../src/index.js';

const parts = [{ text: 'read the places' }];

test('the default is a Flash-Lite model, and it is the current one', () => {
  // 2.5 Flash-Lite was the plan when this was costed and may be retired in
  // October 2026. 3.5 Flash-Lite is the generation that replaced it and is
  // still about a sixth of a penny a reel.
  assert.deepEqual(ALLOWED_MODELS, ['gemini-3.5-flash-lite']);
  assert.equal(modelRequest({}, parts).model, 'gemini-3.5-flash-lite');
});

test('every request asks for low media resolution', () => {
  assert.equal(MEDIA_RESOLUTION, 'MEDIA_RESOLUTION_LOW');
  const { body } = modelRequest({}, parts);
  assert.equal(body.generationConfig.mediaResolution, 'MEDIA_RESOLUTION_LOW');
});

test('a model nobody costed stops the request', () => {
  // Including the plausible ones. "Flash" rather than "Flash-Lite" is a single
  // word and several times the price; a premium model is three orders of
  // magnitude. None of them may be reached by editing a variable.
  for (const model of [
    'gemini-3.5-flash',
    'gemini-3.1-pro',
    'gemini-omni-flash',
    'gemini-2.5-flash-lite',
    'gpt-4o',
  ]) {
    assert.throws(
      () => modelRequest({ GEMINI_MODEL: model }, parts),
      (err) => err.code === FAILURES.modelFailed,
      `${model} was allowed`,
    );
  }
});

test('an unset override means the default, not a refusal', () => {
  // Deliberate, and the tests above were written the other way round first.
  // An absent or empty var is how the Worker normally runs, and a Worker that
  // refused every request because nobody set an optional variable would be a
  // worse failure than the one being guarded against. Refusing is for a value
  // that is present and wrong.
  for (const env of [{}, { GEMINI_MODEL: '' }, { GEMINI_MODEL: undefined }]) {
    assert.equal(modelRequest(env, parts).model, ALLOWED_MODELS[0]);
  }
});

test('a refused model is not quietly swapped for a safe one', () => {
  // Falling back would keep the feature working and hide the fact that
  // something was configured nobody priced. The bill is the symptom either
  // way; only one of these has a cause attached.
  assert.throws(() => modelRequest({ GEMINI_MODEL: 'gemini-3.1-pro' }, parts));
});

test('the answer is asked for as JSON, so nothing has to be parsed out', () => {
  const { body } = modelRequest({}, parts);
  assert.equal(body.generationConfig.responseMimeType, 'application/json');
  assert.equal(body.generationConfig.responseSchema, RESPONSE_SCHEMA);
  assert.equal(body.generationConfig.temperature, 0);
  assert.equal(RESPONSE_SCHEMA.items.required[0], 'name');
});
