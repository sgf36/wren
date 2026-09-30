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
const SCRAPER = 'https://api.scrapecreators.com/v1';

/** A browser user agent, because Cloudflare edges answer 1010 to the defaults. */
export const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
  + 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

/**
 * How much media may be read in one post.
 *
 * A carousel can hold twenty slides and each is a few hundred kilobytes. The
 * cap is on bytes rather than count because that is what actually costs: a
 * Worker has 128MB and Gemini charges by the token. Twenty megabytes covers
 * most video reels while staying within the Vertex AI inline-data ceiling.
 */
export const MEDIA_BUDGET = 20 * 1024 * 1024;

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

/** The vendor path for each platform. */
const PATHS = {
  instagram: '/instagram/post',
  tiktok: '/tiktok/video',
  youtube: '/youtube/video',
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

  // Only Instagram is read in detail so far. The others answer with their own
  // shapes and are added as they are tested against a real post, rather than
  // guessed at from documentation.
  const post = target.platform === 'instagram' ? readInstagram(body) : null;
  if (!post) {
    const keys = body?.data ? Object.keys(body.data) : [];
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
