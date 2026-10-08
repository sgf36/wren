"""Build and publish wren.spencerfields.com/get/, the one link that works on every phone.

    python store/get_redirect.py            # regenerate web/get/tokens.json from campaigns.json
    python store/get_redirect.py --deploy   # ...then upload web/get/ and test it live
    python store/get_redirect.py --links    # print the /get/ link for every campaign
    python store/get_redirect.py --counts   # this month's daily taps per token and device

tokens.json is generated, never edited: campaigns.json is the only place a token
is defined (see campaign_links.py for why). Run this after adding a campaign, or
the redirect sends that campaign's visitors on untagged.

The page itself is web/get/index.php. The site's i18n deploy publishes only its
listed HTML pages, so /get/ is published here, by the cPanel API, with the same
token lookup the site uses (Credential Manager cpanel-littlebird-site or
cpanel-easypost-site, account spencgh6; CPANEL_API_TOKEN overrides).
"""
import json
import os
import pathlib
import re
import sys

import requests

try:
    import keyring
except ImportError:
    keyring = None

ROOT = pathlib.Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "store" / "campaigns.json"
GET = ROOT / "web" / "get"
HOST = "https://box5192.bluehost.com:2083"
USER = "spencgh6"
REMOTE = "/home2/spencgh6/wren.spencerfields.com"
URL = "https://wren.spencerfields.com/get/"
UA_BROWSER = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0 Safari/537.36"
UA_IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
UA_ANDROID = "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 Chrome/128.0 Mobile Safari/537.36"


def source(channel):
    """utm_source for a registry channel: lowercase, letters and digits only."""
    return re.sub(r"[^a-z0-9]", "", channel.lower()) or "unknown"


def generate():
    reg = json.loads(REGISTRY.read_text(encoding="utf-8"))["campaigns"]
    tokens = {c["token"]: {"source": source(c["channel"]), "medium": c["surface"]} for c in reg}
    GET.mkdir(parents=True, exist_ok=True)
    (GET / "tokens.json").write_text(json.dumps(tokens, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return tokens


def session():
    t = os.environ.get("CPANEL_API_TOKEN")
    if not t and keyring:
        t = keyring.get_password("cpanel-littlebird-site", USER) or keyring.get_password("cpanel-easypost-site", USER)
    if not t:
        sys.exit("no cPanel token")
    s = requests.Session()
    s.headers.update({"Authorization": "cpanel %s:%s" % (USER, t.strip()), "User-Agent": UA_BROWSER})
    return s


def listing(s, d):
    r = s.get(HOST + "/execute/Fileman/list_files", params={"dir": d, "show_hidden": 1}, timeout=60).json()
    return {f["file"] for f in (r.get("data") or [])}


def deploy(tokens):
    s = session()
    # UAPI has no mkdir here and API2 reports success for failures: check by listing.
    if "get" not in listing(s, REMOTE):
        s.get(HOST + "/json-api/cpanel", params={"cpanel_jsonapi_module": "Fileman", "cpanel_jsonapi_func": "mkdir",
                                                "cpanel_jsonapi_apiversion": 2, "path": REMOTE, "name": "get"}, timeout=60)
        if "get" not in listing(s, REMOTE):
            sys.exit("could not create %s/get" % REMOTE)
    for name in ("index.php", "tokens.json"):
        r = s.post(HOST + "/execute/Fileman/save_file_content",
                   data={"dir": REMOTE + "/get", "file": name, "content": (GET / name).read_text(encoding="utf-8")},
                   timeout=60).json()
        if r.get("errors"):
            sys.exit("upload of %s failed: %s" % (name, r["errors"]))
        print("uploaded get/%s" % name)
    test(tokens)


def test(tokens):
    tok = "tt-paid-app-install"
    expect = [
        (UA_IPHONE, tok, "https://apps.apple.com/app/apple-store/id6802053382?pt=129201947&ct=%s&mt=8" % tok),
        (UA_ANDROID, tok, "https://play.google.com/store/apps/details?id=com.spencerfields.littlebird"
                          "&utm_source=%s&utm_medium=%s&utm_campaign=%s" % (tokens[tok]["source"], tokens[tok]["medium"], tok)),
        (UA_BROWSER, tok, "https://wren.spencerfields.com/"),
        (UA_IPHONE, "not-a-token", "https://apps.apple.com/app/apple-store/id6802053382?pt=129201947&mt=8"),
        (UA_ANDROID, "", "https://play.google.com/store/apps/details?id=com.spencerfields.littlebird"),
    ]
    bad = 0
    for ua, c, want in expect:
        # X-Wren-Probe keeps these checks out of the daily tally.
        r = requests.get(URL, params={"c": c} if c else None, headers={"User-Agent": ua, "X-Wren-Probe": "1"},
                         allow_redirects=False, timeout=30)
        got = r.headers.get("Location")
        ok = r.status_code == 302 and got == want
        bad += not ok
        print("%s %-8s c=%-22s -> %s %s" % ("ok  " if ok else "FAIL", ua.split("(")[1].split(";")[0], c or "(none)", r.status_code, got))
    if bad:
        sys.exit("%d redirect check(s) failed" % bad)


def counts():
    """Print this month's tally: taps per day, token and device, as index.php kept it."""
    import datetime as dt
    s = session()
    month = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m")
    r = s.get(HOST + "/execute/Fileman/get_file_content",
              params={"dir": "/home2/spencgh6/get-counts", "file": month + ".json"}, timeout=60).json()
    text = (r.get("data") or {}).get("content")
    if not text:
        print("no taps recorded yet for %s" % month)
        return
    data = json.loads(text)
    if not data:
        print("no taps recorded yet for %s" % month)
        return
    for day, toks in sorted(data.items()):
        for tok, dev in sorted(toks.items()):
            print("%s  %-26s %s" % (day, tok, "  ".join("%s %d" % kv for kv in sorted(dev.items()))))


def main():
    if "--counts" in sys.argv:
        counts()
        return
    tokens = generate()
    print("tokens.json: %d campaigns" % len(tokens))
    if "--links" in sys.argv:
        for t in tokens:
            print("%-28s %s?c=%s" % (t, URL, t))
    if "--deploy" in sys.argv:
        deploy(tokens)


if __name__ == "__main__":
    main()
