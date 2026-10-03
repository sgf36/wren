"""Render the advert beats, frame by frame, for compose.py.

    python store/render.py --locale fr-FR
    python store/render.py --locale ja --beat advert-make-guide
    python store/render.py --platform android --locale de-DE

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

## Android

`--platform android` renders the Android edition's beats (DEFAULT_BEATS_ANDROID)
into `render/android/<locale>/`. Its fonts are Android's own, and unlike
Apple's they are open-licence, so they are downloaded from google/fonts on any
machine -- a Windows render is the real look, not a stand-in. The cascade is
Android's fonts.xml: text with no family is Roboto; "Georgia" is an alias of
`serif`, which is Noto Serif (the Play screenshots show exactly that); and each
script falls back to its Noto face, serif under serif and sans under sans.
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

# Same story, and the same intro; the last beat is the hand-off sheet, because
# Android has no Apple Maps guide to make.
DEFAULT_BEATS_ANDROID = [
    "advert-intro",
    "advert-android-add",
    "advert-android-which-city",
    "advert-android-the-list",
    "advert-android-send",
]


def render_dir(platform, locale):
    """Where a locale's frames go. Android has its own tree so the two
    editions never overwrite each other's frames."""
    return OUT / "android" / locale if platform == "android" else OUT / locale

WEIGHTS = (400, 500, 600, 700)

