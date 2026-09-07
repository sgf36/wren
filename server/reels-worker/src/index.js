/**
 * Turning a shared reel into place names, for Wren.
 *
 * The app cannot do this on the phone. What Instagram, TikTok and YouTube put
 * in a share sheet is a URL and never the video, so the only way to read what
 * is burned into a reel's frames, or said out loud in it, is to fetch the video
 * from somewhere — and fetching it needs a vendor, a key and a network posture
 * that has no business inside a shipped app. Hence a server.
 *
 * What the server returns is deliberately thin: candidate place *names* and a
 * region hint. Not coordinates, not place ids, not media. The device resolves
 * names exactly as it already resolves the ones read off a screenshot — MapKit
 * on iPhone, the system geocoder on Android — and shows the same confirmation
 * screen, which is where the app's accuracy actually comes from. Keeping the
 * resolution on the device is also what keeps this feature inside Apple's
 * rules: Wren never delivers the video to anybody, and never stores it.
 *
 * Three identities may call /process, and none of them is a device:
 *
 *   appstore  a StoreKit 2 signed transaction, verified offline against Apple's
 *             certificate chain. Its originalTransactionId is the identity.
 *   play      a Play purchase token, verified online against androidpublisher
 *             and then cached, because Google rate-limits and a reel should not
 *             wait on it twice.
 *   comp      an Ed25519 token this project's other Worker signed, carrying a
 *             role. Only 'everything' and 'admin' reach this feature; an
 *             ordinary 'unlock' is guides and exports. App Review's code must
 *             therefore be issued as 'everything'.
 *
 * The identity matters because quota hangs off it. A one-time purchase for a
 * feature with a per-use cost needs a lid, and a lid keyed on the device is not
 * a lid: Android device ids do not survive an uninstall. Apple's
 * originalTransactionId and Google's purchase token both do.
 */

import {
  fetchPost, fetchImages, regionOf, UA, MEDIA_BUDGET,
  CAPTION_PROMPT, MEDIA_PROMPT,
} from './vendors.js';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  });

/**
 * Every failure the client is allowed to see.
 *
 * The app localises on these strings, so they are an interface and not log
 * text. Nothing here names a vendor or repeats an upstream message: which
 * scraper Wren pays is not the user's business, and an error string is the
 * classic way a detail like that reaches a screenshot in a review.
 */
export const FAILURES = Object.freeze({
  unsupportedHost: 'unsupported_host',
  notEntitled: 'not_entitled',
  quotaExceeded: 'quota_exceeded',
  busy: 'busy',
  postUnavailable: 'post_unavailable',
  fetchFailed: 'fetch_failed',
  modelFailed: 'model_failed',
  // Neither of these is a fault of the customer's, and the shipped 2.0 client
  // does not know them: `_failureOf` maps anything unrecognised to
  // `fetchFailed`, which tells them Wren could not read the post and to share
  // screenshots instead. That is true, free, and works on anything -- so a
  // capacity stop degrades into honest advice rather than a dead end. They are
  // distinct on the wire so the logs say which happened.
  capacityReached: 'capacity_reached',
  disabled: 'disabled',
});

export class Refusal extends Error {
  constructor(code, status = 400, extra = {}) {
    super(code);
    this.code = code;
    this.status = status;
    this.extra = extra;
  }
}

/* ------------------------------------------------------------------ links */

/**
 * The shapes of link this will accept, and nothing else.
 *
 * An allowlist rather than a pattern, for the same reason `guide_expand.dart`
 * keeps one: /process makes an outbound request on the caller's say-so, and an
 * endpoint that fetches whatever it is handed is an open proxy sitting behind
 * somebody's paid API key. Matching on host *and* path shape also throws out
 * the profile and hashtag links people share by accident, before they cost
 * anything.
 */
