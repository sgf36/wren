"""Record the advert footage in a simulator.

    python store/record.py                          # every beat
    python store/record.py --beat advert-which-city # one
    python store/record.py --locale fr-FR           # in French
    python store/record.py --keep-build             # reuse the last build
    python store/record.py --verbose                # every command and output
    gh workflow run advert-footage.yml --ref main

macOS only -- it drives `xcrun simctl`. Run from the repo root. One `.mov` per
beat at the simulator's native size, written to `store/footage/<locale>/`.

The beats live in `lib/src/advert.dart` and are played **by the app**: this file
builds once, installs once, then per beat writes the scene name into the app's
tmp directory, starts the recorder, launches, waits, and terminates. Exactly the
mechanism `shoot.py` uses for screenshots, with a script running over the scene.

## What the first version got wrong, on 2026-08-29

It drove the beats from an `integration_test` harness. Three faults, all found by
running it, none visible beforehand:

  * **`LiveTestWidgetsFlutterBinding` paints a crosshair at the pointer.** It
    landed in the middle of the money shot. No supported way off. That alone
    settled the rewrite -- a marketing frame cannot carry a test artefact.
  * **`flutter test` rebuilds and reinstalls before running.** The recorder was
    already rolling, so a seven-second beat arrived at the end of a
    four-hundred-second file.
  * **`mdls` returns nothing on a CI runner.** It reads Spotlight metadata and
    ephemeral runners do not index, so it reported `0.0s` for a 402-second file.
    Both gates then divided by that zero and failed three good clips.

The last one is the one worth remembering: **the instrument was broken, not the
artefact.** So durations here are read out of the file's own QuickTime atoms
rather than asked of the operating system. It needs no ffmpeg, no Spotlight and
no network, and it cannot be absent on a runner.

## What it still cannot do

The Apple Maps payoff shot. A simulator ignores a `maps://guide` payload and
sends the https form to Safari -- measured both ways in ten languages,
`SCREENSHOTS-RUNBOOK.md` section 3. That shot is a device capture, permanently.

And it cannot tell you the footage is *good*. It can now prove a clip is the
right length and ran at a real frame rate, which is more than the first version
managed. It cannot see composition. Watch the clips.
"""

import argparse
import pathlib
import re
import signal
import struct
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import shoot  # noqa: E402  -- after the path insert, deliberately

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
FOOTAGE = HERE / "footage"
BEATS_DART = ROOT / "lib" / "src" / "advert.dart"
APP = ROOT / "build/ios/iphonesimulator/Runner.app"

# Time for `simctl io recordVideo` to open its file and start taking frames.
# Without it the opening second of every clip is missing, which is the second the
# app is coming up in.
RECORDER_LEAD_IN = 2.0

# How long to wait for the app to appear in launchd before giving up.
LAUNCH_TIMEOUT = 45.0

# After launchd reports the process, before the beat is assumed to be playing.
#
# launchd knows about the process well before Flutter has drawn anything. A cold
# debug build on a CI simulator took about eight seconds to its first frame, and
# a four-second allowance cut `advert-which-city` off partway through: the clip
# ran blank, showed the app briefly, then cut to the home screen because
# terminate arrived before the script had finished. The beat itself was fine.
FIRST_FRAME_SETTLE = 9.0

# Frames per second across the busiest two seconds of the clip.
#
# NOT the average, which is a trap this file fell into twice. `simctl` writes a
# frame only when the screen CHANGES, and a beat is mostly deliberate holds --
# `advert-which-city` is 68% held still by design. Its average was 8fps and its
# scroll ran at 59. Averaging the two measures how much of the beat is a hold,
# which is a creative decision, not a fault.
#
# A real scroll on this runner measures 55-61. Thirty is a floor.
MIN_PEAK_FPS = 30.0

# The window the peak is measured over.
PEAK_WINDOW = 2.0


def beats():
    """Beat names and lengths, read out of the Dart file rather than duplicated.

    `shoot.py` cross-checks its scene list against `sceneNames` for the same
    reason: two lists that must agree eventually will not, and the failure shows
    up as a run that quietly records some of the beats.
    """
    if not BEATS_DART.exists():
        sys.exit(f"no beats file at {BEATS_DART}")
    found = re.findall(
        r"'([A-Za-z0-9-]+)':\s*AdvertBeat\(\s*'([^']+)'\s*,\s*([0-9.]+)",
        BEATS_DART.read_text(encoding="utf-8"))
    if not found:
        sys.exit(f"found no AdvertBeat entries in {BEATS_DART}")
    return {name: (scene, float(seconds)) for name, scene, seconds in found}


