# Play screenshots

Four phone screenshots, in `screenshots/en-GB/`, shot on the `wren_play`
emulator against a real debug build. `01` was reshot on 7 September 2026 for
2.0; the other three were shot on 20 August 2026 and are unchanged, because the
file-import route they show is untouched by 2.0.

| File | What it shows |
|---|---|
| `01-first-screen.png` | The first screen. **Reshot for 2.0**: it now opens "Share a reel or a post to Wren and it reads the places out of it", which is what the store listing leads with. The 1.x capture described an app that only read screenshots, so the words and the pictures disagreed |
| `02-the-list.png` | Six places read out of a CSV, each one to keep or drop |
| `03-send-sheet.png` | The hand-off sheet, listing only map apps that are installed |
| `04-landed.png` | The same six places inside Organic Maps, under the file's own name |

**Nothing in `store/screenshots/` may be used here.** Those are iPhone captures
of the iOS app and several of them show Apple Maps, which does not exist on
Android. There is no overlap between the two sets and there never will be.

## What is deliberately NOT here yet

There is **no screenshot of a reel being read**. Getting one needs three things
that a capture run does not otherwise need: a complimentary code carrying the
`everything` or `admin` role (an ordinary unlock code does not grant reels), a
real post fetched through the live Worker, which spends a ScrapeCreators credit
and Vertex tokens, and a share into the app from another app on the device.

The judgement was that `01` now states the reel route in the app's own words on
the first screen, and that the list a reel produces is the same list a file
produces -- `02` already shows it. A dedicated shot would be better and is worth
doing before production, but it is not worth a paid read and a minted code to
show a screen that differs by one line of source text.

## Shooting them again

```bash
bash tools/emulator.sh                     # wren_play
flutter build apk --debug --no-pub
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Then, in order, and each one matters:

**Make the display 9:16.** The AVD is 1080×2400, which is 2.22:1 and over
Play's 2:1 ceiling — it would be refused on upload, not on shooting.

```bash
adb shell wm size 1080x1920        # adb shell wm size reset  when finished
```

**Turn on the SystemUI demo mode**, or every shot carries the emulator's clock
and a VPN shield in the status bar.

```bash
adb shell settings put global sysui_demo_allowed 1
adb shell am broadcast -a com.android.systemui.demo -e command enter
adb shell am broadcast -a com.android.systemui.demo -e command clock -e hhmm 0930
adb shell am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false
adb shell am broadcast -a com.android.systemui.demo -e command network -e wifi show -e level 4 -e fully true
adb shell am broadcast -a com.android.systemui.demo -e command network -e mobile hide
adb shell am broadcast -a com.android.systemui.demo -e command notifications -e visible false
```

**Start both apps from nothing**, so the map app's list is the one that just
arrived rather than five left over from earlier runs.

```bash
adb shell pm clear com.spencerfields.littlebird
adb shell pm clear app.organicmaps
```

**Convert to RGB before uploading.** `screencap` writes RGBA and Play refuses an
alpha channel.

## Traps

**A cleared app takes about fifteen seconds to draw.** `pm clear` plus a cold
start plus the splash gate; shooting at ten produced a 12 kB screenshot of a
flat green rectangle that was the right size, the right ratio and the right
colour depth, and passed every mechanical check. Open every file and look at it.

**Organic Maps swallows the first hand-off after `pm clear`** while it asks for
location twice and then complains that location is off. Decline both prompts,
close the dialog, and the places are already there — the pin is visible behind
it. This is the same first-launch behaviour recorded for Locus and Mapy.

**`adb push` needs a Windows path for the local file and `MSYS_NO_PATHCONV=1`
for the device path**, and those two wants conflict. Give the source as
`C:\...` and prefix the command; MSYS mangles `/sdcard` otherwise.

**The file the picker opens is not where you put it.** The document picker
reopens wherever it was last, so drive it through the drawer to Downloads
rather than trusting the first screen.

## The demo file

`Saved places.csv`, six London restaurants with real coordinates, pushed to
`/sdcard/Download/`. A CSV on purpose: it carries no title inside it, so the
list arrives in the other map app under the file's own name, which is the
behaviour the fourth screenshot exists to show.