const PATTERNS = [
  {
    platform: 'instagram',
    hosts: ['instagram.com', 'www.instagram.com', 'instagr.am', 'www.instagr.am'],
    path: /^\/(?:reels?|p|tv)\/([A-Za-z0-9_-]+)\/?$/,
  },
  {
    // Instagram also serves a reel under the author's handle.
    platform: 'instagram',
    hosts: ['instagram.com', 'www.instagram.com'],
    path: /^\/[A-Za-z0-9_.]+\/(?:reels?|p)\/([A-Za-z0-9_-]+)\/?$/,
  },
  {
    platform: 'tiktok',
    hosts: ['tiktok.com', 'www.tiktok.com'],
    path: /^\/@[A-Za-z0-9_.]+\/video\/(\d+)\/?$/,
  },
  {
    platform: 'tiktok',
    hosts: ['tiktok.com', 'www.tiktok.com'],
    path: /^\/t\/([A-Za-z0-9]+)\/?$/,
  },
  {
    // The share sheet's own short form, which is what most shares actually are.
    platform: 'tiktok',
    hosts: ['vm.tiktok.com', 'vt.tiktok.com'],
    path: /^\/([A-Za-z0-9]+)\/?$/,
  },
  {
    platform: 'youtube',
    hosts: ['youtube.com', 'www.youtube.com', 'm.youtube.com'],
    path: /^\/shorts\/([A-Za-z0-9_-]{5,})\/?$/,
  },
  {
    platform: 'youtube',
    hosts: ['youtu.be'],
    path: /^\/([A-Za-z0-9_-]{5,})\/?$/,
  },
];

/**
 * Reads a shared string and returns what to fetch, or null.
 *
 * A post is as welcome as a reel. An Instagram /p/ shortcode is a carousel of
 * photographs as often as it is a single one, and a set of slides each naming a
 * place in text is exactly the thing this feature is for — arguably more so
 * than video, since the names are already written down. What kind of media sits
 * behind the link is not knowable from the link, so it is not decided here.
 *
 * Takes a string rather than a URL because what arrives is rarely just a link.
 * Android's EXTRA_TEXT routinely carries a sentence with the URL somewhere
 * inside it, and both platforms hang tracking parameters off the end. The first
 * URL in the text wins, and the query and fragment are dropped — they identify
 * the sharer, not the video, and forwarding them to a vendor would pass along
 * something nobody asked to send.
 */
