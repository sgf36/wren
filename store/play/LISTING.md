# Play store listing — draft

Every factual claim below is either verified on a real Android system (see the
handover, §1) or is what the app itself says in the hand-off sheet, so the two
cannot drift apart.

Rewritten for **2.0**, the release that reads places out of a shared reel or
post. Android can receive a share at all only from this version: before it, the
share target existed on iPhone and not here.

Three rules carried over, two from the App Store and one from this repository:

* **No Apple product is named anywhere.** Wren was rejected under App Store
  guideline 5.2.5 for naming Apple in its subtitle. On Play the wording would
  be irrelevant to the product in any case: there is no Apple map here.
* **Other companies' app names are used referentially only** — "hands the list
  to", "works with" — never in the app's own name or icon, and never in a way
  implying endorsement. Instagram, TikTok and YouTube are named the same way,
  and the non-affiliation line at the end now covers them too.
* **The claims about the five map apps match `lib/src/map_targets.dart`.** If
  a note changes there it changes here. Gaia GPS and Mapy.com were never taken
  past their own sign-in screens, so nothing below says their import succeeds.

---

## App name (30 characters)

```
Wren
```

4 characters. Left as the bare name, as on the App Store. A qualifier such as
"Wren: places to your map app" would read as a description rather than a name,
and the short description is directly beneath it.

## Short description (80 characters)

```
Share a reel or a screenshot, and Wren puts the places in your map app
```

70 characters. The reel comes first because it is the reason to look twice at
an app somebody already scrolled past, and the screenshot stays because it is
the route that is free and always works.

## Full description (4000 characters)

```
Wren reads the places out of a reel, a post or a screenshot, and puts them into the map app on your phone.

FROM A REEL OR A POST

Somebody sends you a reel of ten places in Lisbon. Share it to Wren. Wren reads the names out of it and hands you the list, ready to check.

A server Wren runs fetches that post and reads it, then throws it away. Nothing about the post is kept — not the video, not the words, not the names it found. Wren never shows you the post and never signs in to anything.

OR FROM A SCREENSHOT

A message, a page of a guidebook, a post you cannot share. Screenshot it. Wren reads the names, works out which of them are places rather than buttons and captions, and asks which city before it looks anything up.

That reading happens on your phone. Nothing is uploaded, and no picture ever leaves.

OR FROM A FILE YOU ALREADY HAVE

A saved-places export from another map app, or a Google Takeout archive. Wren reads CSV, KML, KMZ, GPX and GeoJSON, and takes its name for the list from the file.

EVERY PLACE IS YOURS TO CHECK

Wren shows what it read beside what it matched, so a wrong match is obvious rather than silent, and you can search again for anything it got wrong. This matters just as much for a reel: what a model read out of somebody else's caption can be wrong in exactly the way a reading of a screenshot can. Nothing is sent anywhere until you have looked at the list and chosen what to keep.

THEN HAND IT TO YOUR MAP APP

Wren writes one file and passes it to whichever app you choose. Only the apps actually installed on your phone are offered.

• Organic Maps — arrives as a named list of saved places
• OsmAnd — arrives in Favorites, after tapping "Import as favorites"
• Locus Map — arrives in My library, once you confirm the import
• Gaia GPS — needs a Gaia account, and the Waypoints layer switched on
• Mapy.com — needs a Seznam account, and a few taps to save
• Anything else on your phone, through the standard share sheet

Google Maps works differently, because Google offers no way for an app to write into a saved list. Wren saves the places as a spreadsheet, then opens Google My Maps so you can import it there yourself.

WHAT IT COSTS

Guides of up to three places are free, for good, and so is reading a screenshot — at any size, however many places are in it.

Two things are paid for, each once:

• Any number of places — removes the three-place limit, and lets you add to a guide you already have
• Places from posts — reads the places out of a reel or post you share, with a fair-use allowance of 250 posts every thirty days

Buying both together costs less than buying them apart, and if you already own the first, the second is offered at the difference rather than the full price. No subscription, nothing that renews, nothing that expires.

WHAT LEAVES YOUR PHONE, AND WHAT DOES NOT

Your screenshots do not. That reading is done on the device.

A place name does, when Wren looks it up, because finding where a place is means asking a map. It goes to the map service your phone already uses.

A link does, if you share a reel or a post — and only then. A share sheet hands over a web address and never the video, so the post has to be fetched by something that can reach it. What is sent is the address and proof that you paid for the feature: no name, no email address, no location, and no identifier for you.

There is no account, no advertising and no analytics. Wren asks nothing at all about your location: it never asks where you are, only where a place named in a post or a screenshot is.

Organic Maps, OsmAnd, Locus Map, Gaia GPS, Mapy.com and Google Maps are the trademarks of their respective owners. Instagram, TikTok and YouTube are the trademarks of theirs. Wren works with the map apps and reads posts you choose to give it; it is not affiliated with, endorsed by or connected to any of them.
```

