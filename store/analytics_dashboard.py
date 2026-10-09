"""Publish and configure wren.spencerfields.com/analytics, the private advert dashboard.

    python store/analytics_dashboard.py --deploy   # upload web/analytics/ and check it from outside
    python store/analytics_dashboard.py --config   # write the server's config.json from Credential Manager
    python store/analytics_dashboard.py --check    # outside checks only: gate holds, nothing leaks
    python store/analytics_dashboard.py --status   # which sources are configured (names, never values)

The page is PHP on the Bluehost account that serves the site. Like /get/, the
site's i18n deploy does not publish it, so this does, over the cPanel API.

## Where the secrets are, and why they are these secrets

This repository is public, so the page's code holds nothing secret. The server
reads <home>/wren-analytics/config.json, outside every web root, written by
--config from Windows Credential Manager (service "wren-dashboard") and two key
files in Apps\\Claude\\signing\\wren-dashboard\\. Set the Credential Manager
entries with Apps\\Claude\\scripts\\Set-WrenDashboardSecrets.ps1.

Every key in that file is a read-only one made for this page alone. The WordPress
site at spencerfields.com runs as the same cPanel user and can read the file, so
it must hold nothing that can spend money or change an app:
  meta-token     a system-user token with ads_read only, NOT the ads_management
                 token the campaign scripts use (keyring metaads-api)
  App Store key  role "Sales and Reports", NOT the App Manager or Admin keys
  Google         a service account that can only read GA4 and Play's report
                 bucket, NOT the Play publishing account
  tiktok-token   TikTok API for Business, reporting scopes only
--config refuses a Meta token that carries ads_management.
"""
import argparse
import json
import pathlib
import sys
import time

import requests

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from get_redirect import HOST, REMOTE, UA_BROWSER, listing, session  # noqa: E402

try:
    import keyring
except ImportError:
    keyring = None

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAGE = ROOT / "web" / "analytics"
FILES = [".htaccess", "lib.php", "sources.php", "index.php", "auth.php", "api.php", "login.js", "app.js", "app.css"]
URL = "https://wren.spencerfields.com/analytics/"
HOME = "/home2/spencgh6"
PRIVATE = HOME + "/wren-analytics"
SIGNING = pathlib.Path(r"C:\Users\SpencerFields\OneDrive - Spencer Fields\Apps\Claude\signing\wren-dashboard")
SERVICE = "wren-dashboard"

# Not secret, and fixed. The ad account ids are not secret either but are kept
# out of this public repository: Credential Manager meta-ad-account, tiktok-advertiser.
ALLOWED_EMAILS = ["apps@spencerfields.com"]
ASC_ISSUER = "65aee88f-46c4-4daf-8238-5dc37263d06b"
ASC_REQUEST = "71f7b4cf-a0a3-4b50-bc9b-f6734637b651"  # see analytics.py: the only handle on it


def mkdir(s, parent, name):
    # UAPI has no mkdir on this host and API2 reports success for failures: list to check.
    if name not in listing(s, parent):
        s.get(HOST + "/json-api/cpanel", params={"cpanel_jsonapi_module": "Fileman", "cpanel_jsonapi_func": "mkdir",
                                                "cpanel_jsonapi_apiversion": 2, "path": parent, "name": name,
                                                "permissions": "0700" if parent == HOME else "0755"}, timeout=60)
        if name not in listing(s, parent):
            sys.exit("could not create %s/%s" % (parent, name))


def save(s, directory, name, content):
    r = s.post(HOST + "/execute/Fileman/save_file_content",
               data={"dir": directory, "file": name, "content": content}, timeout=60).json()
    if r.get("errors") or not r.get("status"):
        sys.exit("upload of %s/%s failed: %s" % (directory, name, r.get("errors")))


def deploy():
    s = session()
    mkdir(s, REMOTE, "analytics")
    for name in FILES:
        save(s, REMOTE + "/analytics", name, (PAGE / name).read_text(encoding="utf-8"))
        print("uploaded analytics/%s" % name)
    # The funnel counter the app posts to (web/f/), read by the dashboard.
    mkdir(s, REMOTE, "f")
    save(s, REMOTE + "/f", "index.php", (ROOT / "web" / "f" / "index.php").read_text(encoding="utf-8"))
    print("uploaded f/index.php")
    return check()


