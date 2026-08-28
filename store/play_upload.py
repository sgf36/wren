# -*- coding: utf-8 -*-
"""Send an App Bundle to a Google Play track, or to Internal app sharing.

    python store/play_upload.py --check
    python store/play_upload.py --aab <path>                  # internal track
    python store/play_upload.py --aab <path> --share          # install link

Four REST calls around an "edit": create, upload the bundle, assign it to a
track, commit. Talking to the API directly rather than through fastlane keeps
the one credential that can publish this app away from a third-party toolchain.

**A first release does not reach a phone on the day it is built, and there is
no way round it.** A track release on an app that has never been published goes
to "Pending publication" until Google reviews it, and the tester opt-in link
does not exist until that finishes.

`--share` is *not* the escape hatch it is in Easy-Post's copy of this tool.
Measured on 2026-08-21 against this package, Internal app sharing refuses with

    400 FAILED_PRECONDITION
    UploadException: NOT_PUBLISHED [[]] (com.spencerfields.littlebird)

so it wants a published release too. It is kept here because it works once the
app has one, and because the next person will otherwise read Easy-Post's note
and expect it to work today.

What unblocks the first publication is the App content declarations — data
safety, content rating, target audience, ads, the privacy policy URL — which
have no API and must be completed in the Console. Until they are, nothing
reaches a phone through Play by any route.

Production is not offered. Releasing to the public should be a deliberate act
in the Console, not a flag on the script that also does routine test uploads.

Credentials are Easy-Post's Play service account, which reaches this app too.
See that repo's PLAY-SETUP.md.
"""
import argparse
import os
import sys

import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from play_listing import (BASE, PACKAGE, UPLOAD, access_token,  # noqa: E402
                          credentials)

TRACKS = ("internal", "alpha", "beta")
DEFAULT_AAB = os.path.join("build", "app", "outputs", "bundle", "release",
                           "app-release.aab")


def fail(edit, headers, what, r):
    if edit:
        requests.delete("%s/applications/%s/edits/%s" % (BASE, PACKAGE, edit),
                        headers=headers, timeout=60)
    sys.exit("%s failed: %s\n%s" % (what, r.status_code, r.text[:1000]))