3,869 characters, against a 4,000 limit.

---

## App content declarations (§10 of the handover)

Answered from what the app does, all of it checkable in the code. **These have
no endpoint in `androidpublisher` v3 and are Console-only for every developer**,
so they are entered by hand and this section is what they are entered from.

### Data safety

Three things are collected or shared, and 2.0 added the third. State all three;
Play asks what an app *can* do, not what it usually does.

**1. A device identifier, if you enter a complimentary code.** No account, no
analytics, no advertising identifier. But complimentary codes work on Android
as of 2026-08-21: `littlebird/identity` is implemented, so entering a code sends
**the code and a random identifier for this installation** to Wren's own
Cloudflare Worker, which is how a code can be used once and not again. A code
that also grants administrative access is re-confirmed about once a day, which
is what makes such a code withdrawable.

Under Play's taxonomy: *Device or other IDs*, **collected**, not shared,
required rather than optional, not used for advertising or tracking.

The identifier is random and derived from nothing: not `ANDROID_ID`, not the
advertising id, nothing about the hardware or the account. It does **not**
survive reinstalling, unlike the iPhone version, which keeps it in the Keychain
— see `IdentityPlugin.kt`.

**2. A place name, when a lookup happens.** Turning "Dishoom Shoreditch" into a
coordinate means asking a map, and the platform geocoder answers over the
network. Under Play's taxonomy this is closest to *App activity — other
user-generated content*, **shared** rather than collected (it reaches the map
service, and Wren keeps none of it), and required rather than optional.

**3. New in 2.0: the address of a post you share, and proof of purchase.**
Sharing a reel or post sends **the link** and **the Google Play purchase token**
for the product that pays for it to Wren's Worker, which verifies the token with
Google, has the post fetched and read, returns the names, and stores nothing
about the post.

Under Play's taxonomy that is two entries:

* the link — *App activity — other user-generated content*, **shared** (it
  reaches ScrapeCreators, which fetches the post, and Google's Vertex AI, which
  reads it), required rather than optional, not used for advertising;
* the purchase token — *Personal info — user IDs*, **collected**, because one
  row keyed to that purchase counts the fair-use allowance. It is the same
  answer the App Store label gives, where it is declared as User ID used for
  App Functionality, not linked to the user and not used for tracking.

The single stored row records that one purchase spent one unit of its monthly
allowance. It records nothing about what was read.

Answer **yes** to "is data encrypted in transit" — every call is HTTPS — and
**no** to any deletion-request mechanism beyond the contact address, since there
is no account to delete and nothing keyed to a person.

*The screenshot never leaves.* The text recognition runs on the device from a
model inside the bundle. Say this plainly on the listing; it is the question
anybody will actually have.

### Permissions

The app declares two: INTERNET and `com.android.vending.BILLING`, and CI proves
both against the built manifest rather than the source. INTERNET is needed three
times over now: the geocoder, the code server, and reading a shared post.
BILLING is needed because Android sells the same unlocks as iOS. There is
deliberately **no location permission**: Wren never asks where the phone is,
only where a place named in a post or a screenshot is.

The Google Maps route is worth a note if the form allows one: the app saves a
file through the system's own save dialog, then asks Android to open
`https://www.google.com/maps/d/` in a browser. That request is the browser's, in
the user's own session, and Wren uploads nothing.

### Content rating

IARC questionnaire. No violence, no user-generated content published anywhere,
no communication features, no gambling. A utility — but it **does** offer
digital purchases, and the questionnaire asks. Say yes: there are now three
one-time products, all ACTIVE since 2026-09-07.

One answer deserves care. Wren displays *text it read out of somebody else's
post* — place names — and the questionnaire asks about user-generated content
and about content Wren does not control. The names are shown only to the person
who shared the post, are never published, transmitted to another user, or stored
by Wren, and are shown for correction before anything is saved. Answer the
"content from an uncontrolled source" question honestly and note that it is
displayed to that one user only.

### Target audience

Not directed at children.

### Ads

None.

### Government, news, financial or health app

None of these.

### Privacy policy URL

<https://wren.spencerfields.com/android-privacy.html>

Written for this app and live in sixteen languages. Updated for 2.0 on
2026-09-07 with the section on a shared post, stated in Android's own terms —
the proof of purchase there is a Play purchase token, not an App Store
transaction.

Do **not** give Play the /privacy.html address: that one is the iPhone policy,
describing a different map app, an App Store privacy label and a Keychain, none
of which exist here.

The two pages agree on the sections that are true of both — who this is, the ICO
registration, the shared post, children, your rights, the website — and diverge
everywhere the platforms do. If either changes, check the other.
