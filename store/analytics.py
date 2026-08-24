"""App Store analytics — the ongoing report request, and reading what it produces.

    python store/analytics.py            # show the request and any reports ready
    python store/analytics.py --create   # start an ONGOING request (once per app)

Downloads, impressions, product page views and — the reason this exists — the
*source* of each. None of it can be backfilled: Apple accrues data from the day
the request is created and not one day earlier, so a request that does not exist
is a permanent hole rather than a delayed report.

## The key here is NOT the submission key

`readiness.py` and every other script in this directory use the App Manager key
`4CU796U485`, which is right for builds and metadata and is refused here:

    POST analyticsReportRequests -> 403 "The API key in use does not allow this
    request"

That 403 is about the key's role, and is a different failure from the one a bare
`GET analyticsReportRequests` gives, which reads

    403 "The resource does not allow GET_COLLECTION. Allowed operations are:
    CREATE, DELETE, GET_INSTANCE"

and is about the resource's shape. Neither says "wrong key" in plain words, and
reading the second as the first is how this was nearly written off as impossible.
There is no listing endpoint at all, so the request id below is the only handle
on it — losing it means creating a duplicate rather than finding the original.

`ZMTWC3PTN6` carries the role this needs. `MUGQVATMZ4`, the Admin key the signing
README still tells you to revoke, was already revoked and now answers 401 — so
"the README names an Admin key" is not the same as "an Admin key works".
"""
import argparse
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

import jwt

KEY_ID = "ZMTWC3PTN6"
ISSUER = "65aee88f-46c4-4daf-8238-5dc37263d06b"
KEY = pathlib.Path(
    r"C:\Users\SpencerFields\OneDrive - Spencer Fields"
    r"\Apps\Claude MacOS\signing\AuthKey_ZMTWC3PTN6.p8")

APP = "6802053382"

# Created 2026-08-24. There is no way to list requests, so this id is the record.
REQUEST = "71f7b4cf-a0a3-4b50-bc9b-f6734637b651"

BASE = "https://api.appstoreconnect.apple.com/v1"


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER, "iat": now - 60, "exp": now + 1140,
         "aud": "appstoreconnect-v1"},
        KEY.read_text(), algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"})


def call(path, method="GET", body=None):
    data = json.dumps(body).encode() if body else None
    headers = {"Authorization": f"Bearer {token()}"}
    if body:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(f"{BASE}/{path}", data=data, method=method,
                                 headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode("utf-8", "replace"))
        except ValueError:
            return e.code, {}


def create():
    status, payload = call("analyticsReportRequests", "POST", {
        "data": {"type": "analyticsReportRequests",
                 "attributes": {"accessType": "ONGOING"},
                 "relationships": {"app": {"data": {"type": "apps",
                                                    "id": APP}}}}})
    if status != 201:
        print(f"  refused, HTTP {status}")
        print(json.dumps(payload, indent=2)[:800])
        return 1
    new = payload["data"]["id"]
    print(f"  created {new}")
    print("  Record this id in REQUEST above — it cannot be looked up again.")
    return 0


def show():
    status, payload = call(f"analyticsReportRequests/{REQUEST}")
    if status != 200:
        print(f"  request {REQUEST} — HTTP {status}")
        print("  If this is 404 the request was deleted; --create a new one.")
        return 1

    attrs = payload["data"]["attributes"]
    print(f"  request   {REQUEST}")
    print(f"  access    {attrs.get('accessType')}")

    # Apple stops an ONGOING request that nobody reads. It reports this as a
    # flag on the request rather than as an error on the reports, so a run that
    # simply finds no reports looks identical to one that has been switched off.
    stopped = attrs.get("stoppedDueToInactivity")
    print(f"  stopped   {stopped}"
          + ("   <-- READ THE REPORTS OR RECREATE IT" if stopped else ""))

    status, payload = call(
        f"analyticsReportRequests/{REQUEST}/reports?limit=200")
    if status != 200:
        print(f"  reports   could not look, HTTP {status}")
        return 1

    reports = payload.get("data", [])
    if not reports:
        print("  reports   none yet — Apple takes about a day to produce the "
              "first set")
        return 0

    print(f"  reports   {len(reports)}")
    for r in sorted(reports, key=lambda x: x["attributes"].get("name", "")):
        a = r["attributes"]
        print(f"    {a.get('category','?'):<24} {a.get('name','?')}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--create", action="store_true",
                    help="start a new ONGOING request")
    args = ap.parse_args()
    return create() if args.create else show()


if __name__ == "__main__":
    sys.exit(main())