def rollout(headers, track, notes):
    """Flip the draft release already on `track` to completed.

    Separate from the upload path on purpose. Rolling out is the moment the
    build stops being private, and it should be possible to do it -- or to
    re-read what is about to happen -- without also having a bundle in hand.

    Done here rather than in the Console because that flow is five clicks
    across three screens, and the release status is one field.
    """
    r = requests.post("%s/applications/%s/edits" % (BASE, PACKAGE),
                      headers=headers, timeout=60)
    if r.status_code >= 400:
        fail(None, headers, "edits.insert", r)
    edit = r.json()["id"]

    r = requests.get("%s/applications/%s/edits/%s/tracks/%s"
                     % (BASE, PACKAGE, edit, track), headers=headers, timeout=60)
    if r.status_code >= 400:
        fail(edit, headers, "tracks.get", r)
    releases = r.json().get("releases") or []
    if not releases:
        fail(edit, headers, "nothing on track %s to roll out" % track, r)

    rel = releases[0]
    print("track %s: %s (versionCodes %s) is %s"
          % (track, rel.get("name"), rel.get("versionCodes"), rel.get("status")))
    if rel.get("status") == "completed":
        requests.delete("%s/applications/%s/edits/%s" % (BASE, PACKAGE, edit),
                        headers=headers, timeout=60)
        print("already rolled out; nothing to do")
        return

    rel["status"] = "completed"
    if notes:
        rel["releaseNotes"] = [{"language": "en-GB", "text": notes}]

    r = requests.put("%s/applications/%s/edits/%s/tracks/%s"
                     % (BASE, PACKAGE, edit, track),
                     headers={**headers, "Content-Type": "application/json"},
                     json={"track": track, "releases": [rel]}, timeout=120)
    if r.status_code >= 400:
        fail(edit, headers, "tracks.update", r)

    r = requests.post("%s/applications/%s/edits/%s:commit" % (BASE, PACKAGE, edit),
                      headers=headers, timeout=120)
    if r.status_code >= 400:
        fail(edit, headers, "commit", r)

    # Read it back through a fresh edit. The commit reports that the edit
    # applied, not what the track now says.
    r = requests.post("%s/applications/%s/edits" % (BASE, PACKAGE),
                      headers=headers, timeout=60)
    edit2 = r.json()["id"]
    back = requests.get("%s/applications/%s/edits/%s/tracks/%s"
                        % (BASE, PACKAGE, edit2, track), headers=headers, timeout=60).json()
    requests.delete("%s/applications/%s/edits/%s" % (BASE, PACKAGE, edit2),
                    headers=headers, timeout=60)
    got = (back.get("releases") or [{}])[0]
    print("now: %s (versionCodes %s) status=%s"
          % (got.get("name"), got.get("versionCodes"), got.get("status")))
    if got.get("status") != "completed":
        sys.exit("committed, but the release is still %s" % got.get("status"))
    print("rolled out")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--aab", default=DEFAULT_AAB)
    ap.add_argument("--track", default="internal", choices=TRACKS)
    ap.add_argument("--notes", default=None)
    ap.add_argument("--check", action="store_true",
                    help="prove the credential works and can see this app")
    ap.add_argument("--share", action="store_true",
                    help="Internal app sharing: an install link, no track, no review")
    ap.add_argument("--draft", action="store_true",
                    help="Upload and attach, but do NOT roll out or send for review")
    ap.add_argument("--rollout", action="store_true",
                    help="Roll out the release ALREADY on --track: flips draft to "
                         "completed and sends it for review. Uploads nothing.")
    args = ap.parse_args()

    h = {"Authorization": "Bearer " + access_token(credentials())}

    if args.rollout:
        rollout(h, args.track, args.notes)
        return

    if args.check:
        r = requests.post("%s/applications/%s/edits" % (BASE, PACKAGE),
                          headers=h, timeout=60)
        if r.status_code >= 400:
            fail(None, h, "edits.insert", r)
        edit = r.json()["id"]
        requests.delete("%s/applications/%s/edits/%s" % (BASE, PACKAGE, edit),
                        headers=h, timeout=60)
        print("credential reaches %s" % PACKAGE)
        return

    if not os.path.exists(args.aab):
        sys.exit("no bundle at %s" % args.aab)
    size = os.path.getsize(args.aab)
    print("%s (%d MB)" % (os.path.basename(args.aab), size // (1024 * 1024)))

    if args.share:
        # Note the path: applications/internalappsharing/{package}, not
        # applications/{package}/internalappsharing, which is the ordering
        # everything else in this API uses.
        with open(args.aab, "rb") as fh:
            r = requests.post(
                "%s/applications/internalappsharing/%s/artifacts/bundle"
                % (UPLOAD, PACKAGE),
                headers={**h, "Content-Type": "application/octet-stream"},
                params={"uploadType": "media"}, data=fh, timeout=1800)
        if r.status_code >= 400:
            fail(None, h, "internal app sharing", r)
        d = r.json()
        print("\ninstall link: %s" % d.get("downloadUrl"))
        print("sha256      : %s" % d.get("sha256", "(not returned)"))
        return

    r = requests.post("%s/applications/%s/edits" % (BASE, PACKAGE), headers=h, timeout=60)
    if r.status_code >= 400:
        fail(None, h, "edits.insert", r)
    edit = r.json()["id"]
    print("edit %s" % edit)

    with open(args.aab, "rb") as fh:
        # The media type has to be stated. Left to itself requests guesses
        # application/x-zip from the extension, and the API refuses that.
        r = requests.post("%s/applications/%s/edits/%s/bundles" % (UPLOAD, PACKAGE, edit),
                          headers={**h, "Content-Type": "application/octet-stream"},
                          params={"uploadType": "media"}, data=fh, timeout=1800)
    if r.status_code >= 400:
        fail(edit, h, "bundle upload", r)
    version_code = r.json()["versionCode"]
    print("  uploaded, versionCode %s" % version_code)

    # "completed" is a rollout AND a submission for review; "draft" uploads the
    # bundle, attaches it to the track, and stops. The difference matters for
    # more than caution: Play reads the BILLING permission out of an *uploaded*
    # bundle before it will let you create a one-time product, so a draft is
    # enough to unblock the product and does not commit to shipping anything.
    release = {"status": "draft" if args.draft else "completed",
               "versionCodes": [str(version_code)]}
    if args.notes:
        release["releaseNotes"] = [{"language": "en-GB", "text": args.notes}]
    r = requests.put("%s/applications/%s/edits/%s/tracks/%s" % (BASE, PACKAGE, edit, args.track),
                     headers={**h, "Content-Type": "application/json"},
                     json={"track": args.track, "releases": [release]}, timeout=120)
    if r.status_code >= 400:
        fail(edit, h, "track assignment", r)
    print("  assigned to %s%s" % (args.track, " (draft, not rolled out)" if args.draft else ""))

    r = requests.post("%s/applications/%s/edits/%s:commit" % (BASE, PACKAGE, edit),
                      headers=h, timeout=300)
    if r.status_code >= 400:
        fail(edit, h, "commit", r)
    print("  committed")
    print("\nOn an app that has never been published this will read 'Pending "
          "publication' until Google reviews it, and the tester opt-in link "
          "will not exist until then. Use --share to install today.")


if __name__ == "__main__":
    main()
