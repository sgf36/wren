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
  readInstagram, readTikTok, fetchPost, fetchYouTubeSnippet,
  fetchYouTubeTranscript, fetchImages, regionOf, isGenericPlace,
  MAX_SLIDES, MEDIA_BUDGET, MAX_TRANSCRIPT_CHARS,
} from '../src/vendors.js';

const CAROUSEL = JSON.parse(readFileSync(
  new URL('./fixtures/instagram-carousel.json', import.meta.url), 'utf8'));

// Real ScrapeCreators response to a real TikTok share, captured 2026-09-30
// while diagnosing "that post could not be opened" on every TikTok link ever
// shared -- the platform was accepted as valid input and never actually
// readable. Trimmed to the fields readTikTok uses; the CDN video urls are
// replaced for the same reason as the Instagram fixture. The real post is a
// London listicle whose caption already names all eleven venues.
const TIKTOK_VIDEO = JSON.parse(readFileSync(
  new URL('./fixtures/tiktok-video.json', import.meta.url), 'utf8'));

// Real YouTube Data API v3 response for the exact Short reported as "the app
// does ANYTHING when I click to share it to wren" -- id ikO_b8Wmtcc, 2026-09-30.
// Nothing replaced: title and description are public data with no expiring
// tokens. The description is genuinely empty -- all eleven venues are burned
// into on-screen text only -- which is why this fixture exists at all: it is
// the real case that proves the description-only path is not always enough,
// not a hypothetical one.
const YOUTUBE_EMPTY_DESCRIPTION = JSON.parse(readFileSync(
  new URL('./fixtures/youtube-video-empty-description.json', import.meta.url),
  'utf8'));

// Real ScrapeCreators transcript response for that same Short, confirming it
// has no captions at all -- `captionTracks` is genuinely empty, not merely
// unfetched. This is what proves the transcript path is not a full
// replacement for reading the video: some Shorts have neither a caption nor
// a transcript, only on-screen text a transcript cannot see.
const YOUTUBE_NO_TRANSCRIPT = JSON.parse(readFileSync(
  new URL('./fixtures/youtube-transcript-none.json', import.meta.url), 'utf8'));

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