export function reelTarget(raw) {
  const text = String(raw || '');
  const found = text.match(/https?:\/\/[^\s<>"']+/i);
  if (!found) return null;

  let uri;
  try {
    uri = new URL(found[0]);
  } catch {
    return null;
  }
  // Plain http is refused rather than upgraded. Every one of these hosts serves
  // https, so an http link is a sign of something rewriting the URL.
  if (uri.protocol !== 'https:') return null;

  const host = uri.hostname.toLowerCase();
  const path = uri.pathname.replace(/\/{2,}/g, '/');

  for (const p of PATTERNS) {
    if (!p.hosts.includes(host)) continue;
    const m = path.match(p.path);
    if (m) {
      return {
        platform: p.platform,
        id: m[1],
        canonical: `https://${host}${path}`,
      };
    }
  }
  return null;
}

/* ----------------------------------------------------------- entitlement */

const SPKI_ED25519_PREFIX = Uint8Array.from([
  0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
]);

const fromB64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const fromB64Url = (s) =>
  fromB64(s.replace(/-/g, '+').replace(/_/g, '/')
    .padEnd(s.length + ((4 - (s.length % 4)) % 4), '='));

/**
 * A comp token, verified against the same public key the app carries.
 *
 * Copied from wren-codes deliberately rather than shared. Two Workers verifying
 * one signature is duplication, but a shared package between two separately
 * deployed Workers is a thing that gets upgraded on one side only. The key is a
 * var in both wrangler.toml files, and a test below pins the two together so
 * that a change to one is a failure rather than a silent divergence.
 */
export async function verifiedComp(env, token) {
  const [body, sig] = String(token || '').split('.');
  if (!body || !sig) return null;

  const spki = new Uint8Array(SPKI_ED25519_PREFIX.length + 32);
  spki.set(SPKI_ED25519_PREFIX);
  spki.set(fromB64(env.WREN_PUBLIC_KEY), SPKI_ED25519_PREFIX.length);

  const key = await crypto.subtle.importKey('spki', spki, { name: 'Ed25519' },
    false, ['verify']);
  const payload = fromB64Url(body);
  const ok = await crypto.subtle.verify({ name: 'Ed25519' }, key,
    fromB64Url(sig), payload);
  if (!ok) return null;

  try {
    return JSON.parse(new TextDecoder().decode(payload));
  } catch {
    return null;
  }
}

/**
 * Products that carry the reel entitlement, on either store.
 *
 * Two, not three, and the same two on both stores. `everything` is what
 * somebody who owns nothing buys; `reels.upgrade` is what somebody who already
 * owns `unlimited` buys, and owning both is the same thing as owning
 * `everything`. Non-consumables have no native upgrade mechanism, so which of
 * the two a person is offered is a decision the paywall makes from what they
 * already own — not something this list expresses.
 *
 * `unlimited` is deliberately absent. It is the existing purchase, it removes
 * the three-place cap on guides and exports, and it grants nothing here. An
 * id listed in this array is an id that unlocks a feature costing real money
 * per call, so an unused entry left in "just in case" is a product that would
 * silently grant the moment anybody created it.
 */
/**
 * Comp-code roles that carry the reel entitlement.
 *
 * Mirrors the ladder in the codes Worker, where 'unlock' is guides and exports
 * and 'everything' adds reels. Held as its own list rather than inferred from
 * that one, so adding a role there cannot silently grant a paid feature here.
 */
export const COMP_ROLES_WITH_REELS = Object.freeze(['everything', 'admin']);
/** What each service account may reach, and nothing wider. */
export const PLAY_SCOPE = 'https://www.googleapis.com/auth/androidpublisher';
export const VERTEX_SCOPE = 'https://www.googleapis.com/auth/cloud-platform';
export const REEL_PRODUCTS = Object.freeze([
  'com.spencerfields.littlebird.everything',
  'com.spencerfields.littlebird.reels.upgrade',
]);

/** The bundle these purchases must belong to. */
export const BUNDLE_ID = 'com.spencerfields.littlebird';

/**
 * A StoreKit 2 signed transaction, verified offline.
 *
 * Apple's own library does the work. Reimplementing an X.509 chain walk over
 * WebCrypto was considered and rejected: the failure mode of a subtly wrong
 * verifier is that it accepts a forged transaction, which is silent, permanent
 * and worth money. `nodejs_compat` exists so that Apple's implementation can be
 * used as written.
 *
 * `enableOnlineChecks` is off. It performs an OCSP revocation lookup, which is
 * unreliable from a Worker and turns a verification into a network call with
 * somebody else's uptime attached. Revocation is read from the claim instead: a
 * refunded transaction carries a revocationDate.
 */
export async function verifyApple(env, jws) {
  const { SignedDataVerifier, Environment } = await import(
    '@apple/app-store-server-library');

  // Sandbox is tried only where a var says to. A sandbox transaction is free to
  // mint, so a production Worker that accepts one sells nothing.
  const environments = String(env.ACCEPT_SANDBOX) === 'true'
    ? [Environment.PRODUCTION, Environment.SANDBOX]
    : [Environment.PRODUCTION];

  let claim = null;
  for (const environment of environments) {
    const verifier = new SignedDataVerifier(
      appleRootCertificates(env),
      false,
      environment,
      BUNDLE_ID,
    );
    try {
      claim = await verifier.verifyAndDecodeTransaction(jws);
      break;
    } catch {
      // The wrong environment reads as a verification failure, so the loop
      // tries the other rather than treating the first refusal as final.
      claim = null;
    }
  }
  if (!claim) return null;

  // Checked here rather than trusted from the signature. A valid signature
  // proves Apple issued the transaction — not that it was issued to this app,
  // for a product that grants anything, and that it is still live.
  if (claim.bundleId !== BUNDLE_ID) return null;
  if (!REEL_PRODUCTS.includes(claim.productId)) return null;
  if (claim.revocationDate) return null;

  return {
    key: `appstore:${claim.originalTransactionId}`,
    store: 'appstore',
    productId: claim.productId,
  };
}

/**
 * Apple's root certificate, as DER.
 *
 * Held as configuration rather than fetched, because a verifier that downloads
 * its own trust anchor trusts whatever answers. Apple has shipped chains with
 * expired intermediates before — October 2025 — which is why online checks stay
 * off and expiry is judged against the signing date.
 */
function appleRootCertificates(env) {
  const pem = String(env.APPLE_ROOT_CA_G3 || '');
  if (!pem) return [];
  return [Buffer.from(pem.replace(/-----[^-]+-----/g, '').replace(/\s/g, ''),
    'base64')];
}

/**
 * A Play purchase token, verified against androidpublisher.
 *
 * Online, unlike Apple, because Google gives no offline artefact to check: the
 * token is an opaque handle and the only thing that knows whether it is real is
 * Google. The answer is cached in D1 so this happens once per purchase rather
 * than once per reel.
 */
export async function verifyPlay(env, purchaseToken, productId) {
  if (!REEL_PRODUCTS.includes(productId)) return null;
  if (!purchaseToken) return null;

  const token = await accessToken(env.PLAY_SA_KEY, PLAY_SCOPE);
  if (!token) return null;

  const url = 'https://androidpublisher.googleapis.com/androidpublisher/v3/'
    + `applications/${BUNDLE_ID}/purchases/products/`
    + `${encodeURIComponent(productId)}/tokens/`
    + `${encodeURIComponent(purchaseToken)}`;

  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!res.ok) return null;
  const body = await res.json();

  // 0 is purchased, 1 is cancelled, 2 is pending. Only 0 grants anything, and
  // pending is explicitly not a purchase: Play's slow payment methods sit at 2
  // for days and settle either way.
  if (body.purchaseState !== 0) return null;

  return { key: `play:${purchaseToken}`, store: 'play', productId };
}

/**
 * A service-account bearer token for a Google API, minted here.
 *
 * Google's Node SDK is large and mostly concerned with things a Worker cannot
 * do. What is actually needed is one RS256 JWT and one form post, both of which
 * WebCrypto does.
 *
 * Takes the key and the scope rather than reading one variable, because two
 * different service accounts use this: androidpublisher for verifying Play
 * purchases, and cloud-platform for calling Vertex. They are deliberately
 * separate accounts — the one that reads purchases has no business reaching a
 * model, and neither should be the key that publishes releases, which can also
 * replace the app.
 */
export async function accessToken(saKey, scope) {
  if (!saKey) return null;

  // Base64 is the documented form, and raw JSON is what somebody reaches for
  // when setting the secret by hand. Both are accepted because the two are
  // trivially distinguishable and the alternative is not a clean refusal: a
  // JSON key put through fromB64 yields rubbish, JSON.parse throws, and the
  // Worker answers 500 to a request that was correct.
  const text = saKey.trimStart().startsWith('{')
    ? saKey
    : new TextDecoder().decode(fromB64(saKey));
  const sa = JSON.parse(text);
  const now = Math.floor(Date.now() / 1000);

  const seg = (o) => btoa(JSON.stringify(o))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const unsigned = `${seg({ alg: 'RS256', typ: 'JWT' })}.${seg({
    iss: sa.client_email,
    scope,
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  })}`;

  const der = fromB64(sa.private_key
    .replace(/-----[^-]+-----/g, '').replace(/\s/g, ''));
  const key = await crypto.subtle.importKey('pkcs8', der,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key,
    new TextEncoder().encode(unsigned));
  const jwt = `${unsigned}.${btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')}`;

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });
  if (!res.ok) return null;
  return (await res.json()).access_token ?? null;
}

