"""Give every in-app purchase the territories it is sold in.

    python store/iap_availability.py            # show what is missing
    python store/iap_availability.py --write    # set it

The field that keeps a new purchase at MISSING_METADATA while everything
visible about it is complete.

App Store Connect will not tell you this. A purchase with fifty localisations,
a price schedule, a review note and a review screenshot still reads
MISSING_METADATA, with no indication of what is absent, because it has no
`inAppPurchaseAvailability` at all — a resource that does not appear in the
purchase's own relationships and answers 404 rather than empty. Two hours went
into looking for a missing screenshot that was already there.

The territories are copied from a purchase that is already APPROVED rather than
listed here, so the three products stay in step: a customer who can buy the base
unlock can buy the bundle, and one who cannot buy the bundle cannot be offered
it by a paywall that assumes otherwise.
"""
import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from submit import call, errs  # noqa: E402

APP = "6802053382"

# The purchase whose territory list the others copy. Approved and on sale, so
# its list is the one Apple has already accepted for this app.
REFERENCE = "com.spencerfields.littlebird.unlimited"


def territories(iap_id):
    """Every territory one purchase is available in, following the pages."""
    st, r = call("GET", f"inAppPurchases/{iap_id}/inAppPurchaseAvailability",
                 version="v2")
    if st != 200 or not r.get("data"):
        return None
    availability = r["data"]["id"]
    found, cursor = [], None
    while True:
        path = (f"inAppPurchaseAvailabilities/{availability}"
                f"/availableTerritories?limit=200")
        if cursor:
            path += f"&cursor={cursor}"
        st, t = call("GET", path, version="v1")
        if st != 200:
            sys.exit(f"availableTerritories -> {st}: {errs(t)}")
        found += [x["id"] for x in t.get("data", [])]
        nxt = (t.get("links") or {}).get("next") or ""
        cursor = nxt.split("cursor=")[1].split("&")[0] if "cursor=" in nxt else None
        if not cursor:
            return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

    st, d = call("GET", f"apps/{APP}/inAppPurchasesV2?limit=50", version="v1")
    if st != 200:
        sys.exit(f"inAppPurchasesV2 -> {st}: {errs(d)}")
    rows = {i["attributes"]["productId"]: i for i in d.get("data", [])}

    reference = rows.get(REFERENCE)
    if not reference:
        sys.exit(f"no purchase with productId {REFERENCE}")
    wanted = territories(reference["id"])
    if not wanted:
        sys.exit(f"{REFERENCE} has no availability of its own to copy")
    print(f"{REFERENCE}: {len(wanted)} territories")

    failures = 0
    for product, row in sorted(rows.items()):
        if product == REFERENCE:
            continue
        have = territories(row["id"])
        state = row["attributes"]["state"]
        if have is not None:
            print(f"{product}: {len(have)} territories, {state}")
            continue
        print(f"{product}: NO availability at all, {state}")
        if not args.write:
            continue
        st, r = call("POST", "inAppPurchaseAvailabilities", {
            "data": {"type": "inAppPurchaseAvailabilities",
                     "attributes": {"availableInNewTerritories": True},
                     "relationships": {
                         "inAppPurchase": {"data": {
                             "type": "inAppPurchases", "id": row["id"]}},
                         "availableTerritories": {"data": [
                             {"type": "territories", "id": t} for t in wanted]},
                     }}}, version="v1")
        if st != 201:
            failures += 1
            print(f"  ! {st}: {errs(r)}")
        else:
            print(f"  set to {len(wanted)} territories")

    if args.write:
        st, d = call("GET", f"apps/{APP}/inAppPurchasesV2?limit=50", version="v1")
        for i in d.get("data", []):
            a = i["attributes"]
            print(f"{a['productId']}: {a['state']}")
    else:
        print("\nnothing sent — run with --write")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
