# -*- coding: utf-8 -*-
"""Push Wren's translated Play listing and product listings.

    python store/play_locales.py --plan     # what would change; writes nothing
    python store/play_locales.py --apply

The English is `store/play/LISTING.md` (the store listing) and Play's own
en-GB product listings, both copied into `store/play/listing/en.json` by
`--export`. Translations of that file arrive from sgf36/Translation-Agents as
`store/play/listing/<code>.json`, one per app-UI locale, and this pushes them:

* the store listing per language: title (always "Wren"), short and full
  description. Screenshots, icon and feature graphic are not touched, so every
  language shows the en-GB images, which is Play's fallback.
* each one-time product's title and description per language, merged into the
  listings it already has rather than replacing them.

`--plan` refuses to go further if en.json has drifted from LISTING.md: a
translation of yesterday's English is not a translation of the listing.
"""
import argparse
import json
import os
import sys

import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from play_listing import (BASE, LIMITS, PACKAGE, access_token,  # noqa: E402
                          credentials, listing_text)

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.join(HERE, "play", "listing")
ENGLISH = os.path.join(DIR, "en.json")

# Translation-Agents' locale code -> Play's language code. Play uses its own
# tags, several of them not BCP 47 (Hebrew is iw-IL). Anything absent here is
# not a language Play accepts for a listing and is skipped, loudly.
PLAY_CODE = {
    "ar": "ar", "bn": "bn-BD", "ca": "ca", "cs": "cs-CZ", "da": "da-DK",
    "de": "de-DE", "el": "el-GR", "es": "es-ES", "es_MX": "es-419",
    "fi": "fi-FI", "fr": "fr-FR", "fr_CA": "fr-CA", "gu": "gu", "he": "iw-IL",
    "hi": "hi-IN", "hr": "hr", "hu": "hu-HU", "id": "id", "it": "it-IT",
    "ja": "ja-JP", "kn": "kn-IN", "ko": "ko-KR", "ml": "ml-IN", "mr": "mr-IN",
    "ms": "ms", "nl": "nl-NL", "no": "no-NO", "pa": "pa", "pl": "pl-PL",
    "pt": "pt-BR", "pt_PT": "pt-PT", "ro": "ro", "ru": "ru-RU", "sk": "sk",
    "sl": "sl", "sv": "sv-SE", "ta": "ta-IN", "te": "te-IN", "th": "th",
    "tr": "tr-TR", "uk": "uk", "ur": "ur", "vi": "vi", "zh": "zh-CN",
    "zh_Hant": "zh-TW",
}

PRODUCTS = {
    "unlimited": "com.spencerfields.littlebird.unlimited",
    "everything": "com.spencerfields.littlebird.everything",
    "reels": "com.spencerfields.littlebird.reels.upgrade",
}
PRODUCT_LIMITS = {"title": 55, "description": 200}
KEYS = ["shortDescription", "fullDescription"] + [
    "%s%s" % (k, f) for k in PRODUCTS for f in ("Title", "Description")]


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def problems(d):
    """Every reason Play would refuse this file, or would show it wrong."""
    out = [k + " missing" for k in KEYS if not str(d.get(k, "")).strip()]
    out += [k + " not in the English" for k in d if k not in KEYS]
    for k, cap in (("shortDescription", LIMITS["shortDescription"]),
                   ("fullDescription", LIMITS["fullDescription"])):
        if len(d.get(k, "")) > cap:
            out.append("%s %d > %d" % (k, len(d[k]), cap))
    for p in PRODUCTS:
        for f, cap in PRODUCT_LIMITS.items():
            k = p + f.capitalize()
            if len(d.get(k, "")) > cap:
                out.append("%s %d > %d" % (k, len(d[k]), cap))
    return out


def translations():
    got = {}
    for name in sorted(os.listdir(DIR)):
        code, ext = os.path.splitext(name)
        if ext != ".json" or code == "en":
            continue
        if code not in PLAY_CODE:
            print("SKIP %s: not a Play listing language" % name)
            continue
        got[code] = load(os.path.join(DIR, name))
    return got


def export():
    _, short, full = listing_text()
    d = load(ENGLISH) if os.path.exists(ENGLISH) else {}
    d["shortDescription"], d["fullDescription"] = short, full
    with open(ENGLISH, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
    print("wrote", ENGLISH)


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--plan", action="store_true")
    g.add_argument("--apply", action="store_true")
    g.add_argument("--export", action="store_true",
                   help="copy LISTING.md's descriptions into en.json")
    args = ap.parse_args()
    if args.export:
        export()
        return

    title, short, full = listing_text()
    en = load(ENGLISH)
    if (en["shortDescription"], en["fullDescription"]) != (short, full):
        sys.exit("en.json differs from LISTING.md: run --export, then "
                 "retranslate, before pushing anything")

    langs = translations()
    bad = {c: problems(d) for c, d in langs.items() if problems(d)}
    for c, p in bad.items():
        print("REFUSE %s: %s" % (c, "; ".join(p)))
    langs = {c: d for c, d in langs.items() if c not in bad}
    print("%d languages ready: %s" % (
        len(langs), " ".join(PLAY_CODE[c] for c in langs)))
    if args.plan or not langs:
        return

    h = {"Authorization": "Bearer " + access_token(credentials())}
    j = {**h, "Content-Type": "application/json"}

    edit = requests.post("%s/applications/%s/edits" % (BASE, PACKAGE),
                         headers=h, timeout=60).json()["id"]
    refused = []
    for code, d in langs.items():
        lang = PLAY_CODE[code]
        r = requests.put("%s/applications/%s/edits/%s/listings/%s"
                         % (BASE, PACKAGE, edit, lang), headers=j, timeout=60,
                         json={"language": lang, "title": title,
                               "shortDescription": d["shortDescription"],
                               "fullDescription": d["fullDescription"]})
        if r.status_code >= 400:
            refused.append("%s: %s %s" % (lang, r.status_code, r.text[:200]))
    r = requests.post("%s/applications/%s/edits/%s:commit"
                      % (BASE, PACKAGE, edit), headers=h, timeout=300)
    if r.status_code >= 400:
        sys.exit("listing commit failed: %s %s" % (r.status_code, r.text[:800]))
    print("store listing committed for %d languages" % (len(langs) - len(refused)))

    # Products: merge, never replace. A listing language present on Play and
    # absent here (en-GB, at least) must survive.
    for key, pid in PRODUCTS.items():
        prod = requests.get("%s/applications/%s/oneTimeProducts/%s"
                            % (BASE, PACKAGE, pid), headers=h, timeout=60).json()
        have = {l["languageCode"]: l for l in prod.get("listings", [])}
        for code, d in langs.items():
            have[PLAY_CODE[code]] = {
                "languageCode": PLAY_CODE[code],
                "title": d[key + "Title"],
                "description": d[key + "Description"]}
        prod["listings"] = list(have.values())
        r = requests.post(
            "%s/applications/%s/oneTimeProducts:batchUpdate" % (BASE, PACKAGE),
            headers=j, timeout=120,
            json={"requests": [{"oneTimeProduct": prod, "updateMask": "listings",
                                "regionsVersion": prod["regionsVersion"]}]})
        if r.status_code >= 400:
            refused.append("%s: %s %s" % (pid, r.status_code, r.text[:300]))
        else:
            print("%s: %d listings" % (pid, len(prod["listings"])))

    for line in refused:
        print("REFUSED " + line)
    if refused:
        sys.exit(1)


if __name__ == "__main__":
    main()
