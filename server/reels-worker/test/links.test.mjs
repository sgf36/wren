/**
 * What /process will and will not fetch.
 *
 * This is the security boundary of the whole Worker, not a parsing
 * convenience. Everything past it spends money against a vendor key on a URL
 * somebody else chose, so a pattern that is a little too generous turns the
 * endpoint into an open proxy funded by Wren. The negative cases below matter
 * more than the positive ones.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { reelTarget } from '../src/index.js';

test('the three platforms, in the forms their share sheets actually produce', () => {
  const cases = [
    ['https://www.instagram.com/reel/Cx1yZ_aBcDe/', 'instagram'],
    ['https://instagram.com/reels/Cx1yZ_aBcDe', 'instagram'],
    ['https://www.instagram.com/p/Cx1yZ_aBcDe/', 'instagram'],
    ['https://www.instagram.com/tv/Cx1yZ_aBcDe/', 'instagram'],
    ['https://instagr.am/reel/Cx1yZ_aBcDe/', 'instagram'],
    ['https://www.instagram.com/some.person/reel/Cx1yZ_aBcDe/', 'instagram'],
    ['https://www.tiktok.com/@some.person/video/7234567890123456789', 'tiktok'],
    ['https://www.tiktok.com/t/ZTdAbCdEf/', 'tiktok'],
    ['https://vm.tiktok.com/ZTdAbCdEf/', 'tiktok'],
    ['https://vt.tiktok.com/ZTdAbCdEf', 'tiktok'],
    ['https://www.youtube.com/shorts/dQw4w9WgXcQ', 'youtube'],
    ['https://youtu.be/dQw4w9WgXcQ', 'youtube'],
    ['https://m.youtube.com/shorts/dQw4w9WgXcQ', 'youtube'],
  ];
  for (const [url, platform] of cases) {
    const got = reelTarget(url);
    assert.ok(got, `refused ${url}`);
    assert.equal(got.platform, platform, url);
  }
});

test('a link inside a sentence, which is what Android hands over', () => {
  // EXTRA_TEXT from Instagram and TikTok is routinely a caption with the URL
  // somewhere in it. Assuming the whole string is a URL loses every Android
  // share, and the failure looks like "the app does not support TikTok".
  const shared = 'Check this out https://vm.tiktok.com/ZTdAbCdEf/ so good';
  assert.equal(reelTarget(shared).platform, 'tiktok');
});

test('query and fragment are dropped rather than forwarded', () => {
  // igshid identifies the person who shared it. Passing it to a vendor would
  // forward something nobody asked to send, and it is no use for fetching.
  const got = reelTarget(
    'https://www.instagram.com/reel/Cx1yZ_aBcDe/?igshid=abc123&utm_source=ig#x');
  assert.equal(got.canonical, 'https://www.instagram.com/reel/Cx1yZ_aBcDe/');
});

test('everything that is not a video is refused', () => {
  const refused = [
    // Profiles, hashtags and the platforms' own furniture. These are what
    // people share by accident, and each one would cost a vendor call.
    'https://www.instagram.com/some.person/',
    'https://www.instagram.com/explore/tags/london/',
    'https://www.tiktok.com/@some.person',
    'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    'https://www.youtube.com/',
    // Somewhere else entirely, which is the open-proxy case.
    'https://example.com/reel/abc',
    'https://instagram.com.evil.example/reel/abc',
    'https://evil.example/?u=https://instagram.com/reel/abc',
    // http, refused rather than upgraded: every one of these hosts serves
    // https, so plain http means something rewrote the URL.
    'http://www.instagram.com/reel/Cx1yZ_aBcDe/',
    // Not links at all.
    '',
    'not a url',
    'javascript:alert(1)',
    null,
    undefined,
  ];
  for (const url of refused) {
    assert.equal(reelTarget(url), null, `accepted ${url}`);
  }
});

test('an Apple Maps guide link is not a reel', () => {
  // The app routes on this: a guide link must still reach the guide importer,
  // and a reel must not. Overlap here would break a shipped feature.
  assert.equal(reelTarget('https://maps.apple.com/?ug=abc123'), null);
});
