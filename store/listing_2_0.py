"""Bring every App Store listing up to what version 2.0 actually does.

    python store/listing_2_0.py            # show the new lengths
    python store/listing_2_0.py --write    # rewrite the metadata files

Three claims in the live listing become false the moment reading a shared post
ships, and they are the kind of claim a person chooses an app on:

  * "Your screenshots ... are never uploaded, and Wren does not connect to
    Instagram or any other service"
  * "Entering a complimentary access code is the only time Wren contacts a
    server of its own"
  * "FREE, WITH ONE OPTIONAL PURCHASE"

Every one of them is in forty-nine languages, so this edits all forty-nine.

It edits by BLOCK INDEX rather than by matching translated text. All
forty-nine descriptions have the same nineteen blank-line-separated blocks in
the same order — they were translated from one English original and none has
drifted — so the German privacy paragraph is block 13 exactly as the English
one is. Matching on text would mean holding forty-nine translations of the old
wording just to find them, and would fail silently on the one that had been
touched by hand.

Room is the constraint. Apple caps a description at 4000 characters and eight
languages were already past 3940, so nothing here may grow the total: the new
route is deliberately short and the closing section is cut to one sentence to
pay for it. The lengths are asserted before anything is written.
"""
import argparse
import collections
import glob
import io
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# Block indices in the nineteen-block description, before any edit.
WAYS_HEADING, WAYS_INTRO = 2, 3
ROUTES = (4, 5, 6)
PRIVACY = (13, 14)
PRICE_HEADING, PRICE_BODY = 15, 16
CLOSING = 18
BLOCKS = 19

CAPS = {'subtitle': 30, 'promotionalText': 170, 'description': 4000,
        'keywords': 100, 'whatsNew': 4000}

# Per locale: the eight strings that change, plus the two whole fields.
#
#   ways      the "FOUR WAYS IN" heading
#   intro     the sentence under it, saying four rather than three
#   route     the new first route, kept short because there is no room
#   privacy1  Wren has no account; screenshots stay on the phone
#   privacy2  what does leave it, which is now three things and not two
#   price     the heading, now plural
#   pricing   what the two purchases are
#   closing   the Apple Maps limitation, cut to one sentence
#   whatsNew  the release note, which is also what the App Store shows
#   promo     promotional text, 170 characters
TEXT = {}


def load(name):
    """Read one language table out of listing_2_0_<name>.py."""
    path = os.path.join(HERE, f"listing_2_0_{name}.py")
    scope = {}
    with io.open(path, encoding='utf-8') as f:
        exec(compile(f.read(), path, 'exec'), scope)  # noqa: S102
    return scope['TEXT']


for part in ('a', 'b', 'c', 'd', 'e', 'f'):
    try:
        TEXT.update(load(part))
    except FileNotFoundError:
        pass


def rewrite(locale, data):
    """Return the new field values for one locale, or None if untranslated."""
    t = TEXT.get(locale)
    if not t:
        return None
    blocks = data['description'].split('\n\n')
    if len(blocks) != BLOCKS:
        raise SystemExit(
            f"{locale}: description has {len(blocks)} blocks, not {BLOCKS} — "
            f"the structure this file edits by index has drifted")

    blocks[WAYS_HEADING] = t['ways']
    blocks[WAYS_INTRO] = t['intro']
    # The numbers are digits in every language, so renumbering needs no
    # translation — only the new route does.
    for offset, index in enumerate(ROUTES):
        blocks[index] = re.sub(r'^\s*\d+\.', f'{offset + 2}.', blocks[index])
    blocks[PRIVACY[0]] = t['privacy1']
    blocks[PRIVACY[1]] = t['privacy2']
    blocks[PRICE_HEADING] = t['price']
    blocks[PRICE_BODY] = t['pricing']
    blocks[CLOSING] = t['closing']
    blocks.insert(ROUTES[0], t['route'])

    out = dict(data)
    out['description'] = '\n\n'.join(blocks)
    out['whatsNew'] = t['whatsNew']
    out['promotionalText'] = t['promo']
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

    files = sorted(glob.glob(os.path.join(HERE, 'metadata_*.json')))
    missing, over, done = [], [], 0
    for path in files:
        locale = os.path.basename(path)[len('metadata_'):-len('.json')]
        data = json.load(io.open(path, encoding='utf-8'),
                         object_pairs_hook=collections.OrderedDict)
        if len(data['description'].split('\n\n')) == BLOCKS + 1:
            print(f"{locale:8} already rewritten "
                  f"({len(data['description'])} chars)")
            done += 1
            continue
        new = rewrite(locale, data)
        if new is None:
            missing.append(locale)
            continue
        for field, cap in CAPS.items():
            if len(new.get(field, '')) > cap:
                over.append(f"{locale} {field} {len(new[field])}/{cap}")
        print(f"{locale:8} description {len(data['description'])} -> "
              f"{len(new['description'])}")
        if args.write and not over:
            io.open(path, 'w', encoding='utf-8', newline='\n').write(
                json.dumps(new, ensure_ascii=False, indent=2) + '\n')
            done += 1

    if missing:
        print(f"\nno translation yet for {len(missing)}: "
              f"{', '.join(missing)}")
    if over:
        print("\nover Apple's cap — nothing written for these:")
        print("  " + "\n  ".join(over))
    print(f"\n{done} of {len(files)} rewritten")
    return 1 if over else 0


if __name__ == "__main__":
    sys.exit(main())
