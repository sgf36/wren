"""Put an App Preview video on the Wren listing.

Wren has six screenshots and no preview video. The preview is the one asset
Apple gives priority to in a search result, and it is the lever we control:
the other one is the ratings count, which is zero and cannot be manufactured.

    python store/upload_app_preview.py cut.mov --check
    python store/upload_app_preview.py cut.mov --locale en-GB

`--check` validates the file and touches nothing. Run it before every upload:
Apple accepts the reservation regardless and only reports a bad asset later,
through assetDeliveryState, after the bytes are already on the listing.

## What the footage has to be, and why the advert cut will not do

**An App Preview shows the app.** Apple's review guidelines are explicit that a
preview is captured from the app in use; a cut that spends its payoff inside
Apple Maps is an advert, not a preview. So the preview is cut from the app
beats only, and the Maps shot -- the one capture that has to come off a real
device, because a simulator ignores a `maps://guide` payload -- belongs to the
advert and not to this.

That means the preview does **not** wait on the device capture. It waits on
frame rate, which is a different problem: see below.

**15 to 30 seconds.** Apple rejects anything outside that.

**Portrait 886x1920 for the 6.7in slot.** The CI footage is 1290x2796, the
screenshot size, whose aspect (0.4614) matches 886x1920 (0.4615) almost exactly
-- so it downscales cleanly with no crop and no pillarbox.

**Thirty frames a second, really thirty.** The advert-footage workflow says in
its own header that a green job proves the clips are the right length and not
frozen, and says nothing about whether they are smooth, because a CI runner has
no GPU and the simulator renders in software. Measured on the 2026-08-30
artifact:

    advert-correct-a-place   49.2 fps   fine
    advert-the-list          18.9 fps   choppy
    advert-which-city         6.4 fps   unusable

Two of the three beats are below anything a person would accept. `--check`
measures the real rate -- frames divided by duration, not the container's
claimed r_frame_rate, which reads 600/1 on all three and is meaningless.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.request

import jwt

ISSUER = "65aee88f-46c4-4daf-8238-5dc37263d06b"
KID = "4CU796U485"
KEY = pathlib.Path.home() / "OneDrive - Spencer Fields" / "Apps" / "Claude MacOS" \
    / "signing" / f"AuthKey_{KID}.p8"
B1 = "https://api.appstoreconnect.apple.com/v1"
APP = "6802053382"

PREVIEW_TYPE = "IPHONE_67"
WANT_W, WANT_H = 886, 1920
MIN_SECONDS, MAX_SECONDS = 15, 30
MIN_FPS = 29.0


def token() -> str:
    now = int(time.time())
    # Backdated: Apple rejects a token whose iat is even slightly ahead of its
    # clock, and the first call of a run 401s without it.
    return jwt.encode({"iss": ISSUER, "iat": now - 60, "exp": now + 1140,
                       "aud": "appstoreconnect-v1"},
                      KEY.read_text(), algorithm="ES256",
                      headers={"kid": KID, "typ": "JWT"})


def call(url, method="GET", body=None, raw=None, headers=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body else None)
    head = {"Authorization": "Bearer " + token()}
    if body is not None and raw is None:
        head["Content-Type"] = "application/json"
    head.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=head, method=method)
    try:
        with urllib.request.urlopen(req, timeout=300) as fh:
            payload = fh.read()
            return fh.status, (json.loads(payload) if payload else {})
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf8", "replace")
        try:
            return exc.code, json.loads(text)
        except Exception:
            return exc.code, {"_raw": text}


def explain(payload) -> list[str]:
    out = []
    for err in (payload or {}).get("errors", []):
        out.append(f"{err.get('code')}: {err.get('title')} — {err.get('detail')}")
        for group in (err.get("meta") or {}).get("associatedErrors", {}).values():
            for sub in group:
                out.append(f"    · {sub.get('code')}: {sub.get('detail')}")
    return out or [json.dumps(payload)[:600]]


def probe(path: pathlib.Path) -> dict:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
         "-show_entries", "stream=width,height,nb_read_frames,codec_name",
         "-show_entries", "format=duration,size", "-print_format", "json", str(path)],
        capture_output=True, text=True, check=True).stdout
    data = json.loads(out)
    stream = data["streams"][0]
    duration = float(data["format"]["duration"])
    frames = int(stream["nb_read_frames"])
    return {"w": stream["width"], "h": stream["height"], "codec": stream["codec_name"],
            "seconds": duration, "frames": frames,
            # Frames over duration, never the container's r_frame_rate: that
            # reads 600/1 on every clip the workflow produces.
            "fps": frames / duration if duration else 0.0,
            "bytes": int(data["format"]["size"])}


def check(path: pathlib.Path) -> list[str]:
    m = probe(path)
    print(f"  {path.name}")
    print(f"    {m['w']}x{m['h']}  {m['codec']}  {m['seconds']:.1f}s  "
          f"{m['fps']:.1f} fps  {m['bytes']/1e6:.1f} MB")
    problems = []
    if (m["w"], m["h"]) != (WANT_W, WANT_H):
        problems.append(f"needs {WANT_W}x{WANT_H} for {PREVIEW_TYPE}, is {m['w']}x{m['h']}")
    if not MIN_SECONDS <= m["seconds"] <= MAX_SECONDS:
        problems.append(f"needs {MIN_SECONDS}-{MAX_SECONDS}s, is {m['seconds']:.1f}s")
    if m["fps"] < MIN_FPS:
        problems.append(f"needs {MIN_FPS:.0f} fps, is {m['fps']:.1f} — "
                        "software-rendered simulator footage, recapture it")
    return problems


def localization(locale: str) -> str:
    s, versions = call(f"{B1}/apps/{APP}/appStoreVersions?limit=5"
                       "&fields[appStoreVersions]=versionString,appStoreState")
    editable = [v for v in versions.get("data", [])
                if v["attributes"]["appStoreState"] not in ("READY_FOR_SALE",)]
    if not editable:
        sys.exit("no editable version: every version is READY_FOR_SALE")
    version = editable[0]
    print(f"  version {version['attributes']['versionString']} "
          f"({version['attributes']['appStoreState']})")
    s, locs = call(f"{B1}/appStoreVersions/{version['id']}/appStoreVersionLocalizations"
                   "?limit=200&fields[appStoreVersionLocalizations]=locale")
    for entry in locs.get("data", []):
        if entry["attributes"]["locale"] == locale:
            return entry["id"]
    sys.exit(f"{locale} is not a localization on that version")


def preview_set(loc_id: str) -> str:
    s, sets = call(f"{B1}/appStoreVersionLocalizations/{loc_id}/appPreviewSets?limit=20")
    for entry in sets.get("data", []):
        if entry["attributes"]["previewType"] == PREVIEW_TYPE:
            return entry["id"]
    s, made = call(f"{B1}/appPreviewSets", "POST", {"data": {
        "type": "appPreviewSets",
        "attributes": {"previewType": PREVIEW_TYPE},
        "relationships": {"appStoreVersionLocalization": {
            "data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}})
    if s not in (200, 201):
        for line in explain(made):
            print("   ", line)
        sys.exit("could not create the preview set")
    return made["data"]["id"]


def upload(path: pathlib.Path, set_id: str) -> str:
    blob = path.read_bytes()
    s, made = call(f"{B1}/appPreviews", "POST", {"data": {
        "type": "appPreviews",
        "attributes": {"fileName": path.name, "fileSize": len(blob)},
        "relationships": {"appPreviewSet": {
            "data": {"type": "appPreviewSets", "id": set_id}}}}})
    if s not in (200, 201):
        for line in explain(made):
            print("   ", line)
        sys.exit("reservation refused")
    preview = made["data"]
    for op in preview["attributes"]["uploadOperations"]:
        chunk = blob[op["offset"]:op["offset"] + op["length"]]
        head = {h["name"]: h["value"] for h in op["requestHeaders"]}
        req = urllib.request.Request(op["url"], data=chunk, headers=head,
                                     method=op["method"])
        with urllib.request.urlopen(req, timeout=600) as fh:
            if fh.status not in (200, 201, 204):
                sys.exit(f"chunk at {op['offset']} rejected: {fh.status}")
        print(f"    sent {op['offset'] + len(chunk):>12,} / {len(blob):,}")
    s, done = call(f"{B1}/appPreviews/{preview['id']}", "PATCH", {"data": {
        "type": "appPreviews", "id": preview["id"],
        "attributes": {"uploaded": True,
                       "sourceFileChecksum": hashlib.md5(blob).hexdigest()}}})
    if s != 200:
        for line in explain(done):
            print("   ", line)
        sys.exit("commit refused")
    return preview["id"]


def wait(preview_id: str) -> None:
    """Apple validates after the bytes land, so the upload succeeding proves
    nothing about the asset."""
    for attempt in range(30):
        time.sleep(6)
        s, d = call(f"{B1}/appPreviews/{preview_id}"
                    "?fields[appPreviews]=assetDeliveryState,videoUrl")
        state = (d.get("data", {}).get("attributes", {})
                 .get("assetDeliveryState") or {})
        status = state.get("state")
        print(f"    +{(attempt + 1) * 6:3}s  {status}")
        if status == "COMPLETE":
            return
        if status == "FAILED":
            sys.exit(f"Apple rejected the asset: {state.get('errors')}")
    print("    still processing; check App Store Connect")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video")
    ap.add_argument("--locale", default="en-GB")
    ap.add_argument("--check", action="store_true",
                    help="validate the file and stop")
    args = ap.parse_args()

    path = pathlib.Path(args.video)
    if not path.is_file():
        sys.exit(f"no such file: {path}")

    problems = check(path)
    if problems:
        for line in problems:
            print(f"    REJECT: {line}")
        sys.exit(1)
    print("    passes every check Apple applies before it sees the file")
    if args.check:
        return

    loc = localization(args.locale)
    preview_id = upload(path, preview_set(loc))
    wait(preview_id)
    print(f"  uploaded: {preview_id}")


if __name__ == "__main__":
    main()