def check():
    """What a stranger sees. Every line must say ok."""
    ua = {"User-Agent": UA_BROWSER}
    bad = 0

    def expect(label, cond, detail):
        nonlocal bad
        bad += 0 if cond else 1
        print("  %-4s %-44s %s" % ("ok" if cond else "FAIL", label, detail))

    time.sleep(1)
    r = requests.get(URL, headers=ua, timeout=30)
    expect("sign-in page answers", r.status_code == 200 and "Private page" in r.text, r.status_code)
    expect("no figures on the sign-in page", "Wren adverts" not in r.text, "")
    expect("noindex header", "noindex" in r.headers.get("X-Robots-Tag", ""), r.headers.get("X-Robots-Tag"))
    expect("CSP header", "frame-ancestors 'none'" in r.headers.get("Content-Security-Policy", ""), "")
    expect("session cookie is __Host-, Secure, HttpOnly, Strict",
           all(x in r.headers.get("Set-Cookie", "") for x in ("__Host-wren_dash", "secure", "HttpOnly", "SameSite=Strict")),
           r.headers.get("Set-Cookie", "")[:0])
    r = requests.get(URL + "api.php", headers=ua, timeout=30)
    expect("api.php refuses without sign-in", r.status_code == 401, r.status_code)
    for name in ("lib.php", "sources.php"):
        r = requests.get(URL + name, headers=ua, timeout=30)
        expect("%s not served" % name, r.status_code in (403, 404) and "<?php" not in r.text, r.status_code)
    r = requests.get(URL + "auth.php", headers=ua, timeout=30)
    expect("auth.php refuses GET", r.status_code == 405, r.status_code)
    r = requests.post(URL + "auth.php", headers=dict(ua, Origin="https://evil.example"), data={"action": "login"}, timeout=30)
    expect("auth.php refuses another origin", r.status_code == 403, r.status_code)
    r = requests.post(URL + "auth.php", headers=dict(ua, Origin="https://wren.spencerfields.com"),
                      data={"action": "login", "credential": "x.y.z", "csrf": "nope"}, timeout=30)
    expect("auth.php refuses a missing CSRF token", r.status_code == 403, r.status_code)
    r = requests.get("https://wren.spencerfields.com/wren-analytics/config.json", headers=ua, timeout=30)
    expect("config is not under the web root", r.status_code == 404, r.status_code)
    # A step the server does not know must be dropped, and still answer 204.
    r = requests.post("https://wren.spencerfields.com/f/", headers=ua, timeout=30,
                      json={"e": "not_a_step", "p": "ios", "v": "0.0.0", "l": "en"})
    expect("funnel counter answers and drops unknown steps", r.status_code == 204, r.status_code)
    r = requests.get("https://wren.spencerfields.com/funnel-counts/", headers=ua, timeout=30)
    expect("funnel counts are not under the web root", r.status_code == 404, r.status_code)
    print("all checks passed" if not bad else "%d check(s) FAILED" % bad)
    return 1 if bad else 0


def secret(name):
    return (keyring.get_password(SERVICE, name) or "").strip() if keyring else ""


def build_config():
    cfg = {"allowed_emails": ALLOWED_EMAILS, "google_client_id": secret("google-client-id")}

    token = secret("meta-token")
    if token:
        # Not debug_token: Meta answers that only for the app's admins and developers,
        # which an Employee system user deliberately is not. /me/permissions works for
        # any token and lists exactly what it was granted.
        d = requests.get("https://graph.facebook.com/v25.0/me/permissions",
                         params={"access_token": token}, timeout=30).json()
        if "data" not in d:
            sys.exit("meta-token was refused (%s); nothing was written" % d.get("error", {}).get("message", "?")[:120])
        scopes = {p["permission"] for p in d["data"] if p.get("status") == "granted"}
        if "ads_read" not in scopes:
            sys.exit("meta-token lacks ads_read; nothing was written")
        if scopes & {"ads_management", "business_management", "pages_manage_ads"}:
            sys.exit("meta-token can manage ads (%s). Make an ads_read-only token; nothing was written"
                     % ", ".join(sorted(scopes & {"ads_management", "business_management", "pages_manage_ads"})))
        cfg["meta"] = {"token": token, "ad_account": secret("meta-ad-account")}

    p8 = sorted(SIGNING.glob("AuthKey_*.p8")) if SIGNING.is_dir() else []
    if len(p8) > 1:
        sys.exit("more than one AuthKey_*.p8 in %s; keep only the Sales and Reports key" % SIGNING)
    if p8:
        cfg["asc"] = {"key_id": p8[0].stem.split("_", 1)[1], "issuer": ASC_ISSUER, "request_id": ASC_REQUEST,
                      "p8": p8[0].read_text(encoding="utf-8"), "vendor_number": secret("asc-vendor-number")}

    sa = SIGNING / "service-account.json"
    if sa.is_file():
        j = json.loads(sa.read_text(encoding="utf-8"))
        cfg["google"] = {"service_account": {"client_email": j["client_email"], "private_key": j["private_key"]},
                         "ga4_property": secret("ga4-property"), "play_bucket": secret("play-bucket")}

    if secret("tiktok-token"):
        cfg["tiktok"] = {"access_token": secret("tiktok-token"), "advertiser_id": secret("tiktok-advertiser")}
    return cfg


def describe(cfg):
    g = cfg.get("google", {})
    rows = [
        ("Google sign-in client id", bool(cfg.get("google_client_id"))),
        ("Meta (read-only token)", "meta" in cfg),
        ("App Store Connect (Sales and Reports key)", "asc" in cfg),
        ("  vendor number (sales reports: in-app purchases)", bool(cfg.get("asc", {}).get("vendor_number"))),
        ("Google service account", bool(g)),
        ("  GA4 property id", bool(g.get("ga4_property"))),
        ("  Play report bucket", bool(g.get("play_bucket"))),
        ("TikTok API token", "tiktok" in cfg),
    ]
    for label, ok in rows:
        print("  %-4s %s" % ("set" if ok else "--", label))


def write_config():
    cfg = build_config()
    describe(cfg)
    if not cfg["google_client_id"]:
        sys.exit("google-client-id is not set; without it nobody can sign in. Nothing was written")
    s = session()
    mkdir(s, HOME, "wren-analytics")
    save(s, PRIVATE, "config.json", json.dumps(cfg, indent=1))
    print("config.json written to %s (%d bytes, values not shown)" % (PRIVATE, len(json.dumps(cfg))))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--deploy", action="store_true")
    g.add_argument("--config", action="store_true")
    g.add_argument("--check", action="store_true")
    g.add_argument("--status", action="store_true")
    a = ap.parse_args()
    if a.deploy:
        return deploy()
    if a.config:
        return write_config()
    if a.status:
        describe(build_config())
        return 0
    return check()


if __name__ == "__main__":
    sys.exit(main())
