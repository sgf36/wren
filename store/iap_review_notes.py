"""The App Review notes on each in-app purchase.

    python store/iap_review_notes.py            # show what would change
    python store/iap_review_notes.py --write    # send it

A separate field from the app version's review notes, shown to the reviewer
beside the purchase itself. Build 83 was rejected under 2.1(b) — "we cannot
locate the In-App Purchases within the app" — so every one of these leads with
the taps that reach the sheet, from a cold app with nothing imported, which is
the state a review device is actually in.

The complimentary code is stated last and deliberately: a reviewer who reads
only the first paragraph should still be able to find the purchase, and one who
reads to the end should not have to pay to see what it does. It is not
single-use and it survives resubmission.
"""
import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from submit import call, errs  # noqa: E402

APP = "6802053382"
CODE = "7QFG-7FVY-QXP6-2AT6"
POST = "https://www.instagram.com/p/DcZzVx4Da6a/"

EVERYTHING = f"""\
This unlocks both of the app's paid features at once, for a customer who owns \
neither: reading the places out of a shared reel or post, and saving a guide \
with more than three places.

TO REACH THE SHEET: open the app and tap the three dots at the top right, then \
"Places from a post". Nothing needs to be imported first.

WHAT IT DOES: with it held, sharing a reel or a post to Wren — or pasting a \
link via Add > From a link — sends the link to Wren's own server, which fetches \
the post, has a model read the place names out of the caption or the images, \
and returns the names as text. The app then looks each name up in Apple Maps \
exactly as it looks up a name read off a screenshot, and shows them for the \
user to check before anything is saved. Wren never receives, stores or \
displays the video or images themselves.

A public post the reviewer can use without an Instagram account:

    {POST}

It is a list of ten castle hotels across seven countries. Reading it takes \
about five seconds and adds ten names to the list.

There is a fair-use allowance of 250 posts per rolling thirty days per \
purchase, stated in the app when a reading finishes and again if it runs out. \
It exists because each reading costs money to serve; nothing recurs and nothing \
expires.

TO TEST WITHOUT PURCHASING: long-press the "Wren" title at the top left of the \
main screen and enter this complimentary code:

    {CODE}

It grants everything this purchase grants, is not single-use, and keeps working \
across resubmissions. The same code is in the app's own review notes.

One payment, non-consumable, no subscription. "Restore a previous purchase" on \
the same sheet restores it on another device."""

UPGRADE = f"""\
This adds reading a shared reel or post to a customer who already owns \
"Guides of Any Size" (com.spencerfields.littlebird.unlimited).

It is shown ONLY to somebody who owns that purchase. A customer who owns \
nothing is offered the bundle instead \
(com.spencerfields.littlebird.everything, which grants both), because a \
non-consumable has no upgrade mechanism and charging the full bundle price to \
somebody holding half of it would be charging twice for the same half.

TO REACH THE SHEET: the app must first own the base unlock. Open the app, tap \
the three dots at the top right, then "Guides of any size", and buy or restore \
it. Then open the same menu again and tap "Places from a post": the sheet now \
offers this product rather than the bundle.

WHAT IT DOES: sharing a reel or a post to Wren — or pasting a link via \
Add > From a link — sends the link to Wren's own server, which fetches the \
post, has a model read the place names out of the caption or the images, and \
returns the names as text. The app looks each name up in Apple Maps exactly as \
it looks up a name read off a screenshot, and shows them for the user to check \
before anything is saved. Wren never receives, stores or displays the video or \
images themselves.

A public post the reviewer can use without an Instagram account:

    {POST}

There is a fair-use allowance of 250 posts per rolling thirty days per \
purchase, stated in the app when a reading finishes and again if it runs out.

TO TEST WITHOUT PURCHASING: long-press the "Wren" title at the top left of the \
main screen and enter this complimentary code:

    {CODE}

It grants what this purchase grants and more, is not single-use, and keeps \
working across resubmissions. Note that a device holding the code sees no \
purchase sheet at all, because there is then nothing left to sell — to see \
this product's sheet, use a device without the code.

One payment, non-consumable, no subscription. "Restore a previous purchase" on \
the same sheet restores it on another device."""

NOTES = {
    "com.spencerfields.littlebird.everything": EVERYTHING,
    "com.spencerfields.littlebird.reels.upgrade": UPGRADE,
}

# Apple's cap on the field.
CAP = 4000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

    over = {p: len(n) for p, n in NOTES.items() if len(n) > CAP}
    if over:
        sys.exit(f"over Apple's {CAP}-character cap: {over}")

    st, d = call("GET", f"apps/{APP}/inAppPurchasesV2?limit=50", version="v1")
    if st != 200:
        sys.exit(f"inAppPurchasesV2 -> {st}: {errs(d)}")
    rows = {i["attributes"]["productId"]: i for i in d.get("data", [])}

    failures = 0
    for product, note in NOTES.items():
        row = rows.get(product)
        if not row:
            sys.exit(f"no in-app purchase with productId {product}")
        current = row["attributes"].get("reviewNote") or ""
        print(f"\n{product} ({row['attributes']['state']}) "
              f"{len(note)}/{CAP} chars, "
              f"{'unchanged' if current == note else 'CHANGED'}")
        print("  " + note.replace("\n", "\n  ")[:600])
        if current == note or not args.write:
            continue
        st, d = call("PATCH", f"inAppPurchases/{row['id']}",
                     {"data": {"type": "inAppPurchases", "id": row["id"],
                               "attributes": {"reviewNote": note}}},
                     version="v2")
        if st != 200:
            failures += 1
            print(f"  ! {st}: {errs(d)}")
        else:
            print("  written")

    if not args.write:
        print("\nnothing sent — run with --write")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
