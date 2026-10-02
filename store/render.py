"""Render the advert beats, frame by frame, for compose.py.

    python store/render.py --locale fr-FR
    python store/render.py --locale ja --beat advert-make-guide

Writes PNG frames to `store/render/<locale>/<beat>/` and a `manifest.json`,
by running `test/advert_render_test.dart` — the real app, on the test's fake
clock, every frame drawn on demand. See that file for why the beats are no
longer recorded in a simulator.

## Fonts

The render looks like the phone only with the phone's fonts, and the test
engine has none: no system font, no fallback. So this script finds them on
the machine and hands them over:

- macOS (CI): Apple's own system fonts, found by family name, never copied
  into the repository. Faces are pulled out of .ttc collections and variable
  fonts are cut into static weights (Flutter's FontLoader takes one face, and
  maps no weight onto a variable font's axis), in a temp directory.
- Windows: stand-ins, for checking choreography and layout locally. They are
  not the phone's fonts and a frame rendered with them is not for publishing.

Fallback follows iOS, as observed in the simulator footage of 2 October 2026:
text set in Georgia falls back to Hiragino Mincho in Japanese and to the sans
script font everywhere else; all other text falls back to the sans script font.

After rendering, every character drawn is checked against the font files of
its chain (fontTools cmap). A character none of them has would have been drawn
as a box, so that is an exit, not a warning.
"""

import argparse
import glob
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
# Override with WREN_RENDER_DIR on a machine where the checkout is synced (the
# OneDrive copy locks the folder and would upload every frame).
OUT = pathlib.Path(os.environ.get("WREN_RENDER_DIR") or (HERE / "render"))
TEST = "test/advert_render_test.dart"

DEFAULT_BEATS = [
    "advert-intro",
    "advert-add",
    "advert-which-city",
    "advert-the-list",
    "advert-make-guide",
]

WEIGHTS = (400, 500, 600, 700)

# Family name candidates, in order, per role and platform. Matched against the
# fonts' own name tables, not file names, which differ between macOS releases.
FAMILIES = {
    "darwin": {
        "Georgia": ["Georgia"],
        "system": ["SF Pro", "System Font", ".SF NS"],
        "sans": {
            "ja": ["Hiragino Sans"],
            "zh-Hant": ["PingFang TC"],
            "ko": ["Apple SD Gothic Neo"],
            "ar": ["SF Arabic", "Geeza Pro"],
        },
        "serif": {"ja": ["Hiragino Mincho ProN"]},
    },
    "win32": {
        "Georgia": ["Georgia"],
        "system": ["Segoe UI"],
        "sans": {
            "ja": ["Yu Gothic"],
            "zh-Hant": ["Microsoft JhengHei"],
            "ko": ["Malgun Gothic"],
            "ar": ["Segoe UI", "Noto Sans Arabic"],
        },
        "serif": {"ja": ["Yu Mincho", "MS Mincho"]},
    },
}

