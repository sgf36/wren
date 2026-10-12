"""The Custom Product Page the adverts link to: the captioned images, per locale.

    python store/custom_page.py --dir <frames dir> --check     # what it would do
    python store/custom_page.py --dir <frames dir>             # create + upload
    python store/custom_page.py --submit                       # send for review
    python store/custom_page.py --status                       # state and URL id

<frames dir> is store/frames.py's output (or the store-frames workflow's
artifact): <locale>/<slide id>.png, 1290x2796, six per locale.

Why a custom page (12 Oct 2026). The default page's images are being replaced
too, but those can only change with an app version, and 2.1.10 was in review.
A custom page is reviewed on its own, and the adverts can point at it today:
/get/ adds `ppid=<id>` to the App Store link once it is approved.

Idempotent: the page is found by NAME, a locale that already has images is
left alone unless --replace, and nothing is submitted without --submit. The
images are checked for size and count before anything is sent; the person
running this must still have LOOKED at them (SCREENSHOTS-RUNBOOK.md).
"""
import argparse
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from push_screenshots import APP, SLOT, call, errs, png_size, upload_one  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent
NAME = "Adverts - captioned"
SPEC = json.loads((HERE / "frames.json").read_text(encoding="utf-8"))
SLIDES = [s["id"] for s in SPEC["slides"]]


def die(msg):
    sys.exit(msg)


def find_page():
    st, d = call("GET", f"apps/{APP}/appCustomProductPages?limit=50")
    if st != 200:
        die(f"listing custom pages: {st} {errs(d)}")
    for p in d["data"]:
        if p["attributes"]["name"] == NAME:
            return p
    return None


def page_version(page_id):
    """The page's editable version (or the latest), with its localisations."""
    st, d = call("GET", f"appCustomProductPages/{page_id}/appCustomProductPageVersions?limit=10")
    if st != 200 or not d["data"]:
        die(f"versions of {page_id}: {st} {errs(d)}")
    v = d["data"][0]
    st, locs = call("GET", f"appCustomProductPageVersions/{v['id']}/appCustomProductPageLocalizations?limit=50")
    return v, {l["attributes"]["locale"]: l for l in locs.get("data", [])}


def create_page(first_locale):
    # The local ids must be Apple's own form, "${new-<type>-id}". Short ones
    # like v_id are accepted by the schema and refused by the server with a
    # misleading 409 ("missing a required relationship
    # appCustomProductPageLocalizations"). Found by probing, 12 Oct 2026.
    v_id = "${new-appCustomProductPageVersion-id}"
    l_id = "${new-appCustomProductPageLocalization-id}"
    body = {
        "data": {
            "type": "appCustomProductPages",
            "attributes": {"name": NAME},
            "relationships": {
                "app": {"data": {"type": "apps", "id": APP}},
                "appCustomProductPageVersions": {"data": [{"type": "appCustomProductPageVersions", "id": v_id}]},
            },
        },
        "included": [
            {"type": "appCustomProductPageVersions", "id": v_id,
             "relationships": {"appCustomProductPageLocalizations": {
                 "data": [{"type": "appCustomProductPageLocalizations", "id": l_id}]}}},
            {"type": "appCustomProductPageLocalizations", "id": l_id,
             "attributes": {"locale": first_locale}},
        ],
    }
    st, d = call("POST", "appCustomProductPages", body)
    if st != 201:
        die(f"creating the page: {st} {errs(d)}")
    print("created page", d["data"]["id"])
    return d["data"]


def add_locale(version_id, locale):
    st, d = call("POST", "appCustomProductPageLocalizations", {"data": {
        "type": "appCustomProductPageLocalizations",
        "attributes": {"locale": locale},
        "relationships": {"appCustomProductPageVersion": {"data": {
            "type": "appCustomProductPageVersions", "id": version_id}}}}})
    if st != 201:
        die(f"adding {locale}: {st} {errs(d)}")
    return d["data"]


def screenshot_set(loc_id):
    st, d = call("GET", f"appCustomProductPageLocalizations/{loc_id}/appScreenshotSets?limit=20")
    for s in d.get("data", []):
        if s["attributes"]["screenshotDisplayType"] == SLOT:
            return s
    st, d = call("POST", "appScreenshotSets", {"data": {
        "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": SLOT},
        "relationships": {"appCustomProductPageLocalization": {"data": {
            "type": "appCustomProductPageLocalizations", "id": loc_id}}}}})
    if st != 201:
        die(f"screenshot set: {st} {errs(d)}")
    return d["data"]


def images(frames, locale):
    files = [frames / locale / f"{s}.png" for s in SLIDES]
    missing = [f.name for f in files if not f.exists()]
    if missing:
        die(f"{locale}: missing {missing}")
    bad = [f.name for f in files if png_size(f) != (1290, 2796)]
    if bad:
        die(f"{locale}: not 1290x2796: {bad}")
    return files


