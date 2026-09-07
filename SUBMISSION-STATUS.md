# Wren — where the submission stands

Last updated **7 September 2026**. Everything below was read back from App Store
Connect and the Play Console on that date, not assumed. This file has been wrong
before in the most misleading way possible — its first line once said the app was
unsubmitted while 1.0 had been live for days — so every claim here names what was
checked.

## 2.0 is approved on the App Store and must NOT be released yet

| | |
|---|---|
| **2.0.0** | `PENDING_DEVELOPER_RELEASE` — approved, build 177, MANUAL release |
| 1.2.0 | `READY_FOR_SALE` — the version customers have now |
| Purchase `unlimited` | `APPROVED` |
| Purchase `everything` | **`WAITING_FOR_REVIEW`** |
| Purchase `reels.upgrade` | **`WAITING_FOR_REVIEW`** |
| App Privacy label | Published 7 Sept — User ID + Device ID + Other Data, App Functionality, not linked, no tracking |
| Listing, 49 locales | Description, promotional text, release notes, keywords, screenshots — all pushed |

**Releasing 2.0.0 before those two purchases are APPROVED ships a broken
paywall.** A purchase in `WAITING_FOR_REVIEW` is not sold in production, so
`queryProductDetails` returns nothing for it, the sheet falls back to the
hardcoded `$14.99` / `$9.99` strings in `entitlement.dart`, and the buy fails.
Every customer who shares a reel would hit that. This is the entire reason the
release was set to MANUAL.

Check with `python store/readiness.py`, which prints the state of all three.

### What the API cannot see, and how to read that

`appDataUsages` and `agreements` both 404 under this key. That is the API's
shape, not a permissions problem, and a stronger key does not help.
`readiness.py` prints `?` for them, meaning **could not look** — not "missing".
Reading that `?` as a blocker is how an earlier version of this file named a
satisfied requirement as the thing holding up a submission.

`store/push_metadata.py` reports `0 of 49 succeeded` whenever an in-app purchase
is live: Apple refuses to edit an `ACTIVE` InAppPurchaseLocalization, and the
script counts a locale as successful only if the listing *and* the purchase both
wrote. The listings do get written. Read the per-locale `listing set` lines.

### One declaration deliberately left to a person

`contentRightsDeclaration` is still `DOES_NOT_USE_THIRD_PARTY_CONTENT`. That was
plainly true when Wren only read your own screenshots. 2.0 reads place names out
of somebody else's post. It is arguably still true — Wren displays names, never
the video, caption or images, and shows them only to the person who shared the
post — but it is a rights claim, not an engineering fact, and it has not been
changed on anyone's behalf.

## Android: 2.0.0 is on closed testing

| | |
|---|---|
| Track `alpha` (closed testing) | **2.0.0, versionCode 5, `completed`** |
| Track `internal` | 1.1.0, versionCode 2 |
| Bundle signature | `META-INF/UPLOAD.RSA`, SHA-256 `B0:67:…:27:93`, compared against the keystore README |
| Store listing | Rewritten for 2.0 and applied 7 Sept — 70-char short, 3,869-char full |
| Products | All three ACTIVE, 173 territories each, read back from `/oneTimeProducts` |
| Data safety | **Updated 7 Sept** for the reel feature |
| Other nine App content declarations | Unchanged since 28 Aug, reviewed and still correct |

### What the Data safety declaration now says, and why

Three types, and the answers follow Play's own definitions rather than instinct:

* **Device or other IDs** — collected, not shared, App functionality. The random
  installation identifier sent with a complimentary code. Unchanged.
* **Personal info → User IDs** — collected, **not** ephemeral, optional, App
  functionality. The Play purchase token: one row keyed to it counts the
  250-per-30-days allowance, so it is retained and pseudonymous data must be
  disclosed.
* **App activity → Other user-generated content** — collected, **ephemeral**,
  optional, App functionality. The shared post link and the place name. Play
  requires ephemeral data to be declared but does not show it on the public
  listing, which is why the store page shows only the two above.

The public label reads **"No data shared with third parties"**, and that is
correct rather than convenient: ScrapeCreators and Vertex AI are service
providers processing on Wren's instructions, and the geocoder lookup rides the
user-initiated-action exemption. Both are named exemptions from *sharing* in
Play's policy.

The privacy policy URL registered with Play is
**<https://wren.spencerfields.com/android-privacy.html>** — the Android policy,
not `/privacy.html`, which is the iPhone one.

### Still open on Android

* **Closed testing needs 12 testers for 14 days** before production is offered.
  That clock is about the tester cohort, not this build.
* **Screenshots are still the 1.x set** — four images, none showing the reel
  flow. The listing describes a feature the pictures do not.
* Production has never been released, and `play_upload.py` deliberately offers no
  production flag.

## The website is current in all sixteen languages

Deployed and verified byte-for-byte 7 Sept: 188 files, plus `contact.php` which
is executed rather than served. The 2.0 copy — three products instead of one, the
reel route, the fair-use allowance, and the Android policy's new section on what
a shared post sends — is live in English and the fifteen translated directories.

Two branches still show as unmerged and both are **superseded, not pending**:
`vendor/vertex`'s `web/` tree is byte-identical to main, and
`site/microsoft-clarity` would only delete content main already has.

## The guide-link ceiling, measured

The "50 places per link" figure this project carried for a day was wrong, and
worth recording properly because it changed a product decision.

maps.apple.com renders a guide link server-side and reports how many places it
parsed, so the limit was bisected against the live service on 17 August 2026
using real muids from a real 82-place guide:

| payload | URL chars | result |
|---|---|---|
| 159 places, lean | 3,504 | parsed all 159 |
| 160 places, lean | 3,534 | empty |
| 40 places, padded title | 3,420 | parsed all 40 |
| 40 places, padded title | 3,550 | empty |
