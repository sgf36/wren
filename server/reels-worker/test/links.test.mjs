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

test('a photo post is accepted, not only a video', () => {
  // A carousel of slides, each naming a place in text, is the clearest case
  // this feature has — the names are already written down rather than said
  // out loud. Instagram serves those under the same /p/ shortcode as a single
  // photograph, and nothing in the link says which it is, so both are taken
  // and the difference is settled when the media is fetched.
  for (const url of [
    'https://www.instagram.com/p/Cx1yZ_aBcDe/',
    'https://instagram.com/p/Cx1yZ_aBcDe',
    'https://www.instagram.com/some.person/p/Cx1yZ_aBcDe/',
  ]) {
    const got = reelTarget(url);
    assert.ok(got, `refused ${url}`);
    assert.equal(got.platform, 'instagram');
    assert.equal(got.id, 'Cx1yZ_aBcDe');
  }
});

test('the link Instagram actually shares, from a real share', () => {
  // Captured on 6 September 2026 by sharing a post from the Instagram app on
  // an iPhone into Wren. Kept verbatim because every synthetic fixture above
  // was written by guessing at the shape, and this one was not.
  //
  // Note what Instagram appends. `stkn` is a share token identifying the
  // person who shared it, not the post, and it is dropped here rather than
  // forwarded to a vendor along with the request — the point of dropping the
  // query is that nobody has to remember which parameters are personal.
  const shared =
    'https://www.instagram.com/p/DcZzVx4Da6a/?stkn=MmZuc2ExdmJ3cmhp';
  const got = reelTarget(shared);
  assert.equal(got.platform, 'instagram');
  assert.equal(got.id, 'DcZzVx4Da6a');
  assert.equal(got.canonical, 'https://www.instagram.com/p/DcZzVx4Da6a/');
  assert.ok(!got.canonical.includes('stkn'), 'the share token was forwarded');
});

test('an Apple Maps guide link is not a reel', () => {
  // The app routes on this: a guide link must still reach the guide importer,
  // and a reel must not. Overlap here would break a shipped feature.
  assert.equal(reelTarget('https://maps.apple.com/?ug=abc123'), null);
});
