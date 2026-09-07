/**
 * Reading what the vendor actually sends.
 *
 * The fixture is a real ScrapeCreators response to a real Instagram post,
 * captured on 6 September 2026 — an eleven-slide carousel of castle hotels. Only
 * the CDN urls are replaced, because those carry per-request tokens that expire
 * and identify the fetch. Everything that decides behaviour is exactly what
 * Instagram sent.
 *
 * That matters more than it sounds. Every shape in this file was guessed at
 * first and several guesses were wrong: the caption is nested three levels deep
 * under a name that does not mention captions, and a carousel is called a
 * sidecar. Fixtures written from documentation would have encoded the guesses.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  readInstagram, fetchPost, fetchImages, regionOf,
  MAX_SLIDES, MEDIA_BUDGET,
} from '../src/vendors.js';

const CAROUSEL = JSON.parse(readFileSync(
  new URL('./fixtures/instagram-carousel.json', import.meta.url), 'utf8'));

test('a real carousel reads as eleven slides and its caption', () => {
  const post = readInstagram(CAROUSEL);
  assert.equal(post.images.length, 11);
  assert.equal(post.video, null);
  assert.ok(post.caption.includes('Ashford Castle'));
  assert.ok(post.caption.includes('Thornbury Castle'));
});

test('a shape nobody recognises yields null rather than throwing', () => {
  // The caller decides what an unreadable post means, and it has better
  // information for that than this does.
  for (const body of [null, undefined, {}, { data: {} }, { data: { xdt_shortcode_media: null } }]) {
    assert.equal(readInstagram(body), null);
  }
});

test('a single image post is one slide, not zero', () => {
  // No sidecar means the node is its own child. Reading only children would
  // make every non-carousel post look empty.
  const one = {
    data: {
      xdt_shortcode_media: {
        __typename: 'XDTGraphImage',
        display_url: 'https://example.invalid/one.jpg',
        edge_media_to_caption: { edges: [{ node: { text: 'Padella, London' } }] },
      },
    },
  };
  const post = readInstagram(one);
  assert.equal(post.images.length, 1);
  assert.equal(post.caption, 'Padella, London');
});

test('a video post yields a video and no images', () => {
  const reel = {
    data: {
      xdt_shortcode_media: {
        __typename: 'XDTGraphVideo',
        is_video: true,
        video_url: 'https://example.invalid/reel.mp4',
        display_url: 'https://example.invalid/thumb.jpg',
        edge_media_to_caption: { edges: [] },
      },
    },
  };
  const post = readInstagram(reel);
  assert.equal(post.video, 'https://example.invalid/reel.mp4');
  assert.equal(post.images.length, 0);
});

test('a very long carousel is capped', () => {
  const edges = Array.from({ length: 40 }, (_, i) => ({
    node: { display_url: `https://example.invalid/${i}.jpg` },
  }));
  const post = readInstagram({
    data: {
      xdt_shortcode_media: {
        edge_sidecar_to_children: { edges },
        edge_media_to_caption: { edges: [] },
      },
    },
  });
  assert.equal(post.images.length, MAX_SLIDES);
});

test('no key means no call, rather than an unauthenticated one', async () => {
  let called = false;
  const post = await fetchPost({}, { platform: 'instagram', canonical: 'x' },
    () => { called = true; });
  assert.equal(post, null);
  assert.equal(called, false, 'the vendor was called without a key');
});

test('the vendor is asked for the canonical url, with the key in a header', async () => {
  let seen = null;
  await fetchPost(
    { SCRAPECREATORS_API_KEY: 'secret' },
    { platform: 'instagram', canonical: 'https://www.instagram.com/p/ABC/' },
    (url, opts) => {
      seen = { url, opts };
      return { ok: true, json: async () => CAROUSEL };
    },
  );
  assert.ok(seen.url.includes('/instagram/post'));
  assert.ok(seen.url.includes(encodeURIComponent('https://www.instagram.com/p/ABC/')));
  assert.equal(seen.opts.headers['x-api-key'], 'secret');
  // Cloudflare edges answer 403 "error code: 1010" to a default library agent,
  // which looks exactly like a revoked key.
  assert.match(seen.opts.headers['User-Agent'], /Mozilla/);
});

test('a vendor failure is null, not a half-read post', async () => {
  const env = { SCRAPECREATORS_API_KEY: 'k' };
  const target = { platform: 'instagram', canonical: 'x' };
  assert.equal(await fetchPost(env, target, () => ({ ok: false })), null);
  assert.equal(await fetchPost(env, target,
    () => ({ ok: true, json: async () => ({ success: false }) })), null);
});

test('an unknown platform is not guessed at', async () => {
  // TikTok and YouTube answer with their own shapes. Reading them from
  // documentation rather than a real response is how the Instagram reader got
  // written wrong three times, so they wait for a captured example.
  const post = await fetchPost(
    { SCRAPECREATORS_API_KEY: 'k' },
    { platform: 'tiktok', canonical: 'x' },
    () => ({ ok: true, json: async () => ({ success: true }) }),
  );
  assert.equal(post, null);
});

test('one unreachable slide does not lose the other ten', async () => {
  // A carousel with a single expired url is still nine readable slides, and
  // refusing the lot would be a worse answer than a shorter one.
  const urls = Array.from({ length: 11 }, (_, i) => `https://example.invalid/${i}.jpg`);
  const parts = await fetchImages(urls, async (url) => {
    if (url.endsWith('/3.jpg')) return { ok: false };
    if (url.endsWith('/7.jpg')) throw new Error('connection reset');
    return {
      ok: true,
      headers: { get: () => 'image/jpeg' },
      arrayBuffer: async () => new Uint8Array(64).buffer,
    };
  });
  assert.equal(parts.length, 9);
  assert.ok(parts.every((p) => p.inlineData.mimeType === 'image/jpeg'));
});

test('the byte budget stops the download, not the slide count', async () => {
  // What costs money is bytes to the model, not how many files they arrived in.
  const urls = Array.from({ length: 20 }, (_, i) => `https://example.invalid/${i}.jpg`);
  const big = 1024 * 1024;
  const parts = await fetchImages(urls, async () => ({
    ok: true,
    headers: { get: () => 'image/jpeg' },
    arrayBuffer: async () => new Uint8Array(big).buffer,
  }), 4 * big);
  assert.equal(parts.length, 4);
});

test('the region needs a majority, not merely the most common answer', () => {
  // A wrong hint is worse than none: it aims every lookup at the wrong city.
  // Two of three is a post about Lisbon.
  assert.equal(regionOf([
    { name: 'A', city: 'Lisbon' },
    { name: 'B', city: 'Lisbon' },
    { name: 'C', city: 'Porto' },
    { name: 'D' },
  ]), 'Lisbon');

  // The real castle post: ten hotels across seven countries, two of them in
  // Ireland. Taking the most common answer called the whole post Irish.
  const scattered = [
    'Ireland', 'Ireland', 'England', 'England', 'Scotland',
    'Scotland', 'France', 'France', 'Spain', 'Germany',
  ].map((city, i) => ({ name: `castle ${i}`, city }));
  assert.equal(regionOf(scattered), null);

  // Exactly half is not a majority either.
  assert.equal(regionOf([
    { name: 'A', city: 'Lisbon' },
    { name: 'B', city: 'Porto' },
  ]), null);

  assert.equal(regionOf([{ name: 'A' }]), null);
  assert.equal(regionOf([]), null);
});

test('the media budget is a real number, not a placeholder', () => {
  // Eleven slides of a real carousel came to 2.6MB. A Worker has 128MB.
  assert.ok(MEDIA_BUDGET >= 4 * 1024 * 1024);
  assert.ok(MEDIA_BUDGET <= 32 * 1024 * 1024);
});
