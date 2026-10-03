"""Compose a ready-to-publish advert from rendered beats and text cards.

    python store/compose.py                          # en-GB, default beats
    python store/compose.py --locale fr-FR           # French
    python store/compose.py --beats advert-the-list advert-which-city
    python store/compose.py --platform android --locale de-DE

macOS only -- uses system Georgia font and FFmpeg. Run from the repo root
after store/render.py has rendered the beats.

Produces one 1080x1920 MP4 per locale under store/adverts/<locale>/, or
store/adverts/android/<locale>/ for the Android edition, whose cards say
"your map app" and "Google Play" (solution_android, cta_android) and whose
beats end on the hand-off sheet rather than an Apple Maps guide.

The three-act structure:
  1. Problem -- each line on its own text card, teal background, cream text
  2. The app in action -- beats rendered frame by frame by store/render.py
  3. End card -- app icon and call to action on deep teal

Everything is driven by advert_strings.json (localised captions). Add a
locale there and this produces the video for it.
"""

import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
ADVERTS = HERE / "adverts"
STRINGS = HERE / "advert_strings.json"
APP_ICON = ROOT / "assets" / "icon" / "app_icon.png"

TEAL = (30, 75, 69)
DEEP_TEAL = (18, 51, 47)
GOLD = (242, 200, 121)
CREAM = (244, 239, 228)

W, H = 1080, 1920
FPS = 30
FADE = 10

FONT = "/System/Library/Fonts/Supplemental/Georgia.ttf"


def _truetype(path, size, index=0):
    """Every font in this file, loaded with the BASIC layout engine.

    Arabic is shaped and put into visual order here, by arabic_reshaper and
    python-bidi, before Pillow sees it. That is right only for BASIC, which maps
    characters straight to glyphs. Pillow's macOS wheels switch to raqm whenever
    they can dlopen a FriBiDi — and `brew install ffmpeg` can bring one — and
    raqm runs the bidi algorithm again, reversing every Arabic line a second
    time. Which engine you get would then depend on the runner image. Pinning it
    makes the output depend on nothing.
    """
    from PIL import ImageFont
    return ImageFont.truetype(path, size, index=index,
                              layout_engine=ImageFont.Layout.BASIC)

# iPhone Pro/Pro Max safe area at 3x, cropped from beat clips before scaling.
# Removes the "9:41 Carrier" status bar and the home indicator bar.
_SAFE_TOP = 177    # Dynamic Island + status bar (59pt)
_SAFE_BOTTOM = 102  # home indicator (34pt)

# Instagram Reels/Stories overlay a CTA button in the bottom ~250px. Scale the
# beat clips to fit above it so the app's own buttons are not covered.
_IG_CTA_RESERVE = 250

_CJK_CANDIDATES = [
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
    "/System/Library/Fonts/STSongti-SC-Regular.otf",
    "/System/Library/Fonts/Supplemental/Hiragino Mincho ProN W3.otf",
]
_JA_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Hiragino Mincho ProN W3.otf",
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
]
_KO_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/AppleMyungjo.ttf",
    "/System/Library/Fonts/AppleSDGothicNeo.ttc",
]
_AR_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Geeza Pro.ttf",
    "/System/Library/Fonts/GeezaPro.ttc",
]

_font_cache = {}
_latin_fallback = {}
_cmaps = {}


def _cmap(path, index=0):
    """The set of code points the font at *path* (face *index*) has glyphs for.

    Read from the font's own cmap table. The test this replaced drew each
    character and asked whether any pixel was set — but a missing character
    draws the font's .notdef box, which has pixels, so it reported Noto Sans
    Arabic as covering "A" and the Latin fallback never switched on.
    """
    key = (str(path), index)
    if key not in _cmaps:
        from fontTools.ttLib import TTFont
        try:
            font = TTFont(str(path), fontNumber=index, lazy=True)
            _cmaps[key] = set(font.getBestCmap() or {})
        except Exception:
            _cmaps[key] = set()
    return _cmaps[key]


def _faces(path):
    """How many faces the font file holds (a .ttc holds several)."""
    if not str(path).lower().endswith(".ttc"):
        return 1
    from fontTools.ttLib import TTCollection
    try:
        return len(TTCollection(str(path), lazy=True).fonts)
    except Exception:
        return 0