# Family name candidates, in order, per role and platform. Matched against the
# fonts' own name tables, not file names, which differ between macOS releases.
FAMILIES = {
    "darwin": {
        "Georgia": ["Georgia"],
        "system": ["SF Pro", "System Font", ".SF NS"],
        "sans": {
            "ja": ["Hiragino Sans"],
            # iOS uses PingFang TC; the runner's copy draws nothing (see
            # SAMPLES), and Heiti TC is Apple's previous Traditional
            # Chinese sans.
            "zh-Hant": ["PingFang TC", "Heiti TC"],
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


# Android's fonts, from github.com/google/fonts (OFL), per role and script.
# Variable fonts; prepare() cuts static weights from them.
_GF = "https://raw.githubusercontent.com/google/fonts/main/ofl/"
ANDROID_FONTS = {
    "system": _GF + "roboto/Roboto%5Bwdth,wght%5D.ttf",
    "Georgia": _GF + "notoserif/NotoSerif%5Bwdth,wght%5D.ttf",
    "sans": {
        "ja": _GF + "notosansjp/NotoSansJP%5Bwght%5D.ttf",
        "zh-Hant": _GF + "notosanstc/NotoSansTC%5Bwght%5D.ttf",
        "ko": _GF + "notosanskr/NotoSansKR%5Bwght%5D.ttf",
        # Android's Arabic is Naskh, for sans and serif alike.
        "ar": _GF + "notonaskharabic/NotoNaskhArabic%5Bwght%5D.ttf",
    },
    "serif": {
        "ja": _GF + "notoserifjp/NotoSerifJP%5Bwght%5D.ttf",
        "zh-Hant": _GF + "notoseriftc/NotoSerifTC%5Bwght%5D.ttf",
        "ko": _GF + "notoserifkr/NotoSerifKR%5Bwght%5D.ttf",
        "ar": _GF + "notonaskharabic/NotoNaskhArabic%5Bwght%5D.ttf",
    },
    # Last in every chain, as on the phone: Roboto has no arrows, and the
    # Google Maps row reads "You → Maps".
    "symbols": _GF + "notosanssymbols/NotoSansSymbols%5Bwght%5D.ttf",
}
FONT_CACHE = pathlib.Path(os.environ.get("WREN_FONT_CACHE")
                          or pathlib.Path.home() / ".cache" / "wren-fonts")

# The first four bytes of a TrueType or OpenType file.
_FONT_MAGIC = (b"\x00\x01\x00\x00", b"OTTO", b"true")


def say(msg):
    print(msg, flush=True)


def fetch(url):
    """A downloaded font file, cached by name. Refuses anything that is not a
    font, so an HTML error page is never handed to Flutter as one."""
    import urllib.parse
    import urllib.request
    FONT_CACHE.mkdir(parents=True, exist_ok=True)
    name = urllib.parse.unquote(url.rsplit("/", 1)[-1])
    path = FONT_CACHE / "".join(c for c in name if c.isalnum() or c in ".-_")
    if not path.exists() or path.stat().st_size == 0:
        say("  downloading %s" % name)
        req = urllib.request.Request(url,
                                     headers={"User-Agent": "wren-render/1.0"})
        with urllib.request.urlopen(req, timeout=120) as r:
            data = r.read()
        if data[:4] not in _FONT_MAGIC:
            sys.exit("%s is not a font file (%d bytes)" % (url, len(data)))
        path.write_bytes(data)
    return str(path)


def android_faces(url, tmp, role, sample="Wren"):
    """Static weights of one downloaded font, proven to draw `sample`."""
    from fontTools.ttLib import TTFont
    path = fetch(url)
    fam, sub = _names(TTFont(path, lazy=True))
    paths = prepare((fam, sub, path, 0), tmp)
    if not any(draws(p, sample) for p in paths):
        sys.exit("%s (%s) draws no glyph for %r" % (role, fam, sample))
    say("  %-22s %s" % (role, fam))
    return paths


def build_config_android(locale, tmp):
    """Android's cascade. See the module docstring."""
    families = {}
    families["Roboto"] = android_faces(ANDROID_FONTS["system"], tmp,
                                       "system sans")
    families["Georgia"] = android_faces(ANDROID_FONTS["Georgia"], tmp,
                                        "Georgia (serif alias)")
    families["MaterialIcons"] = [material_icons()]
    script = script_of(locale)
    sans_fallback, serif_fallback = [], []
    sample = SAMPLES.get(script, "Wren")
    if script in ANDROID_FONTS["sans"]:
        families["WrenScriptSans"] = android_faces(
            ANDROID_FONTS["sans"][script], tmp,
            "%s sans fallback" % script, sample)
        sans_fallback = ["WrenScriptSans"]
    if script in ANDROID_FONTS["serif"]:
        families["WrenScriptSerif"] = android_faces(
            ANDROID_FONTS["serif"][script], tmp,
            "%s serif fallback" % script, sample)
        serif_fallback = ["WrenScriptSerif"]
    families["WrenSymbols"] = android_faces(ANDROID_FONTS["symbols"], tmp,
                                            "symbols fallback", "→")
    sans_fallback.append("WrenSymbols")
    return {"families": families, "serifFallback": serif_fallback,
            "sansFallback": sans_fallback, "systemFamily": "Roboto"}


def material_icons():
    flutter = shutil.which("flutter")
    if not flutter:
        sys.exit("flutter is not on PATH")
    sdk = pathlib.Path(flutter).resolve().parent.parent
    icons = list((sdk / "bin" / "cache" / "artifacts" / "material_fonts")
                 .glob("[Mm]aterial[Ii]cons-[Rr]egular.otf"))
    if not icons:
        sys.exit("MaterialIcons not found under %s" % sdk)
    return str(icons[0])


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


# Characters each fallback must actually draw. A font's cmap listing a glyph
# is not proof it renders: on the macos-26 runner PingFang TC lists every
# Chinese character and draws none of them (run 37033279280 rendered zh-Hant
# entirely as boxes and passed the cmap check), as Pillow found in run 34.
SAMPLES = {
    "ja": "場所をとっておく",
    "zh-Hant": "地方收著讀取",
    "ko": "장소를담아두다",
    "ar": "أماكن محفوظة",
}


def draws(path, sample):
    """Whether FreeType draws real glyphs for every character in `sample`.

    Real means ink, and ink that is not the font's own missing-glyph box: a
    face that cannot render a glyph either draws nothing or draws .notdef.
    """
    from PIL import Image, ImageDraw, ImageFont
    try:
        font = ImageFont.truetype(path, 48,
                                  layout_engine=ImageFont.Layout.BASIC)
    except Exception:
        return False

    def mask(ch):
        img = Image.new("L", (96, 96), 0)
        ImageDraw.Draw(img).text((12, 12), ch, fill=255, font=font)
        return img.tobytes() if img.getbbox() else None

    notdef = mask("\U0010FFFD")  # a private-use code point no font maps
    for ch in sample:
        if ch.isspace():
            continue
        m = mask(ch)
        if m is None or m == notdef:
            return False
    return True


def faces_for(faces, candidates, tmp, role, sample="Wren"):
    """Prepared font files for the first candidate that is installed AND draws.

    Each candidate is tried in turn; one whose glyphs exist only on paper is
    reported and skipped, never used.
    """
    tried = []
    for want in candidates:
        found = find_faces(faces, [want])
        if not found:
            tried.append("%s: not installed" % want)
            continue
        paths = []
        for f in found:
            # Italics are never asked for by the app and only add ambiguity.
            if "italic" in f[1].lower() or "oblique" in f[1].lower():
                continue
            paths += prepare(f, tmp)
        if not any(draws(p, sample) for p in paths):
            tried.append("%s: installed, but draws no glyph for %r"
                         % (found[0][0], sample))
            say("  %-22s %s draws nothing for %r - next candidate"
                % (role, found[0][0], sample))
            continue
        say("  %-22s %s (%d face%s)" % (role, found[0][0], len(found),
                                        "" if len(found) == 1 else "s"))
        return paths
    near = near_misses(faces, candidates)
    sys.exit("no usable font for %s:\n    %s\n"
             "  Installed families sharing a word:\n    %s"
             % (role, "\n    ".join(tried), "\n    ".join(near) or "(none)"))


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

    families["MaterialIcons"] = [material_icons()]

    script = script_of(locale)
    sans_fallback, serif_fallback = [], []
    if script in spec["sans"]:
        families["WrenScriptSans"] = faces_for(
            faces, spec["sans"][script], tmp, "%s sans fallback" % script,
            SAMPLES.get(script, "Wren"))
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
                faces, spec["serif"][script], tmp, "%s serif fallback" % script,
                SAMPLES.get(script, "Wren"))
            serif_fallback = ["WrenScriptSerif"]
    return {"families": families, "serifFallback": serif_fallback,
            "sansFallback": sans_fallback,
            "systemFamily": "CupertinoSystemText"}


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
    p.add_argument("--platform", choices=("ios", "android"), default="ios")
    p.add_argument("--beat", action="append",
                   help="one beat; repeatable (default: every advert beat)")
    args = p.parse_args()
    android = args.platform == "android"
    beats = args.beat or (DEFAULT_BEATS_ANDROID if android else DEFAULT_BEATS)

    out = render_dir(args.platform, args.locale)
    out.mkdir(parents=True, exist_ok=True)
    say("rendering %s for %s: %s"
        % (args.locale, args.platform, ", ".join(beats)))
    # ignore_cleanup_errors: on Windows fontTools can still hold a file open.
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
        config = (build_config_android(args.locale, tmp) if android
                  else build_config(args.locale, tmp))
        cfg_path = os.path.join(tmp, "fonts.json")
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=1)
        env = dict(os.environ,
                   WREN_RENDER_OUT=str(out),
                   WREN_RENDER_LOCALE=args.locale,
                   WREN_RENDER_BEATS=",".join(beats),
                   WREN_RENDER_FONTS=cfg_path,
                   WREN_RENDER_PLATFORM=args.platform)
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