/**
 * Resolves whichever identity was presented into one shape, or nothing.
 *
 * Fails closed everywhere. An unrecognised `kind`, a malformed token and a
 * verifier that threw all land on the same refusal, because the alternative —
 * reading "could not tell" as "probably fine" — is how a paid feature quietly
 * becomes a free one.
 */
export async function identify(env, auth) {
  try {
    if (auth?.kind === 'comp') {
      const claims = await verifiedComp(env, auth.token);
      if (!claims?.c) return null;
      // Not every comp code reaches this feature. A code carries a role, and
      // reels cost money on every use, so only the roles that name them grant
      // them. An ordinary 'unlock' is guides and exports, as it has always
      // been, and a token minted before roles existed carries no role at all
      // and reads as that.
      //
      // The consequence worth remembering: App Review's code must be issued as
      // 'everything'. A reviewer following the notes into a paywall rejects the
      // build, and the rejection will not say it was about a comp code.
      if (!COMP_ROLES_WITH_REELS.includes(claims.r)) return null;
      return { key: `comp:${claims.c}`, store: 'comp', productId: null };
    }
    if (auth?.kind === 'appstore') return await verifyApple(env, auth.jws);
    if (auth?.kind === 'play') {
      return await verifyPlay(env, auth.purchaseToken, auth.productId);
    }
  } catch {
    return null;
  }
  return null;
}