test('the older shortcode_media shape is read the same way', () => {
  const old = {
    data: {
      shortcode_media: {
        __typename: 'XDTGraphImage',
        display_url: 'https://example.invalid/one.jpg',
        edge_media_to_caption: { edges: [{ node: { text: 'Bar Brutal, Barcelona' } }] },
      },
    },
  };
  const post = readInstagram(old);
  assert.equal(post.images.length, 1);
  assert.equal(post.caption, 'Bar Brutal, Barcelona');
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

test('fetchPost never learns youtube -- that platform reads through the Data API instead', async () => {
  // Not a gap waiting to be filled: placesFromPost routes 'youtube' to
  // fetchYouTubeSnippet before fetchPost is ever called, on purpose (free API,
  // no vendor credit). This pins that fetchPost itself stays ignorant of the
  // platform, so a future change cannot silently start spending a
  // ScrapeCreators credit on a request meant to be free.
  const post = await fetchPost(
    { SCRAPECREATORS_API_KEY: 'k' },
    { platform: 'youtube', canonical: 'x' },
    () => ({ ok: true, json: async () => ({ success: true }) }),
  );
  assert.equal(post, null);
});

test('a real TikTok video reads as its caption and its video url', () => {
  const post = readTikTok(TIKTOK_VIDEO);
  assert.ok(post.caption.includes('Camden Market'));
  assert.ok(post.caption.includes('Battersea Power Station'));
  assert.equal(post.video, 'https://example.invalid/tiktok-video-no-watermark.mp4');
  assert.equal(post.images.length, 0);
});

test('a TikTok shape with no known video field is unreadable, not guessed at', () => {
  // aweme_detail with no video, and no captured example of the photo-mode
  // shape -- see readTikTok's own comment. Reading nothing is the honest
  // answer here, not inventing a field name.
  assert.equal(readTikTok({ aweme_detail: { desc: 'hello' } }), null);
  assert.equal(readTikTok({}), null);
  assert.equal(readTikTok(null), null);
});

test('TikTok is asked at v2, not v1 -- the endpoint that 404s with no body', async () => {
  // Confirmed against the real API 2026-09-30: /v1/tiktok/video 404s with a
  // bare "Not Found", no JSON, on every TikTok link ever shared. /v2 is the
  // one ScrapeCreators' own docs describe.
  let seenUrl = null;
  await fetchPost(
    { SCRAPECREATORS_API_KEY: 'k' },
    { platform: 'tiktok', canonical: 'https://www.tiktok.com/@x/video/1' },
    (url) => {
      seenUrl = url;
      return { ok: true, json: async () => TIKTOK_VIDEO };
    },
  );
  assert.ok(seenUrl.includes('/v2/tiktok/video'));
  assert.ok(!seenUrl.includes('/v1/tiktok'));
});

test('a TikTok post is read end to end through fetchPost', async () => {
  const post = await fetchPost(
    { SCRAPECREATORS_API_KEY: 'k' },
    { platform: 'tiktok', canonical: 'https://www.tiktok.com/@x/video/1' },
    () => ({ ok: true, json: async () => TIKTOK_VIDEO }),
  );
  assert.ok(post.caption.includes('Camden Market'));
  assert.equal(post.video, 'https://example.invalid/tiktok-video-no-watermark.mp4');
});

test('no YouTube key means no call, matching the other vendor', async () => {
  let called = false;
  const post = await fetchYouTubeSnippet({}, 'x', () => { called = true; });
  assert.equal(post, null);
  assert.equal(called, false);
});

test('a real Short with an empty description reads as its title alone', async () => {
  // The real, reported case: nothing to find here on its own. This is what
  // makes placesFromPost fall through to the "nothing to read" refusal --
  // correctly, since the eleven venues really are only on screen.
  const post = await fetchYouTubeSnippet(
    { YOUTUBE_API_KEY: 'k' }, 'ikO_b8Wmtcc',
    () => ({ ok: true, json: async () => YOUTUBE_EMPTY_DESCRIPTION }),
  );
  assert.equal(post.caption, '10 Free Bucket list places You need to visit in London');
  assert.equal(post.video, null);
  assert.equal(post.images.length, 0);
});

test('a Short whose description lists places reads both title and description', async () => {
  // Same confirmed shape (snippet.title / snippet.description) as the real
  // fixture above -- only the values differ, to exercise the case where the
  // description is the reason this path exists at all.
  const withDescription = {
    items: [{ snippet: {
      title: 'Free things to do in Rome',
      description: 'Trevi Fountain, the Pantheon, and Villa Borghese gardens.',
    } }],
  };
  const post = await fetchYouTubeSnippet(
    { YOUTUBE_API_KEY: 'k' }, 'x',
    () => ({ ok: true, json: async () => withDescription }),
  );
  assert.ok(post.caption.includes('Free things to do in Rome'));
  assert.ok(post.caption.includes('Trevi Fountain'));
});

test('no video found is null, not a half-read snippet', async () => {
  const empty = await fetchYouTubeSnippet(
    { YOUTUBE_API_KEY: 'k' }, 'x',
    () => ({ ok: true, json: async () => ({ items: [] }) }),
  );
  assert.equal(empty, null);

  const httpFailure = await fetchYouTubeSnippet(
    { YOUTUBE_API_KEY: 'k' }, 'x',
    () => ({ ok: false, status: 403 }),
  );
  assert.equal(httpFailure, null);
});

test('a Short with real narration reads its transcript', async () => {
  // Same confirmed field (transcript_only_text) as the real capture, with a
  // short synthetic value in place of the real 25,701-character Arabic
  // transcript that confirmed the shape -- committing that one whole would
  // bloat this repo for no test benefit, and it names an unrelated video.
  const withTranscript = { transcript_only_text: '  Stop here first: Trevi Fountain, then the Pantheon.  ' };
  const text = await fetchYouTubeTranscript(
    { SCRAPECREATORS_API_KEY: 'k' }, 'x',
    () => ({ ok: true, json: async () => withTranscript }),
  );
  assert.equal(text, 'Stop here first: Trevi Fountain, then the Pantheon.');
});

test('the real reported Short has no transcript at all, not merely an unfetched one', async () => {
  const text = await fetchYouTubeTranscript(
    { SCRAPECREATORS_API_KEY: 'k' }, 'https://youtube.com/shorts/ikO_b8Wmtcc',
    () => ({ ok: true, json: async () => YOUTUBE_NO_TRANSCRIPT }),
  );
  assert.equal(text, null);
});

test('no SCRAPECREATORS key means no transcript call', async () => {
  let called = false;
  const text = await fetchYouTubeTranscript({}, 'x', () => { called = true; });
  assert.equal(text, null);
  assert.equal(called, false);
});

test('a vendor refusal or HTTP failure is null, not a thrown error', async () => {
  const refused = await fetchYouTubeTranscript(
    { SCRAPECREATORS_API_KEY: 'k' }, 'x',
    () => ({ ok: true, json: async () => ({ success: false, error: 'nope' }) }),
  );
  assert.equal(refused, null);

  const httpFailure = await fetchYouTubeTranscript(
    { SCRAPECREATORS_API_KEY: 'k' }, 'x',
    () => ({ ok: false, status: 500 }),
  );
  assert.equal(httpFailure, null);
});

test('a transcript longer than the cap is cut, not sent in full', async () => {
  const huge = { transcript_only_text: 'x'.repeat(MAX_TRANSCRIPT_CHARS + 5000) };
  const text = await fetchYouTubeTranscript(
    { SCRAPECREATORS_API_KEY: 'k' }, 'x',
    () => ({ ok: true, json: async () => huge }),
  );
  assert.equal(text.length, MAX_TRANSCRIPT_CHARS);
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

test('a place that is just the city restated is not a place', () => {
  // The real failure: a caption naming only where a reel was filmed came back
  // as one candidate, {name: "London", city: "London"}, and the app resolved
  // it literally, searching for "London, London". This is the filter that
  // catches it, whichever path the model answered on.
  assert.equal(isGenericPlace({ name: 'London', city: 'London' }), true);
  assert.equal(isGenericPlace({ name: 'london', city: 'London' }), true);
  assert.equal(isGenericPlace({ name: '  Paris ', city: ' paris ' }), true);
});

test('a real venue in its own city is not caught by the same filter', () => {
  assert.equal(isGenericPlace({ name: 'Tower of London', city: 'London' }), false);
  assert.equal(isGenericPlace({ name: 'Padella', city: 'London' }), false);
  assert.equal(isGenericPlace({ name: 'London' }), false);
  assert.equal(isGenericPlace({ name: 'London', city: '' }), false);
});

test('the media budget is a real number, not a placeholder', () => {
  // Eleven slides of a real carousel came to 2.6MB. A Worker has 128MB.
  assert.ok(MEDIA_BUDGET >= 4 * 1024 * 1024);
  assert.ok(MEDIA_BUDGET <= 32 * 1024 * 1024);
});
