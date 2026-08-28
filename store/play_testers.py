# -*- coding: utf-8 -*-
"""Point a Play testing track at a Google Group.

    python store/play_testers.py --show
    python store/play_testers.py --track alpha --group wren-android-testers@googlegroups.com

The tester list is one of the few closed-testing things that *is* API-writable
-- `edits.testers.update` with `{"googleGroups": [...]}` -- so it needs no
browser. The group itself does: Google Groups raises a reCAPTCHA on creation,
on adding a member and on changing a role, and each of those is a human click.

Two traps live in the group rather than here, and both cost a day on
2026-08-28 with Easy-Post:

* **Create the group under the Play developer account.** That is
  `Apps@spencerfields.com`, which Chrome holds at path `u/1`. The default at
  `u/0` is a different Spencer account, and a group created there cannot simply
  be moved -- a released googlegroups.com address is never reusable, so
  delete-and-recreate loses the name.

* **Two visibility settings matter, not one.** "Who can join group" =
  *Anyone can join* is what makes self-service opt-in work, but with "Who can
  search for the group" left at *Group members* a non-member following the join
  link is refused, which looks like a broken link rather than a setting. Set
  both to the web. Conversations stay at *Group members*, so what testers say
  is still private.

Never conclude from a Groups listing that a blocked write did nothing: after a
CAPTCHA, "My groups" has read zero while the group existed. Load
`groups.google.com/g/<name>` directly and look.
"""
import argparse
import os
import sys

import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from play_listing import BASE, PACKAGE, access_token, credentials  # noqa: E402

TRACKS = ("internal", "alpha", "beta", "production")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--track", default="alpha", choices=TRACKS)
    ap.add_argument("--group", help="full googlegroups.com address")
    ap.add_argument("--show", action="store_true", help="read every track and stop")
    args = ap.parse_args()

    h = {"Authorization": "Bearer " + access_token(credentials())}
    edit = requests.post("%s/applications/%s/edits" % (BASE, PACKAGE),
                         headers=h, timeout=60).json()["id"]

    def discard():
        requests.delete("%s/applications/%s/edits/%s" % (BASE, PACKAGE, edit),
                        headers=h, timeout=60)

    if args.show or not args.group:
        for track in TRACKS:
            r = requests.get("%s/applications/%s/edits/%s/testers/%s"
                             % (BASE, PACKAGE, edit, track), headers=h, timeout=60)
            print("%-11s %s" % (track, r.text.strip() or "(empty)"))
        discard()
        if not args.group:
            print("\nnothing written. Pass --group to set one.")
        return

    r = requests.put(
        "%s/applications/%s/edits/%s/testers/%s" % (BASE, PACKAGE, edit, args.track),
        headers={**h, "Content-Type": "application/json"},
        json={"googleGroups": [args.group]}, timeout=120)
    if r.status_code >= 400:
        discard()
        sys.exit("testers.update failed: %s\n%s" % (r.status_code, r.text[:800]))

    c = requests.post("%s/applications/%s/edits/%s:commit" % (BASE, PACKAGE, edit),
                      headers=h, timeout=120)
    if c.status_code >= 400:
        discard()
        sys.exit("commit failed: %s\n%s" % (c.status_code, c.text[:800]))

    # Read it back through a fresh edit. A commit that returns 200 says the edit
    # applied, not that the track now names the group.
    edit2 = requests.post("%s/applications/%s/edits" % (BASE, PACKAGE),
                          headers=h, timeout=60).json()["id"]
    back = requests.get("%s/applications/%s/edits/%s/testers/%s"
                        % (BASE, PACKAGE, edit2, args.track), headers=h, timeout=60).json()
    requests.delete("%s/applications/%s/edits/%s" % (BASE, PACKAGE, edit2),
                    headers=h, timeout=60)

    got = back.get("googleGroups") or []
    print("%s testers now: %s" % (args.track, got or "(empty)"))
    if args.group not in got:
        sys.exit("committed, but the track does not name the group -- does it exist yet?")
    print("ok")


if __name__ == "__main__":
    main()
