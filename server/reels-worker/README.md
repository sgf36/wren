# wren-reels

Turns a shared reel link into candidate place names.

The app resolves those names itself, the way it already resolves names read off
a screenshot, and shows the same confirmation screen. Nothing here returns
media, coordinates or place ids, and nothing here stores what it was sent.

## State

The entitlement, quota and link layers are written and tested. **The vendor and
model layer is not**: `placesFromReel` throws `fetch_failed`, which is the code
the app already renders as "that did not work, try screenshots". That is
deliberate — a stub returning plausible place names would make the client look
finished and leave the first real reel as the first test of the pipeline.

Filling it in needs three accounts that do not exist yet, and their keys.

## Endpoints

    GET  /health    -> {"ok": true}
    POST /process   -> {url, auth}

`auth` is one of:

    {kind: "appstore", jws}                     StoreKit 2 signed transaction
    {kind: "play", purchaseToken, productId}    Play purchase token
    {kind: "comp", token}                       Ed25519 token from wren-codes

On success: `{candidates, regionHint?, caption?, quota}`.
On refusal, one of `unsupported_host`, `not_entitled`, `quota_exceeded`,
`busy`, `post_unavailable`, `fetch_failed`, `model_failed`. The app localises
on those strings, so they are an interface. Nothing else about a failure
reaches the client.

## Setting it up

    npx wrangler d1 create wren-reels        # paste the id into wrangler.toml
    npm run schema                           # see the note below
    npx wrangler secret put SCRAPECREATORS_API_KEY
    npx wrangler secret put APIFY_TOKEN
    npx wrangler secret put GEMINI_API_KEY
    npx wrangler secret put PLAY_SA_KEY
    npm run deploy

`wrangler secret put` takes the secret's **name**. The value goes at the
interactive prompt and nowhere else — passing it as the argument creates a
secret named after the credential, leaves the real one unset, and writes the
credential into the Wrangler logs, which record full command lines. Check
`wrangler secret list` afterwards: a name that looks like a credential is one.

`d1 execute --remote --file` cannot authenticate with the OAuth token on this
account and fails with code 10000. Export a real `CLOUDFLARE_API_TOKEN` first,
or run each statement in `schema.sql` with `--command`.

There is no global wrangler here. Use `npx wrangler`.

## Tests

    npm test

Node's own runner, no Workers runtime needed: everything tested is either pure
or takes its database as an argument. The Apple path is deliberately untested —
it delegates to Apple's library over a real certificate chain, and a test that
stubbed the library would only assert that the stub works. It needs fixture
transactions from a sandbox purchase on a device.
