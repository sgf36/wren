"""Country lookup for /get/'s anonymous tally: MaxMind GeoLite2 on the web host.

    python store/geo.py --deploy   # upload server/geo/ to <home>/wren-geo (outside the web root)
    python store/geo.py --config   # write maxmind.json from Credential Manager (maxmind-geolite)
    python store/geo.py --update   # download the current database now, on the server
    python store/geo.py --cron     # install the weekly update (idempotent)
    python store/geo.py --check    # look up known addresses on the server; print status

Why it is shaped like this: the database must be no more than 30 days behind
MaxMind's latest (GeoLite2 licence), so the server updates itself weekly
rather than relying on anyone remembering. --update and --check run PHP on the
server through a throwaway, randomly named script that is deleted straight
after and confirmed gone by listing; this host has no shell.
"""
import argparse
import json
import pathlib
import secrets
import sys

import requests

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from get_redirect import HOST, REMOTE, UA_BROWSER, listing, session  # noqa: E402

try:
    import keyring
except ImportError:
    keyring = None

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "server" / "geo"
HOME = "/home2/spencgh6"
GEO = HOME + "/wren-geo"
# Weekly, Tuesday 04:17 server time: MaxMind publishes on Tuesdays and Fridays.
CRON = {"minute": "17", "hour": "4", "day": "*", "month": "*", "weekday": "2"}


def api2(s, module, func, **params):
    return s.get(HOST + "/json-api/cpanel", params={"cpanel_jsonapi_module": module, "cpanel_jsonapi_func": func,
                                                    "cpanel_jsonapi_apiversion": 2, **params}, timeout=60).json()


def mkdir(s, parent, name, perms="0755"):
    if name not in listing(s, parent):
        api2(s, "Fileman", "mkdir", path=parent, name=name, permissions=perms)
        if name not in listing(s, parent):
            sys.exit("could not create %s/%s" % (parent, name))


def save(s, directory, name, content):
    r = s.post(HOST + "/execute/Fileman/save_file_content",
               data={"dir": directory, "file": name, "content": content}, timeout=60).json()
    if r.get("errors") or not r.get("status"):
        sys.exit("upload of %s/%s failed: %s" % (directory, name, r.get("errors")))


def deploy(s):
    mkdir(s, HOME, "wren-geo", "0700")
    mkdir(s, GEO, "MaxMind")
    mkdir(s, GEO + "/MaxMind", "Db")
    mkdir(s, GEO + "/MaxMind/Db", "Reader")
    for f in sorted(SRC.rglob("*")):
        if f.is_file():
            rel = f.relative_to(SRC).as_posix()
            d = (GEO + "/" + rel).rsplit("/", 1)[0]
            save(s, d, f.name, f.read_text(encoding="utf-8"))
            print("uploaded wren-geo/" + rel)


def config(s):
    acct = keyring and keyring.get_password("maxmind-geolite", "account-id")
    key = keyring and keyring.get_password("maxmind-geolite", "license-key")
    if not acct or not key:
        sys.exit("no MaxMind credentials in Credential Manager (maxmind-geolite: account-id, license-key)")
    save(s, GEO, "maxmind.json", json.dumps({"account": acct, "key": key}))
    print("wrote wren-geo/maxmind.json")


def run_php(s, body):
    """Run PHP on the server once, via a throwaway script in the web root."""
    name = "geo-%s.php" % secrets.token_hex(12)
    save(s, REMOTE, name, "<?php\n" + body)
    try:
        r = requests.get("https://wren.spencerfields.com/" + name, headers={"User-Agent": UA_BROWSER}, timeout=180)
        return r.status_code, r.text
    finally:
        api2(s, "Fileman", "fileop", op="unlink", sourcefiles=REMOTE + "/" + name)
        if name in listing(s, REMOTE):
            print("WARNING: could not delete %s/%s -- delete it by hand" % (REMOTE, name))


def update(s):
    code, text = run_php(s, "define('WREN_GEO_UPDATE', true);\nrequire '%s/update.php';\n"
                            "header('Content-Type: application/json');\necho json_encode(geo_update());\n" % GEO)
    print(code, text.strip()[:400])
    return code == 200 and '"ok":true' in text


def check(s):
    code, text = run_php(s, "require '%s/geo.php';\nheader('Content-Type: application/json');\n"
                            "echo json_encode(['us' => geo_country('8.8.8.8'), 'gb' => geo_country('81.2.69.142'),\n"
                            "  'bad' => geo_country('not an ip'), 'status' => json_decode((string) @file_get_contents('%s/status.json'), true),\n"
                            "  'php' => PHP_BINARY]);\n" % (GEO, GEO))
    print(code, text.strip()[:600])
    return code == 200 and '"us":"US"' in text and '"gb":"GB"' in text


def cron(s):
    jobs = api2(s, "Cron", "listcron").get("cpanelresult", {}).get("data", []) or []
    if any("wren-geo/update.php" in (j.get("command") or "") for j in jobs):
        print("weekly update already installed")
        return True
    code, text = run_php(s, "echo PHP_BINARY;\n")
    php = text.strip()
    if code != 200 or not php.startswith("/"):
        sys.exit("could not find the server's PHP binary: %s %s" % (code, text[:200]))
    # PHP_BINARY under the web server can be php-fpm/lsphp; the CLI sits beside it.
    php = php.replace("php-fpm", "php").replace("lsphp", "php")
    command = "%s %s/update.php >/dev/null 2>&1" % (php, GEO)
    r = api2(s, "Cron", "add_line", command=command, **CRON)
    jobs = api2(s, "Cron", "listcron").get("cpanelresult", {}).get("data", []) or []
    ok = any("wren-geo/update.php" in (j.get("command") or "") for j in jobs)
    print(("installed: " if ok else "FAILED to install: ") + command, "" if ok else r)
    return ok


def main():
    ap = argparse.ArgumentParser()
    for flag in ("deploy", "config", "update", "cron", "check"):
        ap.add_argument("--" + flag, action="store_true")
    a = ap.parse_args()
    s = session()
    ok = True
    if a.deploy:
        deploy(s)
    if a.config:
        config(s)
    if a.update:
        ok = update(s) and ok
    if a.cron:
        ok = cron(s) and ok
    if a.check:
        ok = check(s) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