/* ------------------------------------------------------------------ quota */

export const THIRTY_DAYS = 30 * 24 * 60 * 60;

/**
 * What this identity has spent in the trailing thirty days.
 *
 * Rolling rather than calendar. A calendar month resets everybody at midnight
 * on the first, which concentrates the whole user base's cost into one day and
 * hands somebody who buys on the 30th a full quota for two days.
 */
export async function quotaState(env, db, key, now = Date.now()) {
  const limit = Number(env.QUOTA_PER_30_DAYS || 250);
  const since = Math.floor(now / 1000) - THIRTY_DAYS;
  const row = await db.prepare(
    'SELECT COUNT(*) AS n, MIN(ts) AS oldest FROM usage '
    + 'WHERE auth_key = ?1 AND ts >= ?2',
  ).bind(key, since).first();

  const used = Number(row?.n || 0);
  // Quota frees up when the oldest call in the window ages out, not on a fixed
  // date. That is what "rolling" means, and what the copy has to say.
  const resetsAt = row?.oldest
    ? (Number(row.oldest) + THIRTY_DAYS) * 1000
    : null;

  return { used, limit, resetsAt, exhausted: used >= limit };
}

/**
 * Everything this Worker has served in the trailing 24 hours, across everybody.
 *
 * The per-identity quota above bounds what ONE customer can cost. Nothing
 * bounded the total, and the two failure modes that matter are not customers
 * behaving normally: a purchase token shared around, or a bug that retries. The
 * feature costs real money per call -- a ScrapeCreators credit and Vertex
 * tokens -- and the bill arrives after the fact.
 *
 * Deliberately a count and not a currency estimate. Money would need per-call
 * token accounting and a price table that goes stale silently; a count is
 * exact, and the price per call is known well enough to convert by hand.
 *
 * The default is set far above plausible early use and far below a runaway: at
 * 250 per customer per thirty days, 1000 a day is roughly 120 customers using
 * their entire allowance every single day. If it ever binds legitimately that
 * is a good problem, and it is one line of `wrangler deploy` to raise.
 */
export async function globalUsage(env, db, now = Date.now()) {
  const limit = Number(env.GLOBAL_DAILY_LIMIT || 1000);
  const since = Math.floor(now / 1000) - 24 * 60 * 60;
  const row = await db.prepare(
    'SELECT COUNT(*) AS n FROM usage WHERE ts >= ?1',
  ).bind(since).first();
  const used = Number(row?.n || 0);
  return { used, limit, exhausted: used >= limit };
}

/* -------------------------------------------------------------- the model */