# --- reading the movie back, without asking the operating system anything -----

def _atoms(buf, start, end, want, depth=0, out=None):
    """Walk the QuickTime atom tree, collecting the types in `want`."""
    out = out if out is not None else {}
    p = start
    while p + 8 <= end:
        size = struct.unpack(">I", buf[p:p + 4])[0]
        kind = buf[p + 4:p + 8]
        head = 8
        if size == 0:
            size = end - p
        elif size == 1:
            if p + 16 > end:
                break
            size = struct.unpack(">Q", buf[p + 8:p + 16])[0]
            head = 16
        if size < head:
            break
        if kind in want and kind not in out:
            out[kind] = (p + head, p + size)
        # Only these carry children worth descending into.
        if kind in (b"moov", b"trak", b"mdia", b"minf", b"stbl"):
            _atoms(buf, p + head, min(p + size, end), want, depth + 1, out)
        p += size
    return out


def probe(path):
    """(seconds, frames, finalised, peak_fps) read from the file's own atoms.

    `finalised` is whether a `moov` atom is present at all. A recorder that was
    killed rather than interrupted leaves a file of plausible size that no player
    will open, and nothing else here would notice.
    """
    buf = path.read_bytes()
    found = _atoms(buf, 0, len(buf),
                   {b"moov", b"mvhd", b"stsz", b"mdhd", b"stts"})
    if b"moov" not in found:
        return 0.0, 0, False, 0.0

    seconds = 0.0
    if b"mvhd" in found:
        at, _ = found[b"mvhd"]
        version = buf[at]
        if version == 0:
            scale, duration = struct.unpack(">II", buf[at + 12:at + 20])
        else:
            scale, duration = struct.unpack(">IQ", buf[at + 20:at + 32])
        seconds = duration / scale if scale else 0.0

    frames = 0
    if b"stsz" in found:
        at, _ = found[b"stsz"]
        frames = struct.unpack(">I", buf[at + 8:at + 12])[0]

    return seconds, frames, True, _peak_fps(buf, found)


def _peak_fps(buf, found):
    """The busiest [PEAK_WINDOW] seconds, in frames per second.

    Frame times are rebuilt from the time-to-sample table rather than asked of
    ffprobe, which is not on a fresh runner. Checked against ffprobe on three
    real clips: 61 against 59, 41 against 39.5, 35 against 33.5.
    """
    if b"mdhd" not in found or b"stts" not in found:
        return 0.0
    at, _ = found[b"mdhd"]
    version = buf[at]
    lo = at + (12 if version == 0 else 20)
    scale = struct.unpack(">I", buf[lo:lo + 4])[0]
    if not scale:
        return 0.0

    at, end = found[b"stts"]
    entries = struct.unpack(">I", buf[at + 4:at + 8])[0]
    times, tick, p = [], 0, at + 8
    for _ in range(entries):
        if p + 8 > end:
            break
        count, delta = struct.unpack(">II", buf[p:p + 8])
        p += 8
        for _ in range(count):
            times.append(tick / scale)
            tick += delta

    most, j = 0, 0
    for i, start in enumerate(times):
        if j < i:
            j = i
        while j < len(times) and times[j] - start <= PEAK_WINDOW:
            j += 1
        most = max(most, j - i)
    return most / PEAK_WINDOW


# --- the recorder ------------------------------------------------------------

def start_recorder(udid, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["xcrun", "simctl", "io", udid, "recordVideo",
           "--codec", "h264", "--force", str(path)]
    if shoot.VERBOSE:
        shoot.say(f"$ {' '.join(cmd)}", indent=2)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    time.sleep(RECORDER_LEAD_IN)
    if proc.poll() is not None:
        err = (proc.stderr.read() or "").strip()
        sys.exit(f"the recorder exited before it recorded anything: {err}")
    return proc


def stop_recorder(proc):
    """Stop capturing, and let the recorder close the file properly.

    **SIGINT, not SIGTERM or kill.** `simctl io recordVideo` writes the movie's
    index when it is interrupted; killed, it leaves a file of the right size with
    no `moov` atom, which no player will open and which every size-based check
    will pass.
    """
    proc.send_signal(signal.SIGINT)
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)
        shoot.say("the recorder had to be killed; that clip may not play",
                  indent=1)