FONT_DIRS = {
    # FontServices: recent macOS keeps some system UI fonts (PingFang among
    # them, by the name its compose.py candidate path suggested) out of
    # /System/Library/Fonts.
    "darwin": ["/System/Library/Fonts", "/Library/Fonts",
               "/System/Library/AssetsV2",
               "/System/Library/PrivateFrameworks/FontServices.framework"],
    "win32": [os.path.expandvars(r"%WINDIR%\Fonts"),
              os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\Windows\Fonts")],
}


def say(msg):
    print(msg, flush=True)


def script_of(locale):
    """The fallback key for a locale: its language, or zh-Hant as a whole."""
    if locale.startswith("zh"):
        return "zh-Hant"
    return locale.split("-")[0]


# --- finding fonts -----------------------------------------------------------

def _names(font):
    """(family, subfamily) as the font names itself, typographic names first."""
    name = font["name"]
    fam = name.getDebugName(16) or name.getDebugName(1) or ""
    sub = name.getDebugName(17) or name.getDebugName(2) or ""
    return fam, sub


def font_index(platform):
    """[(family, subfamily, path, face_index)] for every face on the machine."""
    from fontTools.ttLib import TTCollection, TTFont
    faces = []
    for d in FONT_DIRS[platform]:
        if not os.path.isdir(d):
            continue
        for path in glob.glob(os.path.join(d, "**", "*.*"), recursive=True):
            ext = path.lower().rsplit(".", 1)[-1]
            if ext not in ("ttf", "otf", "ttc"):
                continue
            try:
                if ext == "ttc":
                    fonts = TTCollection(path, lazy=True).fonts
                else:
                    fonts = [TTFont(path, lazy=True)]
                for i, f in enumerate(fonts):
                    fam, sub = _names(f)
                    faces.append((fam, sub, path, i))
            except Exception:
                continue
    return faces


def _norm(family):
    # Apple names its hidden system faces with a leading dot (".SF NS").
    return family.lstrip(".").strip().lower()


def find_faces(faces, candidates):
    """Every face of the first candidate family present, or []."""
    for want in candidates:
        hits = [f for f in faces if _norm(f[0]) == _norm(want)]
        if hits:
            return hits
    return []


def near_misses(faces, candidates):
    """Installed families sharing a word with any candidate, for the error."""
    words = {w for c in candidates for w in _norm(c).split() if len(w) > 2}
    return sorted({"%s  (%s)" % (f[0], f[2]) for f in faces
                   if words & set(_norm(f[0]).split())})


def prepare(face, tmp):
    """Write one face as a standalone font file Flutter can load.

    Returns a list of paths: one for a static face, one per weight in WEIGHTS
    for a variable face (static instances, so a weight asked for is drawn).
    """
    from fontTools.ttLib import TTCollection, TTFont
    fam, sub, path, index = face
    if path.lower().endswith(".ttc"):
        font = TTCollection(path).fonts[index]
    else:
        font = TTFont(path)
    stem = "%s-%s-%d" % (
        "".join(c for c in fam if c.isalnum()),
        "".join(c for c in sub if c.isalnum()) or "face", index)
    if "fvar" not in font:
        out = os.path.join(tmp, stem + ".ttf")
        font.save(out)
        return [out]
    from fontTools.varLib import instancer
    axes = {a.axisTag: (a.minValue, a.maxValue) for a in font["fvar"].axes}
    outs = []
    for w in WEIGHTS:
        loc = {}
        if "wght" in axes:
            lo, hi = axes["wght"]
            loc["wght"] = max(lo, min(hi, w))
        # Pin every other axis at its default.
        src = TTFont(path) if not path.lower().endswith(".ttc") \
            else TTCollection(path).fonts[index]
        inst = instancer.instantiateVariableFont(src, loc, inplace=False)
        out = os.path.join(tmp, "%s-w%d.ttf" % (stem, w))
        inst.save(out)
        outs.append(out)
    return outs


def faces_for(faces, candidates, tmp, role):
    found = find_faces(faces, candidates)
    if not found:
        near = near_misses(faces, candidates)
        sys.exit("no font for %s: none of %s is installed.\n"
                 "  Installed families sharing a word:\n    %s"
                 % (role, candidates, "\n    ".join(near) or "(none)"))
    say("  %-22s %s (%d face%s)" % (role, found[0][0], len(found),
                                    "" if len(found) == 1 else "s"))
    paths = []
    for f in found:
        # Italics are never asked for by the app and only add ambiguity.
        if "italic" in f[1].lower() or "oblique" in f[1].lower():
            continue
        paths += prepare(f, tmp)
    return paths


def build_config(locale, tmp):
    platform = sys.platform if sys.platform in FAMILIES else None
    if platform is None:
        sys.exit("rendering needs macOS (real fonts) or Windows (stand-ins)")
    spec = FAMILIES[platform]
    if platform != "darwin":
        say("  NOTE: stand-in fonts — fine for checking a beat, not for "
            "publishing one")
    faces = font_index(platform)
    families = {}
    families["Georgia"] = faces_for(faces, spec["Georgia"], tmp, "Georgia")
    system = faces_for(faces, spec["system"], tmp, "system sans")
    families["CupertinoSystemText"] = system
    families["CupertinoSystemDisplay"] = system

    flutter = shutil.which("flutter")
    if not flutter:
        sys.exit("flutter is not on PATH")
    sdk = pathlib.Path(flutter).resolve().parent.parent
    icons = list((sdk / "bin" / "cache" / "artifacts" / "material_fonts")
                 .glob("[Mm]aterial[Ii]cons-[Rr]egular.otf"))
    if not icons:
        sys.exit("MaterialIcons not found under %s" % sdk)
    families["MaterialIcons"] = [str(icons[0])]

    script = script_of(locale)
    sans_fallback, serif_fallback = [], []
    if script in spec["sans"]:
        families["WrenScriptSans"] = faces_for(
            faces, spec["sans"][script], tmp, "%s sans fallback" % script)
        sans_fallback = ["WrenScriptSans"]
    if script in spec["serif"]:
        if platform != "darwin" and not find_faces(faces, spec["serif"][script]):
            # A stand-in machine without the serif: Georgia's chain then runs
            # straight on to the sans fallback. Never on macOS, where a missing
            # font is an exit like any other.
            say("  NOTE: no %s serif stand-in here; Georgia falls back to sans"
                % script)
        else:
            families["WrenScriptSerif"] = faces_for(
                faces, spec["serif"][script], tmp, "%s serif fallback" % script)
            serif_fallback = ["WrenScriptSerif"]
    return {"families": families, "serifFallback": serif_fallback,
            "sansFallback": sans_fallback}


# --- after the render --------------------------------------------------------

def check_glyphs(manifest, config):
    """Exit if any character drawn is in none of its chain's font files."""
    from fontTools.ttLib import TTFont
    cmaps = {}

    def covers(family):
        if family not in cmaps:
            cps = set()
            for p in config["families"].get(family, []):
                try:
                    cps |= set(TTFont(p, lazy=True).getBestCmap() or {})
                except Exception:
                    pass
            cmaps[family] = cps
        return cmaps[family]

    problems = []
    for chain, chars in manifest.get("glyphs", {}).items():
        families = chain.split(">")
        for ch in chars:
            if ch.isspace() or ord(ch) < 0x20:
                continue
            if not any(ord(ch) in covers(f) for f in families):
                problems.append("U+%04X %r in %s" % (ord(ch), ch, chain))
    if problems:
        sys.exit("characters no loaded font can draw (they would be boxes):\n  "
                 + "\n  ".join(problems[:40]))
    say("  every character drawn is in one of its fonts (%d chains)"
        % len(manifest.get("glyphs", {})))


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--locale", default="en-GB")
    p.add_argument("--beat", action="append",
                   help="one beat; repeatable (default: every advert beat)")
    args = p.parse_args()
    beats = args.beat or DEFAULT_BEATS

    out = OUT / args.locale
    out.mkdir(parents=True, exist_ok=True)
    say("rendering %s: %s" % (args.locale, ", ".join(beats)))
    # ignore_cleanup_errors: on Windows fontTools can still hold a file open.
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
        config = build_config(args.locale, tmp)
        cfg_path = os.path.join(tmp, "fonts.json")
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=1)
        env = dict(os.environ,
                   WREN_RENDER_OUT=str(out),
                   WREN_RENDER_LOCALE=args.locale,
                   WREN_RENDER_BEATS=",".join(beats),
                   WREN_RENDER_FONTS=cfg_path)
        cmd = [shutil.which("flutter"), "test", "--no-pub", TEST,
               "--reporter", "expanded"]
        r = subprocess.run(cmd, cwd=ROOT, env=env)
        if r.returncode != 0:
            sys.exit("the render failed (flutter test exited %d)" % r.returncode)
        manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
        check_glyphs(manifest, config)
    for b in manifest["beats"]:
        say("  %-18s %4d frames  %.2fs" % (b["name"], b["frames"], b["seconds"]))
    say("done: %s" % out)


if __name__ == "__main__":
    main()
