"""Compose a ready-to-publish advert from recorded beats and text cards.

    python store/compose.py                          # en-GB, default beats
    python store/compose.py --locale fr-FR           # French
    python store/compose.py --beats advert-the-list advert-which-city

macOS only -- uses system Georgia font and FFmpeg. Run from the repo root
after store/record.py has produced the footage.

Produces one 1080x1920 MP4 per locale under store/adverts/<locale>/.

The three-act structure:
  1. Problem -- each line on its own text card, teal background, cream text
  2. Screen recording -- beat clips from record.py showing the app in action
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
FOOTAGE = HERE / "footage"
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

# iPhone Pro/Pro Max safe area at 3x, cropped from beat clips before scaling.
# Removes the "9:41 Carrier" status bar and the home indicator bar.
_SAFE_TOP = 177    # Dynamic Island + status bar (59pt)
_SAFE_BOTTOM = 102  # home indicator (34pt)

# Instagram Reels/Stories overlay a CTA button in the bottom ~250px. Scale the
# beat clips to fit above it so the app's own buttons are not covered.
_IG_CTA_RESERVE = 250

_CJK_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Songti.ttc",
    "/System/Library/Fonts/STSongti-SC-Regular.otf",
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Supplemental/Hiragino Mincho ProN W3.otf",
]
_JA_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Hiragino Mincho ProN W3.otf",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
    "/System/Library/Fonts/PingFang.ttc",
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


def _font_for_locale(locale):
    if locale in _font_cache:
        return _font_cache[locale]
    lang = locale.split("-")[0]
    candidates = {"ja": _JA_CANDIDATES, "zh": _CJK_CANDIDATES,
                  "ko": _KO_CANDIDATES, "ar": _AR_CANDIDATES}.get(lang, [])
    for path in candidates:
        if pathlib.Path(path).exists():
            say("  font for %s: %s" % (locale, path))
            _font_cache[locale] = path
            return path
    _font_cache[locale] = FONT
    return FONT

try:
    from record import DEFAULT_BEATS
except ImportError:
    DEFAULT_BEATS = [
        "advert-intro", "advert-add", "advert-the-list",
        "advert-which-city", "advert-maps-web",
    ]

PROBLEM_HOLD = 2.5
SOLUTION_HOLD = 4.5
END_CARD_HOLD = 3.0


def say(msg):
    print(msg, flush=True)


def load_strings(locale):
    if not STRINGS.exists():
        sys.exit("no strings file at %s" % STRINGS)
    data = json.loads(STRINGS.read_text(encoding="utf-8"))
    problem = data.get("problem", {}).get(locale)
    solution = data.get("solution", {}).get(locale)
    cta = data.get("cta", {}).get(locale)
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
    try:
        import arabic_reshaper
        from bidi.algorithm import get_display
    except ImportError:
        return text
    reshaped = arabic_reshaper.reshape(text)
    return get_display(reshaped)


def _render(lines, bg, fg, font_size, out_path, line_spacing=1.7, y_shift=-60,
            font_path=None):
    from PIL import Image, ImageDraw, ImageFont

    if isinstance(lines, str):
        lines = lines.split("\n")

    if any(_has_arabic(ln) for ln in lines):
        lines = [_reshape_bidi(ln) for ln in lines]

    img = Image.new("RGB", (W, H), bg)
    draw = ImageDraw.Draw(img)
    font = ImageFont.truetype(font_path or FONT, font_size)

    bboxes = [font.getbbox(ln) for ln in lines]
    heights = [b[3] - b[1] for b in bboxes]
    widths = [b[2] - b[0] for b in bboxes]
    gap = int(font_size * (line_spacing - 1))
    total_h = sum(heights) + gap * max(len(lines) - 1, 0)

    y = (H - total_h) // 2 + y_shift
    for i, line in enumerate(lines):
        x = (W - widths[i]) // 2
        draw.text((x, y), line, fill=fg, font=font)
        y += heights[i] + gap

    img.save(out_path, "PNG")


def _render_end_card(cta_text, out_path, font_path=None):
    from PIL import Image, ImageDraw, ImageFont

    img = Image.new("RGB", (W, H), DEEP_TEAL)
    draw = ImageDraw.Draw(img)

    if APP_ICON.exists():
        icon = Image.open(APP_ICON).convert("RGBA")
        icon = icon.resize((200, 200), Image.LANCZOS)
        img.paste(icon, ((W - 200) // 2, H // 2 - 200 - 30), icon)

    font = ImageFont.truetype(font_path or FONT, 46)
    lines = cta_text.split("\n") if isinstance(cta_text, str) else cta_text
    if any(_has_arabic(ln) for ln in lines):
        lines = [_reshape_bidi(ln) for ln in lines]
    y = H // 2 + 30
    for line in lines:
        bbox = font.getbbox(line)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        draw.text(((W - tw) // 2, y), line, fill=CREAM, font=font)
        y += th + 24

    img.save(out_path, "PNG")


def _encode(src, dst, duration=None, vf_extra="", is_image=False,
            trim_start=None, trim_duration=None):
    """Encode any source to a standardised 1080x1920 h264 segment."""
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
        cmd += ["-loop", "1"]
    else:
        cmd += ["-ignore_editlist", "1"]
    cmd += ["-i", str(src)]
    if trim_start is not None:
        cmd += ["-ss", str(trim_start)]
    if trim_duration is not None:
        cmd += ["-t", str(trim_duration)]
    elif duration is not None:
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
    # Stream-level duration with -ignore_editlist matches how _encode reads
    # VFR simulator recordings. Without it, ffprobe reports a container
    # duration that differs from what ffmpeg actually processes, and the trim
    # logic cuts the wrong range.
    r = subprocess.run(
        ["ffprobe", "-v", "error", "-ignore_editlist", "1",
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
    p.add_argument("--beats", nargs="+", default=DEFAULT_BEATS,
                   help="beat names to include (default: advert-the-list)")
    args = p.parse_args()

    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg is required")
    try:
        from PIL import Image  # noqa: F401
    except ImportError:
        sys.exit("Pillow is required: pip install Pillow")
    if not pathlib.Path(FONT).exists():
        sys.exit("Georgia font not at %s -- this needs macOS" % FONT)

    problem_lines, solution_text, cta_text = load_strings(args.locale)

    locale_dir = FOOTAGE / args.locale
    if not locale_dir.exists():
        alt = FOOTAGE / args.locale.replace("-", "_")
        if alt.exists():
            locale_dir = alt
        else:
            sys.exit("no footage at %s -- run record.py first" % locale_dir)

    clips = []
    for beat in args.beats:
        clip = locale_dir / ("%s.mov" % beat)
        if not clip.exists():
            sys.exit("missing beat clip: %s" % clip)
        clips.append(clip)

    font_path = _font_for_locale(args.locale)
    say("composing advert for %s" % args.locale)
    say("  beats: %s" % ", ".join(args.beats))
    say("  footage: %s" % locale_dir)

    out_dir = ADVERTS / args.locale
    out_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        segments = []
        idx = 0

        for i, line in enumerate(problem_lines):
            say("  problem card %d: %s" % (i + 1, line))
            png = tmp / ("problem_%d.png" % i)
            _render([line], TEAL, CREAM, 58, png, font_path=font_path)
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
        _render(solution_text, TEAL, GOLD, 50, sol_png, font_path=font_path)
        sol_mp4 = tmp / ("seg_%02d.mp4" % idx)
        _encode(sol_png, sol_mp4, duration=SOLUTION_HOLD, is_image=True)
        segments.append(sol_mp4)
        idx += 1

        beat_info = {}
        try:
            from record import beats as _get_beats, RECORDER_LEAD_IN
            beat_info = _get_beats()
        except Exception:
            pass

        for beat_name, clip in zip(args.beats, clips):
            clip_secs = _duration(clip)
            info = beat_info.get(beat_name)
            beat_secs = info[1] if info else clip_secs
            scene = info[0] if info else ""

            trim_file = clip.with_suffix('.trim')
            if trim_file.exists():
                trim_s = float(trim_file.read_text().strip())
                trim_d = beat_secs + 0.5
            elif scene == 'splash':
                trim_s = RECORDER_LEAD_IN if beat_info else 2.0
                trim_d = min(beat_secs + 0.5, max(0, clip_secs - trim_s))
            elif beat_info and clip_secs > beat_secs + 2.0:
                trim_s = max(0, clip_secs - beat_secs - 0.5)
                trim_d = min(beat_secs + 0.5, max(0, clip_secs - trim_s))
            else:
                trim_s = None
                trim_d = None

            if trim_s is not None:
                say("  beat: %s  (%.1fs from %.1fs clip)"
                    % (clip.name, trim_d, clip_secs))
            else:
                say("  beat: %s  (%.1fs)" % (clip.name, clip_secs))

            seg = tmp / ("seg_%02d.mp4" % idx)
            _encode(clip, seg, trim_start=trim_s, trim_duration=trim_d,
                    vf_extra="fade=in:0:%d" % FADE)
            segments.append(seg)
            idx += 1

        say("  end card")
        end_png = tmp / "end_card.png"
        _render_end_card(cta_text, end_png, font_path=font_path)
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
