/**
 * Asks the deployed Worker whether it still serves what the app expects.
 *
 *     node tools/smoke.mjs [base-url]
 *
 * This exists because of a real outage. `/renew` was written, committed, merged
 * and tested on 21 August and never deployed. The app began renewing
 * administrator tokens daily; the live Worker answered 404; and `renewIfDue`
 * treats anything that is not a 200 or a 403 as a dead network, so it changed
 * nothing and let the token age. Fourteen days later `compGrace` elapsed and
 * the token deleted itself. The person holding it saw "could not connect to
 * server" on a phone with a working connection, and lost their access.
 *
 * Every layer behaved as designed. Nothing anywhere compared the routes the app
 * calls against the routes the deployment answers, and that is the only check
 * that would have caught it — unit tests pass against source, and `wrangler
 * deploy` reporting success only ever proves that something was uploaded.
 *
 * So this asserts status codes rather than bodies, and it asserts them against
 * the deployment rather than the source. A route that has gone missing answers
 * 404 where it should answer 400 or 403, which is the signature of a stale
 * deploy and is what this is looking for.
 */
const BASE = process.argv[2] || 'https://wren-codes.sgf36.workers.dev';

// Cloudflare's edge answers 403 with "error code: 1010" to the default
// user agent of curl and of most HTTP libraries. It looks exactly like a
// revoked credential, so every request here claims to be a browser.
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
  + '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

/**
 * Each case names the status a *working* deployment gives, and why that status
 * rather than any other. Where a route is expected to refuse, the refusal is
 * the evidence: reaching a refusal means the route exists and its handler ran.
 */
const CASES = [
  {
    what: 'GET /health',
    method: 'GET', path: '/health', want: 200,
    why: 'the Worker is up at all',
  },
  {
    what: 'POST /redeem with no usable body',
    method: 'POST', path: '/redeem', body: '{}', want: 400,
    why: 'redeem exists and validated the body rather than 404ing',
  },
  {
    what: 'POST /renew with a junk token',
    method: 'POST', path: '/renew', body: '{"token":"aaaa.bbbb"}', want: 403,
    why: 'THE ONE THAT MATTERS: renew exists and ran signature verification. '
      + 'A 404 here is the outage of 21 August to 6 September 2026',
  },
  {
    what: 'GET /renew',
    method: 'GET', path: '/renew', want: 404,
    why: 'renew is POST only, so the method guard still guards',
  },
  {
    what: 'GET /admin/codes without a credential',
    method: 'GET', path: '/admin/codes', want: 403,
    why: 'the console is behind authorisation and has not come unlatched',
  },
  {
    what: 'GET /nothing-here',
    method: 'GET', path: '/nothing-here', want: 404,
    why: 'a genuinely absent route still answers 404, so the 404s above mean '
      + 'something',
  },
];

/** One attempt, retried: a blip must not read as a missing route. */
async function status({ method, path, body }) {
  let last;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = await fetch(BASE + path, {
        method,
        headers: {
          'User-Agent': UA,
          ...(body ? { 'Content-Type': 'application/json' } : {}),
        },
        body,
      });
      return res.status;
    } catch (err) {
      last = err;
      await new Promise((r) => setTimeout(r, 2000 * (attempt + 1)));
    }
  }
  throw last;
}

let failed = 0;
for (const c of CASES) {
  const got = await status(c);
  const ok = got === c.want;
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'}  ${c.what} -> ${got} (want ${c.want})`);
  if (!ok) console.log(`      expected because: ${c.why}`);
}

console.log(`${CASES.length - failed}/${CASES.length} against ${BASE}`);
if (failed) {
  console.error(
    'The deployment does not serve what the app calls. If a route answered 404 '
    + 'where a refusal was expected, the deployed Worker is behind the source: '
    + 'run `npx wrangler deploy` from server/comp-codes-worker.');
  process.exit(1);
}