/**
 * The only models this Worker will call.
 *
 * An allowlist rather than a default, because the difference between a
 * Flash-Lite model and a premium one is not a difference of degree. Gemini
 * tokenises video by the second, and a premium model at full resolution runs to
 * roughly $0.10 for every second of a reel — about $4.50 for a forty-five second
 * one, against $0.0016 here. That is a thousandfold, on a feature paid for once
 * and used for ever, and it would arrive as a bill rather than as an error.
 *
 * So the model is not a string somebody can edit in a hurry. A name that is not
 * on this list stops the request.
 */
export const ALLOWED_MODELS = Object.freeze(['gemini-3.5-flash-lite']);

/**
 * Low, always.
 *
 * The other half of the same arithmetic. Media resolution decides how many
 * tokens a second of video becomes, and the difference between low and default
 * is several times the cost of every call. There is no configuration for it and
 * no environment override: a reel read at low resolution has been the plan since
 * the costs were worked out, and anything that wanted to change it should have
 * to change this line and answer for it.
 */
export const MEDIA_RESOLUTION = 'MEDIA_RESOLUTION_LOW';

/** What the model is asked to return, so the answer needs no parsing. */
export const RESPONSE_SCHEMA = Object.freeze({
  type: 'ARRAY',
  items: {
    type: 'OBJECT',
    properties: {
      name: { type: 'STRING' },
      city: { type: 'STRING' },
      kind: { type: 'STRING' },
    },
    required: ['name'],
  },
});

/**
 * Builds the call, and refuses to build a ruinous one.
 *
 * Every request goes through here so that the two settings that decide the cost
 * are asserted in one place rather than repeated at each call site — the second
 * copy of a rule is where it stops being true.
 */
export function modelRequest(env, parts) {
  const model = env.GEMINI_MODEL || ALLOWED_MODELS[0];
  if (!ALLOWED_MODELS.includes(model)) {
    // Deliberately not a soft fallback to a safe model. Something has been
    // configured that nobody costed, and running anyway would hide it.
    throw new Refusal(FAILURES.modelFailed, 500);
  }
  return {
    model,
    body: {
      contents: [{ role: 'user', parts }],
      generationConfig: {
        mediaResolution: MEDIA_RESOLUTION,
        temperature: 0,
        responseMimeType: 'application/json',
        responseSchema: RESPONSE_SCHEMA,
      },
    },
  };
}

/**
 * Where the model is called, and why it is not AI Studio.
 *
 * AI Studio bills Gemini through a separate prepay payments account, even when
 * the Cloud billing account behind it is postpay. That prepay account is
 * created by one dialog, that dialog does not render, and no other surface can
 * create or fund what it never made — confirmed with Google support on
 * 6 September 2026, and a GBP 10 payment landed as Cloud credit rather than
 * Gemini prepay because of it.
 *
 * Vertex serves the same models and bills through the ordinary Cloud billing
 * account, which works. So the prepay mechanism is not worked around here, it
 * is simply not in the path.
 *
 * The cost of the two is expected to match and is NOT yet verified: Google's
 * pricing pages would not give it up, and the account's own SKU browser does
 * not filter. The honest way to settle it is the first real call — the cost
 * table then shows the SKU and rate actually charged, in the right currency and
 * region. Do that before assuming §12 still holds.
 */
export function vertexEndpoint(env, model) {
  const project = env.VERTEX_PROJECT;
  const location = env.VERTEX_LOCATION || 'global';
  if (!project) return null;
  // `global` is not a region and has no region prefix on the host. It is also
  // the only place 3.5 Flash-Lite exists: europe-west1, europe-west4 and
  // us-central1 all answer 404 for it while happily serving 2.5. Measured, not
  // assumed — the first smoke test failed on exactly this.
  const host = location === 'global'
    ? 'aiplatform.googleapis.com'
    : `${location}-aiplatform.googleapis.com`;
  return `https://${host}/v1/projects/`
    + `${project}/locations/${location}/publishers/google/models/`
    + `${model}:generateContent`;
}

