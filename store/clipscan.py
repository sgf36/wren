"""Where the app is on screen in a raw beat recording, to the frame.

    python store/clipscan.py store/footage/en-GB/advert-add.mov

Every beat is drawn with a 6x6 magenta sentinel in the top-left corner
(`_Sentinel` in `lib/src/advert.dart`). A frame carrying it is the app; a frame
without it is something else — the home screen, the white launch screen, the
previous beat's app going away. This reads **every** frame at the clip's own
rate and returns the last unbroken run of sentinel frames: that run is this
launch's beat, and nothing outside it may reach the advert.

## Why every frame, on 2 October 2026

The detector this replaced sampled at 3fps through ffmpeg's `fps` filter. That
filter rounds to the *nearest* tick by default, so the frame it reported at 15.0s
was really the one at 15.16s — and the trim started at 15.0, on the white launch
screen. Eleven of twelve adverts in run 34 opened a beat with one to five white
frames, which is the "flashes white quite a few times" Spencer saw. Decoding
every frame costs about a second a clip and leaves no rounding to get wrong.

It also fell back to a fixed 4.5s offset when it found nothing, which turned a
beat whose app never drew into seven seconds of white. Here, nothing found is
`None`, and the callers fail.
"""

import re
import subprocess
import sys

# The top-left corner of the recording, in the recording's own pixels. The
# sentinel sits at (2,2)-(8,8) points, which is 6-24 pixels at 3x.
_CROP = 48

# Magenta, allowing for a dialog barrier (Colors.black54) dimming it to roughly
# (117,0,117). Same thresholds the 3fps detector used, which never misfired.
def _is_sentinel(r, g, b):
    return r > 100 and g < 55 and b > 100


def frames(path):
    """[(pts_seconds, has_sentinel)] for every frame, in presentation order.

    `-ignore_editlist` because compose.py trims with it too, and the two must
    agree on what a timestamp means. Timestamps come from the same decode as
    the pixels (showinfo), so a dropped or reordered frame cannot shift them.
    """
    cmd = ["ffmpeg", "-v", "info", "-nostats", "-ignore_editlist", "1",
           "-i", str(path), "-map", "0:v:0", "-fps_mode", "passthrough",
           "-vf", "crop=%d:%d:0:0,showinfo" % (_CROP, _CROP),
           "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode != 0:
        raise RuntimeError("ffmpeg could not read %s: %s"
                           % (path, r.stderr.decode("utf-8", "replace")[-400:]))
    times = [float(t) for t in re.findall(
        r"pts_time:\s*(-?[0-9.]+)", r.stderr.decode("utf-8", "replace"))]
    size = _CROP * _CROP * 3
    data = r.stdout
    count = len(data) // size
    if count != len(times):
        raise RuntimeError("%s: %d frames decoded but %d timestamps"
                           % (path, count, len(times)))
    out = []
    for i in range(count):
        px = data[i * size:(i + 1) * size]
        hit = any(_is_sentinel(px[o], px[o + 1], px[o + 2])
                  for o in range(0, size, 3))
        out.append((times[i], hit))
    return out


def duration(path):
    """Stream duration as compose.py's trims see it (`-ignore_editlist`)."""
    r = subprocess.run(
        ["ffprobe", "-v", "error", "-ignore_editlist", "1",
         "-select_streams", "v:0", "-show_entries", "stream=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
        capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        return 0.0


def content_window(path, frame_list=None, clip_end=None):
    """(start, end) of the beat in seconds, or None when the app never drew.

    `start` is the exact timestamp of the first frame of the last unbroken run
    of sentinel frames. `end` is when that run stopped being on screen: the
    timestamp of the first frame after it, or the end of the clip if the run
    reaches it.

    The *last* run, because a recording can open on the previous beat's app
    still fading out — it carries a sentinel too. Anything after the run that is
    not the app (the home screen sliding in after `terminate`, in a clip
    recorded before record.py stopped the recorder first) is cut off by `end`.

    Says nothing about stalls inside the run; check() does.
    """
    fl = frame_list if frame_list is not None else frames(path)
    last = None
    for i in range(len(fl) - 1, -1, -1):
        if fl[i][1]:
            last = i
            break
    if last is None:
        return None
    first = last
    while first > 0 and fl[first - 1][1]:
        first -= 1
    if first == 0:
        # The run was already on screen when the recorder started, so nothing
        # in this clip shows this launch drawing. record.py terminates the app
        # before it records, so a real take always opens on something else
        # first. nb on 2 October 2026: one stale frame of the warm-up launch,
        # then 27 seconds in which the display never changed — which, without
        # this, reads as 27 seconds of beat.
        return None
    start = fl[first][0]
    if last + 1 < len(fl):
        end = fl[last + 1][0]
    else:
        end = clip_end if clip_end is not None else duration(path)
        end = max(end, fl[last][0])
    return start, end


# The app changes the sentinel's shade every 0.2s (`_SentinelState` in
# advert.dart), so even a held scene writes five frames a second. A longer gap
# is the display or the recorder stalling — on run 34 sv's which-city stopped
# writing frames at 19.25s and the movie ran on, empty, to 42.67s, through a tap
# and a terminate that never appeared.
MAX_GAP = 0.75


def largest_gap(frame_list, a, b):
    """(seconds, at) of the longest stretch in [a, b) with no new frame."""
    ts = [t for t, _ in frame_list if a <= t < b]
    if not ts:
        return b - a, a
    worst = (ts[0] - a, a)
    for x, y in zip(ts, ts[1:] + [b]):
        if y - x > worst[0]:
            worst = (y - x, x)
    return worst


def check(path, need, frame_list=None):
    """(start, end) of `need` seconds of the app, or (None, reason).

    The single test a take must pass: record.py applies it to decide whether
    to record again, compose.py to decide what to cut. `end` is `start + need`.
    Only the stream's own end counts as the clip's end — the movie header's
    duration overran the last real frame by 10 to 37 seconds on run 34.
    """
    fl = frame_list if frame_list is not None else frames(path)
    window = content_window(path, fl)
    if window is None:
        return None, "the app never drew in this clip: " + summary(fl)
    start, end = window
    if end - start < need - 0.05:
        return None, ("only %.2fs of the app for a %.2fs beat: %s"
                      % (end - start, need, summary(fl)))
    gap, at = largest_gap(fl, start, start + need)
    if gap > MAX_GAP:
        return None, ("the display stalled for %.2fs at %.2fs: %s"
                      % (gap, at, summary(fl)))
    return (start, start + need), None


def summary(frame_list):
    """Run-length description, for logs: 'app 4.29-11.52 (229f), other ...'."""
    runs = []
    for t, hit in frame_list:
        if runs and runs[-1][0] == hit:
            runs[-1][2] = t
            runs[-1][3] += 1
        else:
            runs.append([hit, t, t, 1])
    return ", ".join("%s %.2f-%.2f (%df)" % ("app" if h else "other", a, b, n)
                     for h, a, b, n in runs)


if __name__ == "__main__":
    for p in sys.argv[1:]:
        fl = frames(p)
        w = content_window(p, fl)
        print(p)
        print("  " + summary(fl))
        print("  content: %s" % ("%.3f-%.3f (%.2fs)" % (w[0], w[1], w[1] - w[0])
                                 if w else "NONE"))