def _missing(chars, path, index=0):
    cmap = _cmap(path, index)
    return sorted({c for c in chars if not c.isspace() and ord(c) not in cmap})


def _draws(path, index, chars):
    """Whether FreeType draws ink for a sample of *chars* from this face.

    The cmap says a glyph exists; this says FreeType can render it. On the CI
    runner PingFang.ttc has the cmap and draws nothing, which is why
    2de28ed stopped trusting it — a cmap test alone would pick it again.
    """
    from PIL import Image, ImageDraw
    # Native script first: a face can draw Latin and nothing else.
    ink = [c for c in sorted(chars) if not c.isspace() and c.isalnum()]
    sample = ([c for c in ink if not c.isascii()] + ink)[:3]
    try:
        f = _truetype(path, 40, index=index)
    except Exception:
        return False
    for ch in sample:
        img = Image.new("L", (80, 80), 0)
        ImageDraw.Draw(img).text((10, 10), ch, fill=255, font=f)
        if not img.getbbox():
            return False
    return True


def _usable(chars, path, index):
    return not _missing(chars, path, index) and _draws(path, index, chars)


def _is_latin_letter(ch):
    return ch.isascii() and ch.isalpha()


def _font_for_locale(locale, texts):
    """(font_path, face_index) that can draw every character in *texts*.

    *texts* is everything the cards will draw, after Arabic shaping, so the
    test is on the glyphs actually requested. The first candidate (and, in a
    .ttc, the first face) covering all of it wins. For Arabic only, a font
    covering everything but the Latin letters is used with Georgia for those —
    GeezaPro has no A-Z, and the cards carry "Wren", "Apple Maps" and "App
    Store". Nothing covering it is an exit, not a card of tofu.

    Sets ``_latin_fallback[locale]`` to ``(FONT, 0)`` or None.
    """
    if locale in _font_cache:
        return _font_cache[locale]
    lang = locale.split("-")[0]
    candidates = {"ja": _JA_CANDIDATES, "zh": _CJK_CANDIDATES,
                  "ko": _KO_CANDIDATES, "ar": _AR_CANDIDATES}.get(lang, [])
    chars = set("".join(texts))
    native = {c for c in chars if not _is_latin_letter(c)}
    latin = chars - native

    def pick(path, index, fallback, note=""):
        say("  font for %s: %s (face %d)%s" % (locale, path, index, note))
        _font_cache[locale] = (path, index)
        _latin_fallback[locale] = fallback
        return (path, index)

    present = [p for p in candidates if pathlib.Path(p).exists()]
    for path in present:
        for index in range(_faces(path)):
            if _usable(chars, path, index):
                return pick(path, index, None)
    if lang == "ar" and not _missing(latin, FONT):
        for path in present:
            for index in range(_faces(path)):
                if _usable(native, path, index):
                    return pick(path, index, (FONT, 0), " + Georgia for Latin")
    if not _missing(chars, FONT):
        return pick(FONT, 0, None)
    sys.exit("no font can draw every character for %s; missing from %s: %s"
             % (locale, FONT, " ".join("U+%04X" % ord(c)
                                       for c in _missing(chars, FONT))))


def _check_glyphs(font, text):
    """Exit rather than draw a character *font* has no glyph for.

    Pillow has no font fallback (python-pillow/Pillow#4808, still open) and
    draws .notdef — a box — for a missing glyph, without a warning. That is how
    ar-SA shipped "Wren" as four boxes. Every draw goes through here.
    """
    gone = _missing(text, font.path, getattr(font, "index", 0))
    if gone:
        sys.exit("%s has no glyph for %s in %r"
                 % (pathlib.Path(font.path).name,
                    " ".join("U+%04X" % ord(c) for c in gone), text))

from render import (DEFAULT_BEATS, DEFAULT_BEATS_ANDROID,  # noqa: E402
                    render_dir)

PROBLEM_HOLD = 2.5
SOLUTION_HOLD = 4.5
END_CARD_HOLD = 3.0

def say(msg):
    print(msg, flush=True)