/**
 * One model call, with the cost guards already applied by modelRequest.
 *
 * Returns the parsed candidates, or throws a Refusal the client can localise.
 * Nothing from Google's error body reaches the caller: it can name a project, a
 * region and a service account, none of which is the user's business.
 */
export async function readPlaces(env, parts) {
  const { model, body } = modelRequest(env, parts);
  const url = vertexEndpoint(env, model);
  const token = await accessToken(env.VERTEX_SA_KEY, VERTEX_SCOPE);
  if (!url || !token) throw new Refusal(FAILURES.modelFailed, 503);

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    console.error('model call failed', res.status);
    throw new Refusal(FAILURES.modelFailed, 502);
  }

  const answer = await res.json();
  const text = answer?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) throw new Refusal(FAILURES.modelFailed, 502);

  let places;
  try {
    places = JSON.parse(text);
  } catch {
    // responseSchema asks for JSON, so this means the model ignored it. Better
    // a refusal the app can explain than a half-parsed list of place names.
    throw new Refusal(FAILURES.modelFailed, 502);
  }
  return Array.isArray(places) ? places.filter((p) => p && p.name) : [];
}

/* ------------------------------------------------------------- the vendors */

/**
 * Fetching what was shared, and reading it.
 *
 * Two shapes arrive here and they are not the same job.
 *
 *   video     a reel, a TikTok, a Short. One file. Gemini ingests it whole,
 *             reading the text burned into the frames and transcribing what is
 *             said out loud, because half of these name the place only in
 *             speech.
 *
 *   carousel  an Instagram post of several photographs, each one a place with
 *             its name and often its address written across it. Not a video at
 *             all: the scraper returns a list of image urls, every one of them
 *             has to be fetched, and all of them go to the model together in
 *             one request so that a city named on the first slide is still
 *             known by the ninth.
 *
 * The output contract is identical either way — candidate names and a region
 * hint — because everything downstream resolves names on the device and does
 * not care where they were read. Quota counts one post, not one slide: a
 * carousel of ten costs about what a reel costs, and charging ten would make
 * the fair-use number mean different things for different people.
 *
 * The caption is read first, and the media only if it yields nothing. That
 * order was decided by a real post rather than by design: the first carousel
 * tested listed all ten of its places in the caption as a numbered list, which
 * cost a few hundred text tokens against 2,772 for the eleven images. Both
 * were measured. List-style posts are the genre this feature exists for, so for
 * a good share of them the expensive half never runs.
 */
async function placesFromPost(env, target) {
  const post = await fetchPost(env, target);
  if (!post) throw new Refusal(FAILURES.postUnavailable, 404);

  // The caption, if there is one worth asking about. Two words is not a list.
  if (post.caption && post.caption.length > 20) {
    const text = [CAPTION_PROMPT, '', post.caption, ...post.alts].join(NEWLINE);
    const found = await readPlaces(env, [{ text }]);
    if (found.length) {
      return { candidates: found, regionHint: regionOf(found), read: 'caption' };
    }
  }

  // Otherwise the media, which is what most reels need.
  const parts = [{ text: MEDIA_PROMPT }];
  if (post.video) {
    const res = await fetch(post.video, { headers: { 'User-Agent': UA } });
    if (!res.ok) throw new Refusal(FAILURES.fetchFailed, 502);
    const bytes = new Uint8Array(await res.arrayBuffer());
    if (bytes.length > MEDIA_BUDGET) throw new Refusal(FAILURES.fetchFailed, 413);
    parts.push({
      inlineData: {
        mimeType: res.headers.get('content-type')?.split(';')[0] || 'video/mp4',
        data: bytesToB64(bytes),
      },
    });
  } else {
    parts.push(...await fetchImages(post.images));
  }

  if (parts.length < 2) throw new Refusal(FAILURES.fetchFailed, 502);

  const found = await readPlaces(env, parts);
  if (!found.length) throw new Refusal(FAILURES.postUnavailable, 404);
  return { candidates: found, regionHint: regionOf(found), read: 'media' };
}

const NEWLINE = String.fromCharCode(10);

