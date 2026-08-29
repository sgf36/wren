"""Build Wren's App Analytics campaign links from the registry.

    python store/campaign_links.py            # print the links
    python store/campaign_links.py --check    # validate only, exit 1 on a fault

Why this exists rather than a list of links in a document.

**Apple matches campaign tokens literally.** `ig-organic-gone-by-thursday` and
`IG-Organic-Gone-By-Thursday` are two rows under Acquisition > Campaigns that
Apple will never merge, and a single typo silently mints a third. Hand-typed
tokens across a dozen posts fragment into data that looks fine until you try to
read it, and by then the traffic that produced it is months gone. So the tokens
live in `campaigns.json` and the links are generated. Nobody types a token.

## Two things about this that are not guessable, both verified 2026-08-29

**`pt` is required, and you cannot invent it.** Apple generates the provider
token when the FIRST campaign link is created in App Store Connect, under
Analytics > Acquisition > Campaigns > the add button. It is then the same six
digits for every campaign afterwards. A link without `pt=` is still a working
App Store link -- it opens the page, installs happen, and **none of it is
attributed**. That failure is silent and unrecoverable, which is why this script
refuses to print anything until `providerToken` is filled in.

**There is no API for this.** `analyticsCampaigns`, `campaigns` and the app-scoped
variants all answer 404 under both the submission key and the analytics key, so
the 404 is the API's shape rather than a permissions gap. Campaigns are created
in the console and only the links are mechanical.

## The limit that will bite

`ct` is **30 characters**. Apple permits alphanumerics, spaces and a specific
punctuation set, but a space may not lead or trail. This file enforces a
narrower convention than Apple allows -- lowercase, digits and hyphens only --
because the failure mode here is case and separator drift, not exotic
punctuation. `ig-organic-gone-by-thursday` is 27 characters, so a longer
creative name will breach the limit rather than be truncated silently.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
REGISTRY = HERE / "campaigns.json"

CT_LIMIT = 30
TOKEN_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


def load() -> dict:
    return json.loads(REGISTRY.read_text(encoding="utf8"))


def problems(data: dict) -> list[str]:
    """Everything wrong with the registry, rather than the first thing."""
    out: list[str] = []
    seen: dict[str, int] = {}

    for i, c in enumerate(data.get("campaigns", [])):
        tok = c.get("token", "")
        where = f"campaigns[{i}]"

        if not tok:
            out.append(f"{where}: no token")
            continue
        if len(tok) > CT_LIMIT:
            out.append(f"{where} {tok!r}: {len(tok)} characters, limit is {CT_LIMIT}")
        if not TOKEN_RE.match(tok):
            out.append(
                f"{where} {tok!r}: must be lowercase letters, digits and single "
                f"hyphens. Apple allows more, but case and separator drift is how "
                f"one campaign becomes three rows.")
        if tok in seen:
            out.append(f"{where} {tok!r}: already used by campaigns[{seen[tok]}]")
        else:
            seen[tok] = i

        for field in ("channel", "surface", "creative"):
            if not c.get(field):
                out.append(f"{where} {tok!r}: {field} is empty")

    if not data.get("appId"):
        out.append("appId is missing")
    return out


def links(data: dict) -> list[tuple[str, str]]:
    pt = data["providerToken"]
    app = data["appId"]
    return [
        (c["token"],
         f"https://apps.apple.com/app/apple-store/id{app}"
         f"?pt={pt}&ct={c['token']}&mt=8")
        for c in data["campaigns"]
    ]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="validate only; print nothing on success")
    args = ap.parse_args()

    data = load()
    faults = problems(data)
    if faults:
        print("registry is not usable:", file=sys.stderr)
        for f in faults:
            print(f"  {f}", file=sys.stderr)
        return 1

    if args.check:
        return 0

    if not data.get("providerToken"):
        print(
            "No providerToken yet, so no link can be generated.\n"
            "\n"
            "Apple mints it when the FIRST campaign link is created in App Store\n"
            "Connect: Analytics > Acquisition > Campaigns > +. Create one campaign\n"
            "there using any token from this registry, read the six digits after\n"
            "pt= in the link it gives back, and put them in campaigns.json.\n"
            "Every other link is then generated from here.\n"
            "\n"
            "A link without pt= still opens the App Store and still installs.\n"
            "It is simply never attributed, and that cannot be recovered later.",
            file=sys.stderr)
        return 1

    width = max(len(t) for t, _ in links(data))
    for tok, url in links(data):
        print(f"{tok.ljust(width)}  {url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