def load_strings(locale, platform="ios"):
    if not STRINGS.exists():
        sys.exit("no strings file at %s" % STRINGS)
    data = json.loads(STRINGS.read_text(encoding="utf-8"))
    # Never falls back to the iOS copy: an Android advert that said "Apple
    # Maps" or "App Store" would be wrong in a way no check below would catch.
    suffix = "_android" if platform == "android" else ""
    problem = data.get("problem", {}).get(locale)
    solution = data.get("solution" + suffix, {}).get(locale)
    cta = data.get("cta" + suffix, {}).get(locale)
    missing = [k for k, v in [("problem", problem), ("solution", solution),
                               ("cta", cta)] if not v]
    if missing:
        sys.exit("missing strings for %s: %s" % (locale, ", ".join(missing)))
    return problem, solution, cta


def _hex(rgb):
    return "0x%02x%02x%02x" % rgb


def _has_arabic(text):
    return any(0x0600 <= ord(c) <= 0x06FF or 0x0750 <= ord(c) <= 0x077F
               or 0xFB50 <= ord(c) <= 0xFDFF or 0xFE70 <= ord(c) <= 0xFEFE
               for c in text)


def _reshape_bidi(text):
    """Arabic shaped and in visual order, for the BASIC layout engine.

    No silent fallback: without these, Arabic would be drawn as isolated
    letters in the wrong direction and nothing would say so.
    """
    try:
        import arabic_reshaper
        from bidi.algorithm import get_display
    except ImportError:
        sys.exit("Arabic text needs arabic-reshaper and python-bidi: "
                 "pip install arabic-reshaper python-bidi")
    reshaped = arabic_reshaper.reshape(text)
    return get_display(reshaped)


def _is_arabic_cp(ch):
    """True when *ch* is in an Arabic Unicode block."""
    cp = ord(ch)
    return (0x0600 <= cp <= 0x06FF or 0x0750 <= cp <= 0x077F
            or 0xFB50 <= cp <= 0xFDFF or 0xFE70 <= cp <= 0xFEFE)


def _split_runs(text):
    """Split *text* into ``(substring, is_arabic)`` runs for dual-font rendering.

    Neutral characters (whitespace, punctuation, digits) attach to the
    preceding run so inter-word spaces stay with their script.
    """
    if not text:
        return []
    runs = []
    buf = []
    cur = None
    for ch in text:
        if _is_arabic_cp(ch):
            script = True
        elif ch.isascii() and ch.isalpha():
            script = False
        else:
            script = cur
        if script is not None and script != cur and cur is not None:
            runs.append(("".join(buf), cur))
            buf = []
        buf.append(ch)
        if script is not None:
            cur = script
    if buf:
        runs.append(("".join(buf), cur if cur is not None else False))
    return runs


def _measure_line(text, font, fallback_font=None):
    """Return ``(width, height)`` of *text*, splitting across fonts when needed."""
    if fallback_font is None:
        bbox = font.getbbox(text)
        return (bbox[2] - bbox[0], bbox[3] - bbox[1])
    w = 0
    h = 0
    for run_text, is_ar in _split_runs(text):
        f = font if is_ar else fallback_font
        # Advance width, not ink: a run ending in a space has no ink there,
        # and measuring by ink closes the gap between the two scripts.
        w += f.getlength(run_text)
        bbox = f.getbbox(run_text)
        h = max(h, bbox[3] - bbox[1])
    return (int(round(w)), h)


def _draw_line(draw, xy, text, fill, font, fallback_font=None):
    """Draw *text*, switching between *font* and *fallback_font* per script run.

    Both runs sit on one baseline (anchor "ls"): Georgia's ascender is not
    GeezaPro's, and anchoring each run at its own top would set "App Store" a
    few pixels off the Arabic beside it.
    """
    if fallback_font is None:
        _check_glyphs(font, text)
        draw.text(xy, text, fill=fill, font=font)
        return
    x, y = xy
    baseline = y + max(font.getmetrics()[0], fallback_font.getmetrics()[0])
    for run_text, is_ar in _split_runs(text):
        f = font if is_ar else fallback_font
        _check_glyphs(f, run_text)
        draw.text((x, baseline), run_text, fill=fill, font=f, anchor="ls")
        x += f.getlength(run_text)


def _load_icon(size):
    from PIL import Image
    if not APP_ICON.exists():
        return None
    icon = Image.open(APP_ICON).convert("RGBA")
    return icon.resize((size, size), Image.LANCZOS)


