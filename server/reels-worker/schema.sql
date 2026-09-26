-- Quota and verification state for the reel feature.
--
-- What is deliberately absent is most of it. No urls, no captions, no place
-- names, no results. The privacy pages are about to say that a shared reel is
-- fetched, read and discarded, and the only way to keep that true under someone
-- else's audit is for there to be nothing here to hand over. A row records that
-- an identity spent one unit of quota at a time. It does not record on what.

-- One row per successful entitlement check, so a Play purchase token is not
-- re-verified against Google on every reel. Apple transactions verify offline
-- and need no cache at all, but they are written here too: it is the only place
-- that answers "which product does this identity actually own?" without a round
-- trip, and one shape for both stores is one code path for both stores.
CREATE TABLE IF NOT EXISTS verifications (
  auth_key    TEXT    PRIMARY KEY,   -- purchase identity, never a device id
  store       TEXT    NOT NULL CHECK (store IN ('appstore', 'play', 'comp')),
  product_id  TEXT,
  verified_at INTEGER NOT NULL
);

-- One row per reel processed. Quota is COUNT over the trailing thirty days
-- rather than a counter on `verifications`, for the reason the comp-codes
-- schema gives about redemptions: a counter is a second source of truth that
-- drifts the first time an increment succeeds and its sibling write does not.
--
-- Keyed on the purchase identity, not the device. Apple's originalTransactionId
-- and Play's purchase token both survive a reinstall, and an Android device UUID
-- does not — so a device key would hand anybody an unlimited quota for the price
-- of clearing app data.
--
-- The free sample added on 2026-09-26 keys on `free:<appTransactionId>` and does
-- not break that rule, which is why it was allowed to exist. appTransactionId is
-- Apple's id for this *Apple Account's* download of this app: it is issued and
-- signed by Apple, survives deleting the app, restoring a backup and changing
-- phone, and is not a device id. One free read means one.
--
-- An earlier attempt keyed it on a random id the app generated and sent. That is
-- the thing this paragraph already forbade — a key the client chooses is a free
-- feature with extra steps — and it was stopped before it shipped. If a future
-- free tier needs Android, Play Integrity attests the app and device but issues
-- no stable per-account id, so it is NOT the equivalent of this and needs its
-- own answer rather than a device UUID with a nicer name.
CREATE TABLE IF NOT EXISTS usage (
  auth_key TEXT    NOT NULL,
  ts       INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS usage_by_key_ts ON usage (auth_key, ts);

-- Claimed while a reel is in flight, released when it finishes. One at a time
-- per identity: /process spends money on every call, and the cheapest way to
-- stop a loop from spending it in parallel is to make the second call fail fast
-- rather than queue.
CREATE TABLE IF NOT EXISTS inflight (
  auth_key   TEXT    PRIMARY KEY,
  claimed_at INTEGER NOT NULL
);
