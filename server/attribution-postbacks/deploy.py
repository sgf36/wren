"""Publish index.php to both Apple postback paths on spencerfields.com, and read what arrived.

    python deploy.py            # create the folders, upload, verify by a test POST
    python deploy.py --read     # print this month's postbacks

The cPanel token comes from Windows Credential Manager (service
cpanel-littlebird-site or cpanel-easypost-site, account spencgh6), or the
CPANEL_API_TOKEN environment variable. Never commit it: this repo is public.

cPanel on this host has no UAPI mkdir, so folders go through API2
Fileman::mkdir, and API2 reports success for failures: every step is checked
by listing the folder afterwards (show_hidden=1, the paths start with a dot).
"""
import datetime as dt
import json
import os
import pathlib
import sys

import requests

try:
    import keyring
except ImportError:
    keyring = None

HOST = "https://box5192.bluehost.com:2083"
USER = "spencgh6"
ROOT = "/home2/spencgh6/public_html"
STORE = "/home2/spencgh6/attribution-postbacks"
PATHS = [".well-known/skadnetwork/report-attribution", ".well-known/appattribution/report-attribution"]
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/128.0 Safari/537.36"  # mod_security 406s the default


def token():
    t = os.environ.get("CPANEL_API_TOKEN")
    if not t and keyring:
        t = keyring.get_password("cpanel-littlebird-site", USER) or keyring.get_password("cpanel-easypost-site", USER)
    if not t:
        sys.exit("no cPanel token")
    return t.strip()


S = requests.Session()
S.headers.update({"Authorization": "cpanel %s:%s" % (USER, token()), "User-Agent": UA})


def listing(d):
    r = S.get(HOST + "/execute/Fileman/list_files", params={"dir": d, "show_hidden": 1}, timeout=60).json()
    return {f["file"] for f in (r.get("data") or [])}


def mkdir(parent, name):
    if name in listing(parent):
        return
    S.get(HOST + "/json-api/cpanel", params={"cpanel_jsonapi_module": "Fileman", "cpanel_jsonapi_func": "mkdir",
                                            "cpanel_jsonapi_apiversion": 2, "path": parent, "name": name}, timeout=60)
    if name not in listing(parent):
        sys.exit("could not create %s/%s" % (parent, name))


def main():
    if "--read" in sys.argv:
        f = dt.datetime.now(dt.UTC).strftime("%Y-%m") + ".jsonl"
        r = S.get(HOST + "/execute/Fileman/get_file_content", params={"dir": STORE, "file": f}, timeout=60).json()
        print((r.get("data") or {}).get("content") or "(nothing yet: %s)" % (r.get("errors") or f))
        return
    php = (pathlib.Path(__file__).parent / "index.php").read_text(encoding="utf-8")
    for p in PATHS:
        parent = ROOT
        for part in p.split("/"):
            mkdir(parent, part)
            parent += "/" + part
        r = S.post(HOST + "/execute/Fileman/save_file_content",
                   data={"dir": parent, "file": "index.php", "content": php}, timeout=60).json()
        if r.get("errors") or "index.php" not in listing(parent):
            sys.exit("upload to %s failed: %s" % (parent, r.get("errors")))
        print("uploaded %s/index.php" % parent)
    for p in PATHS:
        url = "https://spencerfields.com/%s/" % p
        g = requests.get(url, headers={"User-Agent": UA}, timeout=30).status_code
        t = requests.post(url, headers={"User-Agent": UA, "Content-Type": "application/json"},
                          data=json.dumps({"deploy-check": dt.datetime.now(dt.UTC).isoformat()}), timeout=30)
        print("%s  GET %s (want 405)  POST %s %r (want 200 'ok')" % (url, g, t.status_code, t.text[:20]))


if __name__ == "__main__":
    main()
