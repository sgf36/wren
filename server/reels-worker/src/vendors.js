/**
 * Getting the media, and getting the names out of it.
 *
 * Split from index.js because this is the only part that talks to somebody
 * else's service, and it is the part most likely to change when they change.
 * Everything it exports is pure or takes its fetcher as an argument, so the
 * shapes can be tested against real captured responses without an account.
 *
 * The order of work is deliberate and was decided by a real post rather than by
 * design. The first carousel tested — eleven slides of castle hotels — listed
 * all ten places in its caption as a numbered list. Reading that costs a few
 * hundred text tokens; reading the eleven images costs 2,772. Both were
 * measured. So the caption is tried first and the images are fetched only when
 * it yields nothing, because list-style posts are exactly the genre this
 * feature exists for and for them the expensive half is unnecessary.
 */

/**
 * Instagram, TikTok and YouTube through one vendor.
 *
 * One credit per request, and a cache hit costs nothing — so a post two people
 * share on the same day is paid for once.
 */
const SCRAPER = 'https://api.scrapecreators.com';

/** A browser user agent, because Cloudflare edges answer 1010 to the defaults. */
export const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
  + 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

/**
 * How much media may be INLINED in one request.
 *
 * A carousel can hold twenty slides and each is a few hundred kilobytes, and
 * those always fit here. Video is the case this stops covering: this number
 * has already been raised once (12MB to 20MB) for a longer reel to hit the
 * same wall a second time. It is Vertex's own request-size ceiling, not a
 * guess this Worker gets to make bigger -- a video over this goes to Cloud
 * Storage instead (see `MAX_VIDEO_BYTES` and `uploadToGCS` in index.js),
 * which has no comparable limit.
 */
export const MEDIA_BUDGET = 20 * 1024 * 1024;

/**
 * The absolute ceiling on a video, even through Cloud Storage.
 *
 * Not a technical limit -- a GCS object can be far larger -- a cost and abuse
 * ceiling. A reel is at most a few minutes; something claiming to be 200MB is
 * not a reel, and reading it would spend a Vertex call finding that out.
 */
export const MAX_VIDEO_BYTES = 200 * 1024 * 1024;

/** Slides beyond this are ignored however small they are. */
export const MAX_SLIDES = 20;

/**
 * What ScrapeCreators returned, reduced to what matters.
 *
 * Instagram's payload is a GraphQL shape with several names for the same idea,
 * so the reading of it lives here rather than being spread through the caller.
 * A shape that is not recognised yields nulls rather than throwing: the caller
 * decides what an empty post means, and it has better information for that.
 */
export function readInstagram(body) {
  const m = body?.data?.xdt_shortcode_media ?? body?.data?.shortcode_media ?? null;
  if (!m) return null;

  const caption = m.edge_media_to_caption?.edges?.[0]?.node?.text ?? '';
  const kids = m.edge_sidecar_to_children?.edges ?? [];

  // A sidecar is Instagram's word for a carousel. A single image or video has
  // no children and is its own node.
  const nodes = kids.length ? kids.map((k) => k.node) : [m];
  const images = [];
  let video = null;
  for (const n of nodes) {
    if (n.is_video && n.video_url) {
      video ??= n.video_url;
    } else if (n.display_url) {
      images.push(n.display_url);
    }
  }

  return {
    caption,
    video,
    images: images.slice(0, MAX_SLIDES),
    // Instagram's own alt text. Free, already written, and occasionally names
    // a place the image does not — so it is offered to the model as text.
    alts: nodes.map((n) => n.accessibility_caption).filter(Boolean),
  };
}

/**
 * What ScrapeCreators' TikTok endpoint returns, reduced to what matters.
 *
 * Captured against a real share, 2026-09-30 -- a London listicle whose
 * caption already named all eleven venues, the same "the caption is the
 * cheap half" shape the first Instagram carousel had. TikTok's own field is
 * `desc`, not `caption`.
 *
 * Video-only for now. TikTok also has a photo-mode ("slideshow") post shape,
 * presumably under `image_infos` -- it was `null` on the one real post
 * available, so its actual structure is unverified. Guessing at it is
 * exactly how the Instagram reader got written wrong three times; a post
 * with no video and no confirmed image shape reads as unreadable here, and
 * the caller offers screenshots instead, until a real example exists.
 */
export function readTikTok(body) {
  const a = body?.aweme_detail;
  if (!a) return null;

  const video = a.video?.download_no_watermark_addr?.url_list?.[0]
    ?? a.video?.play_addr_h264?.url_list?.[0]
    ?? a.video?.play_addr?.url_list?.[0]
    ?? null;
  if (!video) return null;

  return {
    caption: a.desc ?? '',
    video,
    images: [],
    alts: [],
  };
}

