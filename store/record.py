"""Record the app footage for the advert, in a simulator.

    python store/record.py                       # every beat
    python store/record.py --beat "which city"   # one
    python store/record.py --locale fr-FR        # in French
    python store/record.py --verbose             # every command and its output
    gh workflow run advert-footage.yml --ref main

macOS only -- it drives `xcrun simctl`. Run from the repo root.

One `.mov` per beat, at the simulator's native size, written to
`store/footage/<locale>/`. The beats themselves live in
`integration_test/advert_test.dart`; this file only boots the device, starts the
recorder, runs one beat and stops the recorder.

The simulator is booted by `shoot.boot_simulator()` rather than a second copy of
that logic. It is fussier than video needs -- it insists on a device that shoots
the App Store's 1290x2796 slot -- but the fussiness costs nothing here and the
three routes it tries took a run to get right. Never reimplement it.

Two things this cannot do, both settled elsewhere and neither a bug here:

  * **The Apple Maps payoff shot.** A simulator ignores a `maps://guide`
    payload and sends `https://maps.apple.com/guide` to Safari. Measured both
    ways in ten languages -- `SCREENSHOTS-RUNBOOK.md` section 3. That shot is a
    device capture, permanently.

  * **Judge the footage.** The size-per-second check below can tell you a clip
    is frozen. Nothing here can tell you it is *choppy*, and a CI runner has no
    GPU, so a list that animates at fifteen frames a second is the failure mode
    to expect. It will pass every check in this file. Watch the clips.
"""

import argparse
import pathlib
import re
import signal
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import shoot  # noqa: E402  -- after the path insert, deliberately

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
FOOTAGE = HERE / "footage"
TEST = ROOT / "integration_test" / "advert_test.dart"

# Long enough for `simctl io recordVideo` to have opened its file and started
# taking frames. Without it the first second of every clip is missing, which is
# exactly the second the app is coming up in.
RECORDER_LEAD_IN = 2.0

# Below this, a clip is almost certainly a still. H.264 spends its bytes on
# change, so a frozen screen compresses to nearly nothing -- an early run that
# recorded a simulator which never launched the app produced 11 kB for eight
# seconds. A moving clip at this size runs to hundreds of kB per second.
MIN_BYTES_PER_SECOND = 25_000


def beats_in_test_file():
    """The beat names, read out of the Dart file rather than duplicated here.

    `shoot.py` cross-checks its scene list against `sceneNames` for the same
    reason: two lists that must agree will not, and the failure shows up as a
    run that quietly records four of five beats.
    """
    if not TEST.exists():
        sys.exit(f"no test file at {TEST}")
    names = re.findall(r"""testWidgets\(\s*['"](.+?)['"]""", TEST.read_text())
    if not names:
        sys.exit(f"found no testWidgets(...) beats in {TEST}")
    # `flutter test --plain-name` matches a SUBSTRING, not a whole name. Two
    # beats called "the list" and "the list, scrolled" would both run under the
    # first, and the clip would hold two beats end to end with nothing saying so
    # -- it would simply be twice as long as expected, which reads as a slow
    # take rather than a fault.
    clashes = [(a, b) for a in names for b in names if a != b and a in b]
    if clashes:
        pairs = "; ".join(f'"{a}" is inside "{b}"' for a, b in clashes)
        sys.exit(f"beat names must not contain one another -- {pairs}")
    return names


def start_recorder(udid, path):
    """Begin capturing the simulator screen. Returns the process."""
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
    index when it is interrupted; killed, it leaves a file of the right size
    that no player will open, and the run looks like it worked.
    """
    proc.send_signal(signal.SIGINT)
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)
        shoot.say("the recorder had to be killed; that clip may not play",
                  indent=1)


def duration_of(path):
    """Seconds, from Spotlight's own metadata. No ffmpeg on a fresh runner."""
    r = subprocess.run(
        ["mdls", "-name", "kMDItemDurationSeconds", "-raw", str(path)],
        capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        return 0.0


def run_beat(udid, beat, out, locale):
    """Record one beat. Returns True if the clip looks like moving pictures."""
    shoot.say(f"{beat}")
    proc = start_recorder(udid, out)
    failed = None
    try:
        cmd = ["flutter", "test", str(TEST.relative_to(ROOT)),
               "-d", udid,
               "--plain-name", beat,
               # Belt and braces: nothing in the harness reads this, because it
               # imports `sceneFor` directly rather than going through main()'s
               # gate. Passed anyway so the build matches the one the store
               # screenshots are taken from.
               "--dart-define=WREN_SHOTS=true"]
        if shoot.VERBOSE:
            shoot.say(f"$ {' '.join(cmd)}", indent=2)
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        if r.returncode != 0:
            tail = (r.stdout or "").strip().splitlines()[-12:]
            failed = "\n".join(tail) or (r.stderr or "").strip()[:800]
    finally:
        # Always, including when the beat failed: a clip of the failure is the
        # most useful thing to look at when working out why it failed.
        stop_recorder(proc)

    if failed:
        shoot.say(f"the beat did not run:\n{failed}", indent=1)
        return False
    if not out.exists():
        shoot.say("the recorder wrote no file at all", indent=1)
        return False

    seconds = duration_of(out)
    size = out.stat().st_size
    rate = size / seconds if seconds else 0
    shoot.say(f"{out.name}  {seconds:.1f}s  {size / 1e6:.1f} MB  "
              f"{rate / 1000:.0f} kB/s", indent=1)

    if seconds < 1.0:
        shoot.say("under a second of video -- the recorder was stopped before "
                  "the beat ran, or the file did not close", indent=1)
        return False
    if rate < MIN_BYTES_PER_SECOND:
        shoot.say(f"only {rate / 1000:.0f} kB/s, so almost nothing moved on "
                  f"screen. Expect a still of the home screen or a frozen app.",
                  indent=1)
        return False
    return True


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--beat", action="append",
                   help="one beat by name; repeatable (default: all of them)")
    p.add_argument("--locale", default="en-GB",
                   help="device language for the recording (default en-GB)")
    p.add_argument("--verbose", action="store_true",
                   help="every command and its output")
    args = p.parse_args()

    shoot.VERBOSE = args.verbose

    available = beats_in_test_file()
    wanted = args.beat or available
    unknown = [b for b in wanted if b not in available]
    if unknown:
        sys.exit(f"no such beat: {', '.join(unknown)}. "
                 f"This file has: {', '.join(available)}")

    language = args.locale.split("-")[0]
    out_dir = FOOTAGE / args.locale
    out_dir.mkdir(parents=True, exist_ok=True)

    shoot.say(f"recording {len(wanted)} beat(s) in {args.locale}")
    udid, native, _ = shoot.boot_simulator()
    shoot.say(f"recording at {native[0]}x{native[1]}")
    shoot.set_language(udid, language, args.locale.replace("-", "_"))
    # A real clock ticking through a shot dates the footage, and a carrier name
    # or a battery percentage differs between takes of the same beat.
    shoot.clean_status_bar(udid)

    failures = []
    for beat in wanted:
        slug = re.sub(r"[^a-z0-9]+", "-", beat.lower()).strip("-")
        if not run_beat(udid, beat, out_dir / f"{slug}.mov", args.locale):
            failures.append(beat)

    shoot.say("")
    if failures:
        sys.exit(f"no usable clip for: {', '.join(failures)}")
    shoot.say(f"done -- {len(wanted)} clip(s) under {out_dir}")
    shoot.say("Now watch them. Nothing above can see a stutter, and a "
              "GPU-less runner is where stutter comes from.")


if __name__ == "__main__":
    main()