def upload(frames, check, replace):
    locales = sorted(d.name for d in frames.iterdir() if d.is_dir())
    unknown = [l for l in locales if l not in SPEC["captions"]]
    if unknown:
        die(f"directories with no captions in frames.json: {unknown}")
    plan = {l: images(frames, l) for l in locales}
    print(f"{len(plan)} locales x {len(SLIDES)} images, all 1290x2796")
    if check:
        page = find_page()
        print("page:", page["id"] if page else "(would be created)", NAME)
        return
    # A custom page can only use languages the app's own listing has. Others
    # are skipped and named; their viewers get the page's primary language.
    st, v = call("GET", f"apps/{APP}/appStoreVersions?filter[appStoreState]=READY_FOR_SALE&limit=1")
    st, ls = call("GET", f"appStoreVersions/{v['data'][0]['id']}/appStoreVersionLocalizations?limit=200")
    listed = {l["attributes"]["locale"] for l in ls["data"]}
    skipped = [l for l in plan if l not in listed]
    for l in skipped:
        del plan[l]
    if skipped:
        print("not in the app's listing, skipped:", skipped)
    locales = sorted(plan)
    page = find_page() or create_page(locales[0])
    version, locs = page_version(page["id"])
    state = version["attributes"].get("state")
    print("page", page["id"], "version", version["id"], state)
    for locale, files in plan.items():
        loc = locs.get(locale) or add_locale(version["id"], locale)
        sset = screenshot_set(loc["id"])
        st, have = call("GET", f"appScreenshotSets/{sset['id']}/appScreenshots?limit=20")
        have = have.get("data", [])
        # Only a complete set is left alone: an upload interrupted part-way
        # (Apple slow to process one image) leaves fewer, and that set is
        # replaced rather than kept.
        if len(have) == len(files) and not replace:
            print(f"  {locale}: {len(have)} images already there, left alone")
            continue
        for old in have:
            call("DELETE", f"appScreenshots/{old['id']}")
        for f in files:
            ok, msg = upload_one(sset["id"], f)
            # Apple's processing queue can take longer than upload_one waits
            # (UPLOAD_COMPLETE, no errors). That is checked once, below, for
            # the whole page; anything else is a real failure.
            if not ok and not msg.startswith("still not COMPLETE"):
                die(f"  {locale} {f.name}: {msg}")
        print(f"  {locale}: {len(files)} uploaded")
    wait_complete(version["id"])


def wait_complete(version_id, minutes=20):
    """Every image on the page processed by Apple, or a named failure."""
    import time
    for _ in range(minutes * 4):
        pending, failed, total = [], [], 0
        st, locs = call("GET", f"appCustomProductPageVersions/{version_id}/appCustomProductPageLocalizations?limit=50")
        for l in locs["data"]:
            st, sets = call("GET", f"appCustomProductPageLocalizations/{l['id']}/appScreenshotSets")
            for sset in sets.get("data", []):
                st, shots = call("GET", f"appScreenshotSets/{sset['id']}/appScreenshots?limit=20")
                for x in shots.get("data", []):
                    total += 1
                    state = x["attributes"].get("assetDeliveryState") or {}
                    name = f"{l['attributes']['locale']}/{x['attributes']['fileName']}"
                    if state.get("errors"):
                        failed.append(name)
                    elif state.get("state") != "COMPLETE":
                        pending.append(name)
        if failed:
            die(f"Apple rejected: {failed}")
        if not pending:
            print(f"all {total} images processed (COMPLETE)")
            return
        time.sleep(15)
    die(f"still processing after {minutes} min: {pending}")


def status():
    page = find_page()
    if not page:
        print("no page named", NAME)
        return
    version, locs = page_version(page["id"])
    print("page", page["id"], "| visible:", page["attributes"].get("visible"),
          "| url:", page["attributes"].get("url"))
    print("version", version["id"], version["attributes"])
    print("locales:", sorted(locs))


def submit():
    page = find_page() or die("no page to submit")
    version, _ = page_version(page["id"])
    st, d = call("POST", "reviewSubmissions", {"data": {
        "type": "reviewSubmissions", "attributes": {"platform": "IOS"},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
    if st != 201:
        die(f"creating a submission: {st} {errs(d)}")
    sub = d["data"]["id"]
    st, d = call("POST", "reviewSubmissionItems", {"data": {
        "type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub}},
            "appCustomProductPageVersion": {"data": {
                "type": "appCustomProductPageVersions", "id": version["id"]}}}}})
    if st not in (200, 201) and not (st == 409 and "already" in (errs(d) or "")):
        die(f"adding the page to submission {sub}: {st} {errs(d)}")
    st, items = call("GET", f"reviewSubmissions/{sub}/items")
    if not items.get("data"):
        die(f"submission {sub} holds no items; not submitting")
    st, d = call("PATCH", f"reviewSubmissions/{sub}", {"data": {
        "type": "reviewSubmissions", "id": sub, "attributes": {"submitted": True}}})
    print("SUBMIT ->", st, "" if st == 200 else errs(d))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", type=pathlib.Path)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--replace", action="store_true")
    ap.add_argument("--submit", action="store_true")
    ap.add_argument("--status", action="store_true")
    a = ap.parse_args()
    if a.dir:
        upload(a.dir, a.check, a.replace)
    if a.submit:
        submit()
    if a.status or not (a.dir or a.submit):
        status()


if __name__ == "__main__":
    main()
