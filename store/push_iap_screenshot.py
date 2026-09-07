"""Upload each in-app purchase's App Review screenshot.

    python store/push_iap_screenshot.py            # show what would be sent
    python store/push_iap_screenshot.py --write    # send it

Separate from the app's screenshots: a different resource, a different upload,
and the thing that keeps a purchase at MISSING_METADATA. Review needs one image
per purchase showing what the customer actually sees before paying — and for
three products that is three different sheets, not one picture used three
times. The paywall shows what is left to buy, so a customer who owns the base
unlock sees a different sheet from one who owns nothing, and an image of the
wrong one is a description of a purchase that does not exist.

The images come out of `store/shoot.py`, which renders the real paywall in a
simulator with the real storefront prices. See IAP_SCENES there.

Same three-step dance as appScreenshots, and the same trap: the PUT must not
carry the API token, and the commit needs an MD5.
"""
import argparse
import hashlib
import os
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

import jwt

# In CI the key arrives as a secret written to a temporary file, so the path
# and the two ids are overridable. Hard-coding them worked on the author's
# machine and failed the first time this ran on a runner, after forty
# minutes of simulator work — the same three environment variables
# push_screenshots.py has always honoured.
KEY_ID = os.environ.get("WREN_ASC_KEY_ID") or "4CU796U485"
ISSUER = (os.environ.get("WREN_ASC_ISSUER")
          or "65aee88f-46c4-4daf-8238-5dc37263d06b")
KEY = pathlib.Path(os.environ.get("WREN_ASC_KEY") or (
    r"C:\Users\SpencerFields\OneDrive - Spencer Fields"
    r"\Apps\Claude MacOS\signing\AuthKey_4CU796U485.p8"))
APP = "6802053382"
HERE = pathlib.Path(__file__).resolve().parent
IAP_DIR = HERE / "screenshots" / "IAP"

# Which image belongs to which purchase.
#
# Keyed on the file's stem so the mapping is visible in the directory listing
# as well as here. The scene names match `iapScenes` in
# lib/src/screenshots.dart and `IAP_SCENES` in shoot.py; the legacy name is the
# image taken by hand before any of that existed, and is kept so the base
# unlock does not lose its screenshot on the first run of this file.
SHOTS = {
    "guides-of-any-size": "com.spencerfields.littlebird.unlimited",
    "07-everything": "com.spencerfields.littlebird.everything",
    "08-reels-upgrade": "com.spencerfields.littlebird.reels.upgrade",
}

_tok = {"v": None, "exp": 0}


def token():
    now = int(time.time())
    if not _tok["v"] or now > _tok["exp"] - 120:
        _tok["v"] = jwt.encode(
            {"iss": ISSUER, "iat": now - 60, "exp": now + 1140,
             "aud": "appstoreconnect-v1"},
            KEY.read_text(), algorithm="ES256",
            headers={"kid": KEY_ID, "typ": "JWT"})
        _tok["exp"] = now + 1140
    return _tok["v"]


def call(method, path, body=None, version="v1", _left=3):
    req = urllib.request.Request(
        f"https://api.appstoreconnect.apple.com/{version}/{path}",
        method=method,
        headers={"Authorization": f"Bearer {token()}",
                 "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body else None)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        if e.code == 401 and _left > 1:
            _tok["v"] = None
            time.sleep(4)
            return call(method, path, body, version, _left - 1)
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"_raw": raw[:400]}


def errs(d):
    return "; ".join(f"{x.get('title')}: {x.get('detail')}"
                     for x in d.get("errors", []))[:300] or str(d)[:200]


def upload(iap_id, path):
    """Replace this purchase's review screenshot with the file at `path`."""
    st, cur = call("GET", f"inAppPurchases/{iap_id}/appStoreReviewScreenshot",
                   version="v2")
    if st == 200 and cur.get("data"):
        # Replaced rather than stacked: a purchase holds one.
        call("DELETE",
             f"inAppPurchaseAppStoreReviewScreenshots/{cur['data']['id']}")
        print("    removed the existing screenshot")

    data = path.read_bytes()
    st, d = call("POST", "inAppPurchaseAppStoreReviewScreenshots", {
        "data": {"type": "inAppPurchaseAppStoreReviewScreenshots",
                 "attributes": {"fileName": path.name, "fileSize": len(data)},
                 "relationships": {"inAppPurchaseV2": {"data": {
                     "type": "inAppPurchases", "id": iap_id}}}}})
    if st != 201:
        return f"reserve failed {st}: {errs(d)}"
    shot_id = d["data"]["id"]

    for op in d["data"]["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], method=op["method"], data=chunk)
        for h in op["requestHeaders"]:
            req.add_header(h["name"], h["value"])
        urllib.request.urlopen(req, timeout=300).read()

    st, d = call("PATCH",
                 f"inAppPurchaseAppStoreReviewScreenshots/{shot_id}", {
                     "data": {"type": "inAppPurchaseAppStoreReviewScreenshots",
                              "id": shot_id,
                              "attributes": {
                                  "uploaded": True,
                                  "sourceFileChecksum":
                                      hashlib.md5(data).hexdigest()}}})
    if st != 200:
        return f"commit failed {st}: {errs(d)}"

    for _ in range(40):
        st, d = call("GET",
                     f"inAppPurchaseAppStoreReviewScreenshots/{shot_id}")
        state = (d.get("data", {}).get("attributes", {})
                 .get("assetDeliveryState") or {})
        if state.get("state") == "COMPLETE":
            return None
        if state.get("errors"):
            return f"rejected: {json.dumps(state['errors'])[:300]}"
        time.sleep(3)
    return "never reached COMPLETE"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="actually upload")
    args = ap.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

    st, iaps = call("GET", f"apps/{APP}/inAppPurchasesV2?limit=50")
    if "data" not in iaps:
        sys.exit(f"inAppPurchases -> {st}: {errs(iaps)}")
    ids = {i["attributes"]["productId"]: i["id"] for i in iaps["data"]}
    states = {i["attributes"]["productId"]: i["attributes"]["state"]
              for i in iaps["data"]}

    failures = 0
    for stem, product in SHOTS.items():
        path = IAP_DIR / f"{stem}.png"
        if product not in ids:
            print(f"{product}: no such purchase — skipped")
            continue
        if not path.exists():
            # Named rather than silent: a purchase with no image stays at
            # MISSING_METADATA and cannot be submitted, and the reason for that
            # is a file that was never taken.
            print(f"{product}: no image at {path} — still "
                  f"{states.get(product)}")
            failures += 1
            continue
        print(f"{product} ({states.get(product)})")
        print(f"    {path.name}, {path.stat().st_size:,} bytes")
        if not args.write:
            continue
        problem = upload(ids[product], path)
        if problem:
            print(f"    ! {problem}")
            failures += 1
        else:
            print("    COMPLETE")

    if args.write:
        st, iaps = call("GET", f"apps/{APP}/inAppPurchasesV2?limit=50")
        for i in iaps.get("data", []):
            a = i["attributes"]
            print(f"{a['productId']}: {a['state']}")
    else:
        print("\nnothing sent — run with --write")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