/**
 * YouTube's title and description, which is sometimes the whole answer.
 *
 * The free Data API (`videos.list`), not ScrapeCreators -- no vendor credit
 * spent, and a Short's own description regularly lists every place named on
 * screen, the same pattern that carried the first Instagram carousel and the
 * TikTok listicle both did. Video-only here: no `video` or `images` -- a post
 * whose description does not cooperate goes to `fetchYouTubeTranscript` next,
 * not a guessed-at media path. See that function's comment for why there is
 * no path onto the actual video.
 */
export async function fetchYouTubeSnippet(env, videoId, fetcher = fetch) {
  if (!env.YOUTUBE_API_KEY) return null;
  const url = 'https://www.googleapis.com/youtube/v3/videos?part=snippet'
    + `&id=${encodeURIComponent(videoId)}&key=${env.YOUTUBE_API_KEY}`;
  const res = await fetcher(url);
  if (!res.ok) {
    console.error('youtube api http', res.status);
    return null;
  }

  const body = await res.json();
  const snippet = body?.items?.[0]?.snippet;
  if (!snippet) return null;

  return {
    caption: [snippet.title, snippet.description].filter(Boolean).join('\n\n'),
    video: null,
    images: [],
    alts: [],
  };
}

/**
 * How much transcript text may be sent to the model in one call.
 *
 * Plain text costs far less per byte than the image and video tokens
 * everywhere else in this file, but a long-form video's transcript can run to
 * tens of thousands of characters -- the one real example captured while
 * building this ran 25,701. This is a generous cap on a genuine cost, not an
 * arbitrary one: at Flash-Lite's per-token price even the full cap is a
 * fraction of a cent, and a Short is a minute at most, so anything this long
 * is already most of a real transcript's worth of narration.
 */
export const MAX_TRANSCRIPT_CHARS = 20000;

/**
 * YouTube's transcript, tried when the title and description say nothing.
 *
 * Free-ish -- `credits_charged` came back 0 on both real calls made while
 * building this -- and it catches a Short whose voiceover names places its
 * on-screen text and its description both leave out. `transcript_only_text`
 * is ScrapeCreators' own flattened field, confirmed against a real caption
 * track (Arabic, auto-generated, 2026-09-30) rather than assembled from the
 * timed `transcript` array this endpoint also returns.
 *
 * This is not the video. It is the honest second-best available today: the
 * actual on-screen text a Short like the one that prompted this file's
 * existence relies on ("3. Sky Garden") is invisible to a transcript, and
 * that specific video turned out to have no transcript at all -- confirmed,
 * not assumed; `captionTracks` came back empty for it. A video with genuine
 * narration is what this is for.
 */
export async function fetchYouTubeTranscript(env, canonicalUrl, fetcher = fetch) {
  if (!env.SCRAPECREATORS_API_KEY) return null;
  const url = `${SCRAPER}/v1/youtube/video/transcript`
    + `?url=${encodeURIComponent(canonicalUrl)}`;
  const res = await fetcher(url, {
    headers: { 'x-api-key': env.SCRAPECREATORS_API_KEY, 'User-Agent': UA },
  });
  if (!res.ok) {
    console.error('youtube transcript http', res.status);
    return null;
  }

  const body = await res.json();
  if (body?.success === false) {
    console.error('youtube transcript refused', body?.error ?? '(no detail)');
    return null;
  }

  const text = body?.transcript_only_text;
  if (!text || !text.trim()) return null;
  return text.trim().slice(0, MAX_TRANSCRIPT_CHARS);
}

/**
 * The vendor path for each platform, versioned per-platform because the
 * versions do not agree. `/v1/tiktok/video` looks like a URL that should
 * exist and instead 404s with a bare "Not Found" (no JSON, no error body) --
 * confirmed 2026-09-30 against a real share that had never worked. TikTok's
 * video endpoint is `/v2`; ScrapeCreators' own docs, not this file, are the
 * only place that says so.
 */
const PATHS = {
  instagram: '/v1/instagram/post',
  tiktok: '/v2/tiktok/video',
  youtube: '/v1/youtube/video',
};

/**
 * Asks the vendor for one post.
 *
 * `fetcher` is injected so the tests can hand back a captured response. In
 * production it is fetch.
 */
export async function fetchPost(env, target, fetcher = fetch) {
  const path = PATHS[target.platform];
  if (!path || !env.SCRAPECREATORS_API_KEY) return null;

  const url = `${SCRAPER}${path}?url=${encodeURIComponent(target.canonical)}`;
  const res = await fetcher(url, {
    headers: { 'x-api-key': env.SCRAPECREATORS_API_KEY, 'User-Agent': UA },
  });
  if (!res.ok) {
    console.error('vendor http', res.status, target.canonical);
    return null;
  }

  const body = await res.json();
  if (body?.success === false) {
    console.error('vendor refused', target.canonical, body?.error ?? '(no detail)');
    return null;
  }

  // Instagram and TikTok are read in detail. YouTube answers with its own
  // shape and is added once it is tested against a real post, rather than
  // guessed at from documentation -- the same rule that made the Instagram
  // reader wrong three times before a captured example fixed it.
  const post = target.platform === 'instagram' ? readInstagram(body)
    : target.platform === 'tiktok' ? readTikTok(body)
    : null;
  if (!post) {
    // Instagram's shape nests under `data`; TikTok's does not. Falling back
    // to the top-level keys means this stays useful for whichever platform
    // just failed, instead of reporting `[]` for every TikTok miss.
    const keys = Object.keys(body?.data ?? body ?? {});
    console.error('unreadable shape', target.canonical, keys);
    return null;
  }
  return { ...post, credits: body?.credits_charged ?? null };
}

