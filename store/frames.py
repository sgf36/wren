"""Render the captioned store images (store/frames.json) for one or more locales.

    python store/frames.py --locale en-GB
    python store/frames.py --locale en-GB --locale de-DE

Writes `<out>/<locale>/<slide id>.png` at 1290x2796, where <out> is
WREN_RENDER_DIR/frames or store/render/frames. Runs
test/store_frame_render_test.dart; see that file for how a slide is drawn and
why these exist.

Fonts are render.py's: Apple's own on macOS (publishable), stand-ins on
Windows (layout checks only). Every character drawn is then checked against
its fonts, as for the adverts. The price a caption quotes ({price}) is the
base unlock's, from shot_prices.json, which iap_prices.py reads out of App
Store Connect; a locale with no price there is an exit, never a guess.
"""
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
from render import build_config, check_glyphs, say  # noqa: E402

SPEC = HERE / "frames.json"
PRICES = HERE / "shot_prices.json"
OUT = pathlib.Path(os.environ.get("WREN_RENDER_DIR") or (HERE / "render")) / "frames"
TEST = "test/store_frame_render_test.dart"


def prices_for(locale):
    table = json.loads(PRICES.read_text(encoding="utf-8"))
    out = {pid: per[locale] for pid, per in table.items() if locale in per}
    if not out:
        sys.exit("shot_prices.json has no prices for %s: add it to "
                 "iap_prices.py SHOT_TERRITORIES and run --write" % locale)
    return out


def render(locale):
    spec = json.loads(SPEC.read_text(encoding="utf-8"))
    if locale not in spec["captions"]:
        sys.exit("frames.json has no captions for %s" % locale)
    out = OUT / locale
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    say("frames for %s -> %s" % (locale, out))
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
        config = build_config(locale, tmp)
        cfg = os.path.join(tmp, "fonts.json")
        pr = os.path.join(tmp, "prices.json")
        with open(cfg, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=1)
        with open(pr, "w", encoding="utf-8") as f:
            json.dump(prices_for(locale), f, ensure_ascii=False)
        env = dict(os.environ, WREN_FRAME_OUT=str(out), WREN_RENDER_LOCALE=locale,
                   WREN_RENDER_FONTS=cfg, WREN_FRAME_SPEC=str(SPEC),
                   WREN_FRAME_PRICES=pr, WREN_FRAME_ROOT=str(ROOT))
        r = subprocess.run([shutil.which("flutter"), "test", "--no-pub", TEST,
                            "--reporter", "expanded"], cwd=ROOT, env=env)
        if r.returncode != 0:
            sys.exit("the render failed (flutter test exited %d)" % r.returncode)
        glyphs = json.loads((out / "glyphs.json").read_text(encoding="utf-8"))
        check_glyphs({"glyphs": glyphs}, config)
    (out / "glyphs.json").unlink()
    made = sorted(p.name for p in out.glob("*.png"))
    want = sorted(s["id"] + ".png" for s in spec["slides"])
    if made != want:
        sys.exit("%s: expected %s, made %s" % (locale, want, made))
    say("  %d images" % len(made))


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--locale", action="append")
    args = p.parse_args()
    for locale in args.locale or ["en-GB"]:
        render(locale)


if __name__ == "__main__":
    main()