def _render(lines, bg, fg, font_size, out_path, line_spacing=1.7, y_shift=-60,
            font_path=None, font_index=0, latin_fallback=None):
    from PIL import Image, ImageDraw

    if isinstance(lines, str):
        lines = lines.split("\n")

    if any(_has_arabic(ln) for ln in lines):
        lines = [_reshape_bidi(ln) for ln in lines]

    img = Image.new("RGB", (W, H), bg)
    draw = ImageDraw.Draw(img)
    font = _truetype(font_path or FONT, font_size, index=font_index)
    fb = None
    if latin_fallback:
        fb = _truetype(latin_fallback[0], font_size,
                                index=latin_fallback[1])

    rendered = []
    for ln in lines:
        w, h = _measure_line(ln, font, fb)
        rendered.append((ln, w, h))

    gap = int(font_size * (line_spacing - 1))
    total_h = sum(r[2] for r in rendered) + gap * max(len(rendered) - 1, 0)

    y = (H - total_h) // 2 + y_shift
    for text, w, h in rendered:
        x = (W - w) // 2
        _draw_line(draw, (x, y), text, fg, font, fb)
        y += h + gap

    img.save(out_path, "PNG")


def _render_solution_card(lines, out_path, font_path=None, font_index=0,
                          latin_fallback=None):
    """Solution card: full-size Wren logo (icon + name) above the copy."""
    from PIL import Image, ImageDraw

    if isinstance(lines, str):
        lines = lines.split("\n")

    clean = list(lines)
    if clean and clean[0].startswith("Wren"):
        rest = clean[0][len("Wren"):].lstrip()
        if rest and rest[0].isascii() and rest[0].islower():
            rest = rest[0].upper() + rest[1:]
        if rest:
            clean[0] = rest
        else:
            clean.pop(0)

    if any(_has_arabic(ln) for ln in clean):
        clean = [_reshape_bidi(ln) for ln in clean]

    img = Image.new("RGB", (W, H), TEAL)
    draw = ImageDraw.Draw(img)

    icon_size = 160
    icon_img = _load_icon(icon_size)
    logo_font = _truetype(font_path or FONT, 60, index=font_index)
    wren_font = logo_font
    if latin_fallback:
        wren_font = _truetype(latin_fallback[0], 60,
                                       index=latin_fallback[1])
    wren_bbox = wren_font.getbbox("Wren")
    wren_w = wren_bbox[2] - wren_bbox[0]
    wren_h = wren_bbox[3] - wren_bbox[1]

    icon_text_gap = 20
    logo_body_gap = 50

    logo_h = icon_size + icon_text_gap + wren_h

    text_font = _truetype(font_path or FONT, 46, index=font_index)
    fb = None
    if latin_fallback:
        fb = _truetype(latin_fallback[0], 46,
                                index=latin_fallback[1])
    metrics = []
    for ln in clean:
        metrics.append(_measure_line(ln, text_font, fb))

    line_gap = 28
    text_h = sum(m[1] for m in metrics) + line_gap * max(len(clean) - 1, 0)

    total = logo_h + logo_body_gap + text_h
    y = (H - total) // 2 - 30

    if icon_img:
        img.paste(icon_img, ((W - icon_size) // 2, y), icon_img)
    y += icon_size + icon_text_gap

    _check_glyphs(wren_font, "Wren")
    draw.text(((W - wren_w) // 2, y), "Wren", fill=GOLD, font=wren_font)
    y += wren_h + logo_body_gap

    for i, ln in enumerate(clean):
        tw, th = metrics[i]
        _draw_line(draw, ((W - tw) // 2, y), ln, GOLD, text_font, fb)
        y += th + line_gap

    img.save(out_path, "PNG")


def _render_end_card(cta_text, out_path, font_path=None, font_index=0,
                     latin_fallback=None):
    from PIL import Image, ImageDraw

    img = Image.new("RGB", (W, H), DEEP_TEAL)
    draw = ImageDraw.Draw(img)

    if APP_ICON.exists():
        icon = Image.open(APP_ICON).convert("RGBA")
        icon = icon.resize((200, 200), Image.LANCZOS)
        img.paste(icon, ((W - 200) // 2, H // 2 - 200 - 30), icon)

    font = _truetype(font_path or FONT, 46, index=font_index)
    fb = None
    if latin_fallback:
        fb = _truetype(latin_fallback[0], 46,
                                index=latin_fallback[1])
    lines = cta_text.split("\n") if isinstance(cta_text, str) else cta_text
    if any(_has_arabic(ln) for ln in lines):
        lines = [_reshape_bidi(ln) for ln in lines]
    lines = [ln for ln in lines
             if ln.strip().rstrip(".").rstrip("。") != "Wren"]
    y = H // 2 + 30
    for line in lines:
        tw, th = _measure_line(line, font, fb)
        _draw_line(draw, ((W - tw) // 2, y), line, CREAM, font, fb)
        y += th + 24

    img.save(out_path, "PNG")


def _encode(src, dst, duration=None, vf_extra="", is_image=False,
            sequence=False):
    """Encode any source to a standardised 1080x1920 h264 segment.

    `sequence` reads `src` as a rendered beat: a directory of numbered PNGs,
    one per frame at FPS. Every frame is used, in order, as drawn — there is
    nothing to find or trim, which is the point of rendering rather than
    recording.
    """
    if is_image:
        vf = ("scale=%d:%d:force_original_aspect_ratio=increase,"
              "crop=%d:%d,fps=%d" % (W, H, W, H, FPS))
    else:
        vf = ("crop=iw:ih-%d:0:%d,"
              "scale=%d:%d:force_original_aspect_ratio=decrease:force_divisible_by=2,"
              "pad=%d:%d:(ow-iw)/2:0:color=%s,"
              "fps=%d" % (
                  _SAFE_TOP + _SAFE_BOTTOM, _SAFE_TOP,
                  W, H - _IG_CTA_RESERVE, W, H, _hex(TEAL), FPS))
    if vf_extra:
        vf += "," + vf_extra

    cmd = ["ffmpeg", "-y"]
    if is_image:
        cmd += ["-loop", "1", "-i", str(src)]
    elif sequence:
        cmd += ["-framerate", str(FPS), "-i", str(pathlib.Path(src) / "%05d.png")]
    else:
        cmd += ["-i", str(src)]
    if duration is not None:
        cmd += ["-t", str(duration)]
    cmd += ["-vf", vf,
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-profile:v", "high", "-level", "4.0",
            "-preset", "medium", "-crf", "18",
            "-an", str(dst)]

    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("ffmpeg failed on %s:\n%s" % (src.name, r.stderr[-600:]))


def _concat(segments, dst, tmp_dir):
    lst = pathlib.Path(tmp_dir) / "concat.txt"
    with lst.open("w") as f:
        for s in segments:
            f.write("file '%s'\n" % s)
    r = subprocess.run(
        ["ffmpeg", "-y", "-f", "concat", "-safe", "0",
         "-i", str(lst), "-c", "copy", str(dst)],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("concat failed:\n%s" % r.stderr[-600:])


def _duration(path):
    r = subprocess.run(
        ["ffprobe", "-v", "error",
         "-select_streams", "v:0", "-show_entries", "stream=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
        capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        pass
    r = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
        capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        return 0.0


def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--locale", default="en-GB")
    p.add_argument("--platform", choices=("ios", "android"), default="ios")
    p.add_argument("--beats", nargs="+", default=None,
                   help="beat names to include, in order (default: every beat)")
    args = p.parse_args()
    android = args.platform == "android"
    if args.beats is None:
        args.beats = DEFAULT_BEATS_ANDROID if android else DEFAULT_BEATS

    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg is required")
    try:
        from PIL import Image  # noqa: F401
    except ImportError:
        sys.exit("Pillow is required: pip install Pillow")
    if not pathlib.Path(FONT).exists():
        sys.exit("Georgia font not at %s -- this needs macOS" % FONT)

    problem_lines, solution_text, cta_text = load_strings(args.locale,
                                                          args.platform)

    locale_dir = render_dir(args.platform, args.locale)
    manifest_path = locale_dir / "manifest.json"
    if not manifest_path.exists():
        sys.exit("no render at %s -- run store/render.py --platform %s "
                 "--locale %s first" % (locale_dir, args.platform, args.locale))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("platform", "ios") != args.platform:
        sys.exit("%s holds a %s render, not %s"
                 % (locale_dir, manifest.get("platform", "ios"), args.platform))
    rendered = {b["name"]: b for b in manifest["beats"]}
    if manifest.get("fps") != FPS:
        sys.exit("rendered at %s fps, composed at %d" % (manifest.get("fps"), FPS))
    clips = []
    for beat in args.beats:
        if beat not in rendered:
            sys.exit("%s was not rendered for %s" % (beat, args.locale))
        frames = locale_dir / beat
        count = len(list(frames.glob("*.png")))
        if count != rendered[beat]["frames"]:
            sys.exit("%s: %d frames on disk, %d rendered"
                     % (beat, count, rendered[beat]["frames"]))
        clips.append(frames)

    texts = ["Wren"]  # the solution card's logo, drawn in every locale
    for block in (problem_lines, solution_text, cta_text):
        lines = block.split("\n") if isinstance(block, str) else list(block)
        texts += [_reshape_bidi(ln) if _has_arabic(ln) else ln for ln in lines]
    font_path, font_index = _font_for_locale(args.locale, texts)
    fallback = _latin_fallback.get(args.locale)
    say("composing %s advert for %s" % (args.platform, args.locale))
    say("  beats: %s" % ", ".join(args.beats))
    say("  rendered: %s" % locale_dir)

    out_dir = (ADVERTS / "android" / args.locale) if android \
        else ADVERTS / args.locale
    out_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        segments = []
        idx = 0

        for i, line in enumerate(problem_lines):
            say("  problem card %d: %s" % (i + 1, line))
            png = tmp / ("problem_%d.png" % i)
            _render([line], TEAL, CREAM, 58, png, font_path=font_path,
                   font_index=font_index, latin_fallback=fallback)
            mp4 = tmp / ("seg_%02d.mp4" % idx)
            # Fade in on the first card only; the teal background stays
            # continuous across all problem cards and the solution card.
            vf = "fade=in:0:%d" % FADE if i == 0 else ""
            _encode(png, mp4, duration=PROBLEM_HOLD,
                    vf_extra=vf, is_image=True)
            segments.append(mp4)
            idx += 1

        say("  solution card")
        sol_png = tmp / "solution.png"
        _render_solution_card(solution_text, sol_png, font_path=font_path,
                              font_index=font_index,
                              latin_fallback=fallback)
        sol_mp4 = tmp / ("seg_%02d.mp4" % idx)
        _encode(sol_png, sol_mp4, duration=SOLUTION_HOLD, is_image=True)
        segments.append(sol_mp4)
        idx += 1

        for beat_name, frames in zip(args.beats, clips):
            say("  beat: %s  %d frames"
                % (beat_name, rendered[beat_name]["frames"]))
            seg = tmp / ("seg_%02d.mp4" % idx)
            _encode(frames, seg, sequence=True,
                    vf_extra="fade=in:0:%d" % FADE)
            segments.append(seg)
            idx += 1

        say("  end card")
        end_png = tmp / "end_card.png"
        _render_end_card(cta_text, end_png, font_path=font_path,
                         font_index=font_index, latin_fallback=fallback)
        end_mp4 = tmp / ("seg_%02d.mp4" % idx)
        end_frame = int(END_CARD_HOLD * FPS) - FADE
        _encode(end_png, end_mp4, duration=END_CARD_HOLD,
                vf_extra="fade=in:0:%d,fade=out:%d:%d" % (FADE, end_frame, FADE),
                is_image=True)
        segments.append(end_mp4)

        final = out_dir / "wren-advert.mp4"
        say("  concatenating %d segments..." % len(segments))
        _concat(segments, final, tmp)

        total = _duration(final)
        size = final.stat().st_size
        say("")
        say("done: %s" % final)
        say("  %.1f seconds, %.1f MB" % (total, size / 1e6))
        say("  %d segments: %d problem cards + solution + %d beats + end card"
            % (len(segments), len(problem_lines), len(clips)))

        if total > 60:
            say("WARNING: over 60 seconds -- too long for most placements")
        elif total > 30:
            say("note: over 30 seconds -- fine for Reels, long for Stories")


if __name__ == "__main__":
    main()