/**
 * Downloads the slides, stopping at the budget.
 *
 * Returns what it managed to get rather than failing on one bad url: a
 * carousel with a single expired image is still nine readable slides, and
 * refusing the lot would be a worse answer than a slightly shorter one.
 */
export async function fetchImages(urls, fetcher = fetch, budget = MEDIA_BUDGET) {
  const parts = [];
  let spent = 0;
  for (const url of urls) {
    if (spent >= budget) break;
    try {
      const res = await fetcher(url, { headers: { 'User-Agent': UA } });
      if (!res.ok) continue;
      const bytes = new Uint8Array(await res.arrayBuffer());
      if (spent + bytes.length > budget) break;
      spent += bytes.length;
      parts.push({
        inlineData: {
          mimeType: res.headers.get('content-type')?.split(';')[0] || 'image/jpeg',
          data: toB64(bytes),
        },
      });
    } catch {
      // One slide that will not load is not a failed post.
    }
  }
  return parts;
}

/** Base64 in chunks, because a 300KB spread hits the argument limit. */
function toB64(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(s);
}

/**
 * What the model is asked, and why it is asked twice.
 *
 * The caption prompt and the media prompt differ in one respect that matters: a
 * caption is written by a person and often lists places plainly, while an image
 * has to be read. Asking the same question of both would waste the caption's
 * structure.
 */
export const CAPTION_PROMPT =
  'This is the caption of a social media post. List every place a person could '
  + 'visit that it names: restaurants, bars, cafes, hotels, shops, landmarks. '
  + 'A city, region or country named by itself is not a place somebody can walk '
  + 'into -- only list it as the "city" of a specific business, venue or '
  + 'landmark named alongside it, never as a place in its own right. '
  + 'Include the city or country if the caption states it. Ignore hashtags, '
  + 'usernames and anything that is not a place somebody could go. If it names '
  + 'no such place, return an empty list.';

export const MEDIA_PROMPT =
  'These are the slides or frames of one social media post, in order. Read the '
  + 'text in them, and any speech, and list every place a person could visit: '
  + 'restaurants, bars, cafes, hotels, shops, landmarks. A city, region or '
  + 'country named by itself is not a place somebody can walk into -- only list '
  + 'it as the "city" of a specific business, venue or landmark named alongside '
  + 'it, never as a place in its own right. Include the city or country where '
  + 'it is stated. Ignore usernames, hashtags and app interface text. If a city '
  + 'is named once, it applies to the places after it.';

/**
 * Whether a "place" the model returned is really just the city or region
 * restated, not somewhere a person can walk into.
 *
 * Found on a real post: a caption that only said where it was filmed came back
 * from the model as one candidate, `{name: "London", city: "London"}`. Because
 * the caption path treats any non-empty answer as proof the caption was enough,
 * that single self-referential entry passed as a reading and skipped the video
 * entirely -- where the actual venues were. The two prompts above now say not
 * to do this; this filter is the backstop for when the model does it anyway,
 * on either path.
 */
export function isGenericPlace(p) {
  const name = String(p?.name || '').trim().toLowerCase();
  const city = String(p?.city || '').trim().toLowerCase();
  return Boolean(name) && Boolean(city) && name === city;
}

/**
 * The city the whole post is about, or nothing.
 *
 * Feeds the same confirmation screen as region_hint.dart does for screenshots,
 * where the hint decides which city the resolver searches first. A wrong hint
 * is therefore worse than no hint: it aims every lookup at the wrong place.
 *
 * So a plurality is not enough — a majority is required. The first real post
 * tested named ten castle hotels across seven countries, and taking the most
 * common answer returned "Ireland" on the strength of two of them. Two out of
 * ten is not what the post is about. A post with no single answer should say
 * so, and let the person choose.
 */
export function regionOf(places) {
  const counted = new Map();
  let named = 0;
  for (const p of places) {
    const city = (p.city || '').trim();
    if (!city) continue;
    named += 1;
    counted.set(city, (counted.get(city) ?? 0) + 1);
  }
  if (!named) return null;

  let best = null;
  let most = 0;
  for (const [city, n] of counted) {
    if (n > most) {
      best = city;
      most = n;
    }
  }
  // More than half of the places that named anywhere have to agree.
  return most * 2 > named ? best : null;
}
