"""Attach the build, fill in the review detail, and submit Wren for review.

    python store/submit.py --dry-run     # say what it would do
    python store/submit.py               # do it

Deliberately idempotent and ordered so that a failure leaves the version in a
sane state: everything that can be prepared is prepared before anything is
submitted, and the submission itself is last.
"""
import argparse
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

import jwt

KEY_ID, ISSUER = "4CU796U485", "65aee88f-46c4-4daf-8238-5dc37263d06b"
KEY = (pathlib.Path(r"C:\Users\SpencerFields\OneDrive - Spencer Fields"
                    r"\Apps\Claude MacOS\signing") / "AuthKey_4CU796U485.p8")
APP = "6802053382"
HERE = pathlib.Path(__file__).resolve().parent

# Same contact as the Easy-Post submissions, read from those records rather
# than invented. A wrong phone number on a review detail is how a rejection
# becomes unanswerable.
CONTACT = {
    "contactFirstName": "Spencer",
    "contactLastName": "Fields",
    "contactEmail": "Apps@spencerfields.com",
    "contactPhone": "+44 20 8132 5790",
    "demoAccountRequired": False,
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
                     for x in d.get("errors", []))[:400] or str(d)[:250]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    say = (lambda *a: print("would:", *a)) if args.dry_run else print

    notes = json.loads((HERE / "metadata_en_GB.json")
                       .read_text(encoding="utf-8"))["reviewNotes"]

    st, vers = call("GET", f"apps/{APP}/appStoreVersions?limit=1")
    if "data" not in vers:
        sys.exit(f"appStoreVersions -> {st}: {errs(vers)}")
    ver = vers["data"][0]
    vid = ver["id"]
    print(f"version {ver['attributes']['versionString']} "
          f"({ver['attributes']['appStoreState']})")

    # --- 1. content rights -------------------------------------------
    st, app = call("GET", f"apps/{APP}")
    if app["data"]["attributes"].get("contentRightsDeclaration") is None:
        if args.dry_run:
            say("declare no third-party content")
        else:
            st, d = call("PATCH", f"apps/{APP}", {
                "data": {"type": "apps", "id": APP, "attributes": {
                    "contentRightsDeclaration":
                        "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}})
            print(f"content rights -> {st}"
                  + ("" if st == 200 else f"  {errs(d)}"))
    else:
        print("content rights already declared")

    # --- 2. attach the newest build ----------------------------------
    st, builds = call("GET", f"builds?filter[app]={APP}"
                             "&limit=1&sort=-uploadedDate")
    build = builds["data"][0]
    bver = build["attributes"]["version"]
    st, cur = call("GET", f"appStoreVersions/{vid}/build")
    attached = (cur.get("data") or {}).get("id")
    if attached == build["id"]:
        print(f"build {bver} already attached")
    elif args.dry_run:
        say(f"attach build {bver}")
    else:
        st, d = call("PATCH", f"appStoreVersions/{vid}/relationships/build", {
            "data": {"type": "builds", "id": build["id"]}})
        print(f"attach build {bver} -> {st}"
              + ("" if st in (204, 200) else f"  {errs(d)}"))

    # --- 3. review detail --------------------------------------------
    st, rd = call("GET", f"appStoreVersions/{vid}/appStoreReviewDetail")
    body_attrs = {**CONTACT, "notes": notes}
    if st == 200 and rd.get("data"):
        rid = rd["data"]["id"]
        if args.dry_run:
            say("update the review detail")
        else:
            st, d = call("PATCH", f"appStoreReviewDetails/{rid}", {
                "data": {"type": "appStoreReviewDetails", "id": rid,
                         "attributes": body_attrs}})
            print(f"review detail updated -> {st}"
                  + ("" if st == 200 else f"  {errs(d)}"))
    elif args.dry_run:
        say("create the review detail")
    else:
        st, d = call("POST", "appStoreReviewDetails", {
            "data": {"type": "appStoreReviewDetails",
                     "attributes": body_attrs,
                     "relationships": {"appStoreVersion": {"data": {
                         "type": "appStoreVersions", "id": vid}}}}})
        print(f"review detail created -> {st}"
              + ("" if st == 201 else f"  {errs(d)}"))

    # --- 4. submit ----------------------------------------------------
    # The version and every purchase awaiting review are separate items in one
    # submission. This used to take inAppPurchasesV2[0] and submit whichever
    # purchase the API happened to list first, which was right while there was
    # one. There are three, and two of them are new: submitting one of those and
    # calling it done would ship a version whose paywall offers a product App
    # Review never saw.
    #
    # APPROVED ones are left alone — Apple refuses to re-submit them — and
    # MISSING_METADATA is named loudly rather than skipped quietly, because it
    # means a purchase has no review screenshot and CANNOT go in.
    st, iaps = call("GET", f"apps/{APP}/inAppPurchasesV2?limit=50")
    if "data" not in iaps:
        sys.exit(f"inAppPurchasesV2 -> {st}: {errs(iaps)}")

    SUBMITTABLE = {"READY_TO_SUBMIT", "DEVELOPER_ACTION_NEEDED", "REJECTED",
                   "DEVELOPER_REMOVED_FROM_SALE"}
    wanted, blocked = [], []
    for i in iaps["data"]:
        a = i["attributes"]
        if a["state"] in SUBMITTABLE:
            wanted.append((i["id"], a["productId"]))
        elif a["state"] == "MISSING_METADATA":
            blocked.append(f"{a['productId']} ({a['state']})")
        else:
            print(f"purchase {a['productId']}: {a['state']}, not submitted")

    if blocked:
        sys.exit("these purchases have incomplete metadata and cannot be "
                 "submitted — most likely no App Review screenshot:\n  "
                 + "\n  ".join(blocked))

    if args.dry_run:
        say(f"submit version {vid}"
            + "".join(f" and purchase {name}" for _, name in wanted))
        return

    st, subs = call("GET", f"reviewSubmissions?filter[app]={APP}"
                           "&filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW"
                           ",IN_REVIEW&limit=5")
    open_subs = subs.get("data", [])
    if open_subs:
        sub_id = open_subs[0]["id"]
        print(f"reusing open submission {sub_id}")
    else:
        st, d = call("POST", "reviewSubmissions", {
            "data": {"type": "reviewSubmissions",
                     "attributes": {"platform": "IOS"},
                     "relationships": {"app": {"data": {
                         "type": "apps", "id": APP}}}}})
        if st != 201:
            sys.exit(f"could not create a submission: {st} {errs(d)}")
        sub_id = d["data"]["id"]
        print(f"created submission {sub_id}")

    items = [("appStoreVersion", vid, "the version")]
    items += [("inAppPurchaseV2", ident, name) for ident, name in wanted]
    for kind, ident, label in items:
        body = {"data": {"type": "reviewSubmissionItems",
                         "relationships": {
                             "reviewSubmission": {"data": {
                                 "type": "reviewSubmissions", "id": sub_id}},
                             kind: {"data": {
                                 "type": ("appStoreVersions"
                                          if kind == "appStoreVersion"
                                          else "inAppPurchases"),
                                 "id": ident}}}}}
        # Apple returns 500 here on a request that WORKED. On 2026-09-10 this
        # same POST answered 500 three times and then 409 "was already added"
        # on the fourth -- so every one of those 500s had in fact added the
        # item and only the response was wrong. Treating the 500 as a failure
        # abandons a release that has already half happened, which is exactly
        # what it did that day.
        #
        # So a 500 is retried and a 409 "already added" is success. What the
        # loop is really waiting for is the item being observably present;
        # the status code describes what Apple felt like returning, not what
        # Apple did.
        for attempt in range(1, 6):
            st, d = call("POST", "reviewSubmissionItems", body)
            if st in (200, 201):
                print(f"add {label} -> {st}")
                break
            if st == 409 and "already added" in (errs(d) or ""):
                print(f"add {label} -> already there")
                break
            print(f"add {label} -> {st} (attempt {attempt})  {errs(d)}")
            if st < 500:
                break
            time.sleep(5)

    # Read the items back before submitting. Submitting an empty submission
    # is accepted and then fails with "does not have any items", which names
    # a problem two steps away from the one that caused it.
    st, got = call("GET", f"reviewSubmissions/{sub_id}/items?limit=20")
    on_it = len(got.get("data", []))
    print(f"\n{on_it} item(s) on the submission, {len(items)} expected")
    if on_it < len(items):
        sys.exit("refusing to submit: Apple holds fewer items than were added")

    st, d = call("PATCH", f"reviewSubmissions/{sub_id}", {
        "data": {"type": "reviewSubmissions", "id": sub_id,
                 "attributes": {"submitted": True}}})
    print(f"SUBMIT -> {st}" + ("" if st == 200 else f"  {errs(d)}"))
    if st == 200:
        print(f"state: {d['data']['attributes'].get('state')}")


if __name__ == "__main__":
    main()