/** Base64 in chunks, because a spread over megabytes hits the argument limit. */
function bytesToB64(bytes) {
  let out = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    out += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(out);
}

/* ------------------------------------------------------------------ routes */

async function handleProcess(request, env) {
  let payload;
  try {
    payload = await request.json();
  } catch {
    throw new Refusal(FAILURES.unsupportedHost, 400);
  }

  // Host first, before the entitlement check and long before a vendor call. A
  // profile link shared by mistake should cost a regex rather than a round
  // trip, and refusing it before saying anything about entitlement stops this
  // endpoint from doubling as a way to test whether a token is valid.
  const target = reelTarget(payload?.url);
  if (!target) throw new Refusal(FAILURES.unsupportedHost, 400);

  const who = await identify(env, payload?.auth);
  if (!who) throw new Refusal(FAILURES.notEntitled, 402);

  const db = env.DB;
  const now = Date.now();
  const seconds = Math.floor(now / 1000);

  // The kill switch. One var, no deploy of code required, and it stops the
  // spending immediately -- which is what you want at 3am when a vendor's
  // pricing or a loop has gone wrong and the app is in the store.
  if (String(env.REELS_DISABLED || '') === '1') {
    throw new Refusal(FAILURES.disabled, 503);
  }

  const quota = await quotaState(env, db, who.key, now);
  if (quota.exhausted) throw new Refusal(FAILURES.quotaExceeded, 429, { quota });

  // Checked after the per-identity quota so an exhausted customer still gets
  // the accurate answer about their own allowance, and before the vendor call
  // so nothing is spent past the ceiling.
  const global = await globalUsage(env, db, now);
  if (global.exhausted) {
    console.log(`capacity: ${global.used}/${global.limit} in 24h, refusing`);
    throw new Refusal(FAILURES.capacityReached, 503);
  }

  // One reel at a time per identity. The row is the lock, and a stale claim is
  // released after five minutes: a Worker that dies mid-reel would otherwise
  // lock that purchase out for good, with nothing to unlock it.
  const claimed = await db.prepare(
    'INSERT INTO inflight (auth_key, claimed_at) VALUES (?1, ?2) '
    + 'ON CONFLICT (auth_key) DO UPDATE SET claimed_at = ?2 '
    + 'WHERE inflight.claimed_at < ?3',
  ).bind(who.key, seconds, seconds - 300).run();
  if (!claimed.meta?.changes) throw new Refusal(FAILURES.busy, 409);

  try {
    const result = await placesFromPost(env, target);

    // Usage is recorded on success only. A vendor outage is not something to
    // charge against somebody's quota, and "it failed and used one anyway" is
    // the kind of thing that becomes a refund request.
    await db.prepare('INSERT INTO usage (auth_key, ts) VALUES (?1, ?2)')
      .bind(who.key, seconds).run();
    await db.prepare(
      'INSERT INTO verifications (auth_key, store, product_id, verified_at) '
      + 'VALUES (?1, ?2, ?3, ?4) '
      + 'ON CONFLICT (auth_key) DO UPDATE SET verified_at = ?4',
    ).bind(who.key, who.store, who.productId, seconds).run();

    return json({ ...result, quota: await quotaState(env, db, who.key, now) });
  } finally {
    await db.prepare('DELETE FROM inflight WHERE auth_key = ?1')
      .bind(who.key).run();
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS });
    }
    if (url.pathname === '/health') return json({ ok: true });

    if (url.pathname === '/process' && request.method === 'POST') {
      try {
        return await handleProcess(request, env);
      } catch (err) {
        if (err instanceof Refusal) {
          return json({ error: err.code, ...err.extra }, err.status);
        }
        // Nothing from an exception reaches the client. An upstream message is
        // where a vendor's name, a key fragment or an internal URL escapes, and
        // the app has no use for any of it: every case it can act on already
        // has a code above.
        console.error('process failed');
        return json({ error: FAILURES.modelFailed }, 500);
      }
    }

    return json({ error: 'not_found' }, 404);
  },
};