def record_beat(udid, name, scene, seconds, out, app_tmp, language, locale):
    shoot.say(f"{name}  ({scene}, {seconds:.0f}s)")

    shoot.run("xcrun", "simctl", "terminate", udid, shoot.BUNDLE,
              check=False, quiet=True)
    if not shoot.name_scene(app_tmp, name):
        shoot.say("could not write the scene file", indent=1)
        return False

    proc = start_recorder(udid, out)
    try:
        cmd = ["xcrun", "simctl", "launch", udid, shoot.BUNDLE,
               "-AppleLanguages", f"({language})", "-AppleLocale", locale]
        if shoot.VERBOSE:
            shoot.say(f"$ {' '.join(cmd)}", indent=2)
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            shoot.say(f"launch failed: {r.stderr.strip()[:300]}", indent=1)
            return False

        # Ask launchd rather than guessing at a duration. The same instrument
        # shoot.py uses to prove which app is on screen.
        waited = 0.0
        while waited < LAUNCH_TIMEOUT and not shoot.running(udid, shoot.BUNDLE):
            time.sleep(1.0)
            waited += 1.0
        if waited >= LAUNCH_TIMEOUT:
            shoot.say(f"the app never appeared in launchd after "
                      f"{LAUNCH_TIMEOUT:.0f}s", indent=1)
            return False
        if shoot.VERBOSE:
            shoot.say(f"launchd has it after {waited:.0f}s", indent=2)

        time.sleep(FIRST_FRAME_SETTLE + seconds)
    finally:
        # Terminate before stopping the recorder, so the last frame is the app
        # rather than the home screen sliding back in.
        shoot.run("xcrun", "simctl", "terminate", udid, shoot.BUNDLE,
                  check=False, quiet=True)
        stop_recorder(proc)

    if not out.exists():
        shoot.say("the recorder wrote no file at all", indent=1)
        return False

    length, frames, finalised, peak = probe(out)
    average = frames / length if length else 0.0
    size = out.stat().st_size
    shoot.say(f"{out.name}  {length:.1f}s  {frames} frames  "
              f"peak {peak:.0f} fps (avg {average:.0f})  "
              f"{size / 1e6:.1f} MB", indent=1)

    if not finalised:
        shoot.say("no moov atom -- the recorder was killed rather than "
                  "interrupted, and this file will not play", indent=1)
        return False
    if length < seconds * 0.6:
        shoot.say(f"only {length:.1f}s of video for a {seconds:.0f}s beat", indent=1)
        return False
    if peak < MIN_PEAK_FPS:
        shoot.say(f"the busiest {PEAK_WINDOW:.0f}s of this clip ran at "
                  f"{peak:.0f} fps, which is stutter. No still will show it.",
                  indent=1)
        return False
    return True


def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--beat", action="append",
                   help="one beat by name; repeatable (default: all)")
    p.add_argument("--locale", default="en-GB",
                   help="device language for the recording (default en-GB)")
    p.add_argument("--keep-build", action="store_true",
                   help="reuse an existing build instead of rebuilding")
    p.add_argument("--verbose", action="store_true",
                   help="every command and its output")
    args = p.parse_args()

    shoot.VERBOSE = args.verbose

    available = beats()
    wanted = args.beat or list(available)
    unknown = [b for b in wanted if b not in available]
    if unknown:
        sys.exit(f"no such beat: {', '.join(unknown)}. "
                 f"This build has: {', '.join(available)}")

    language = args.locale.split("-")[0]
    out_dir = FOOTAGE / args.locale
    out_dir.mkdir(parents=True, exist_ok=True)

    if not args.keep_build or not APP.exists():
        shoot.say("building the app…")
        shoot.run("flutter", "build", "ios", "--simulator", "--debug",
                  "--dart-define=WREN_SHOTS=true")
    if not APP.exists():
        sys.exit(f"no app at {APP}")

    shoot.say(f"recording {len(wanted)} beat(s) in {args.locale}")
    udid, native, _ = shoot.boot_simulator()
    shoot.say(f"recording at {native[0]}x{native[1]}")
    shoot.run("xcrun", "simctl", "install", udid, str(APP))
    shoot.set_language(udid, language, args.locale.replace("-", "_"))
    # A real clock dates the footage, and a battery percentage differs between
    # takes of the same beat.
    shoot.clean_status_bar(udid)
    app_tmp = shoot.app_tmp_dir(udid)

    failures = []
    for name in wanted:
        scene, seconds = available[name]
        out = out_dir / f"{name}.mov"
        if not record_beat(udid, name, scene, seconds, out, app_tmp,
                           language, args.locale.replace("-", "_")):
            failures.append(name)

    shoot.say("")
    if failures:
        sys.exit(f"no usable clip for: {', '.join(failures)}")
    shoot.say(f"done -- {len(wanted)} clip(s) under {out_dir}")
    shoot.say("Now watch them. Length and frame rate are proved above; "
              "composition is not, and cannot be.")


if __name__ == "__main__":
    main()
