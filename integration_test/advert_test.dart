/// The app footage for the advert, driven in a simulator so it can be retaken
/// for free whenever the interface changes, in any language.
///
/// This is the moving-picture sibling of `lib/src/screenshots.dart`, and it
/// borrows that file's one good idea: a beat is the **real** app put into a
/// known state, never a rebuild of it. Both files call [sceneFor], so a card
/// that changes shape changes in the store screenshots and in the advert at the
/// same moment, and neither can drift into advertising an interface that no
/// longer exists.
///
/// What it is *not* is a test. Nothing here asserts a behaviour; the artifact is
/// a video file and the only real verdict is a person watching it. It lives
/// under `integration_test/` because that is the only harness Flutter offers
/// that drives real gestures against a real app on a real simulator.
///
/// Driven by `store/record.py`, which boots the simulator, starts
/// `simctl io recordVideo`, runs one beat, and stops the recorder. One clip per
/// beat rather than one long take: an editor wants four separate five-second
/// pieces far more than one twenty-second piece they have to cut up, and a beat
/// that comes out badly can be retaken on its own.
///
///     python store/record.py                    # every beat
///     python store/record.py --beat "the list"  # one
///
/// **The Apple Maps payoff shot is not here and cannot be.** A simulator does
/// not hand `maps://guide` payloads to Maps and does not claim
/// `maps.apple.com` at all — measured both ways, in ten languages, and written
/// up in `store/SCREENSHOTS-RUNBOOK.md` §3. That shot is a device capture,
/// permanently.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wren/l10n/app_localizations.dart';
import 'package:wren/main.dart';
import 'package:wren/src/screenshots.dart';

/// Run the beats on the fake clock, for `test/advert_probe_test.dart`.
///
/// Set to true only by the probe. It exists because the two things this file
/// does are worth checking separately: whether the *sequence* is right — the
/// scenes exist, the dialog opens, the button is where the tap goes — and
/// whether it *renders in real time*, which needs a device and eight minutes.
///
/// The first question is answered headless, on every `flutter test`, for
/// nothing. It is also the question that actually breaks: a renamed scene or a
/// moved string is a silent black clip, discovered after a simulator boot.
bool probeMode = false;

/// Roughly one frame at 60Hz.
const _frame = Duration(milliseconds: 16);

void main() {
  // Probing, the integration binding is not initialised at all, so `flutter
  // test` uses its ordinary one.
  //
  // This is not tidiness. [IntegrationTestWidgetsFlutterBinding] is a *live*
  // binding whatever its frame policy: every `pump` waits for a frame the
  // device is expected to draw, and with no device none ever arrives. The whole
  // file then dies on `_pendingFrame == null` in teardown, and every beat after
  // the first on `!inTest` — which reads as three broken beats rather than one
  // binding that cannot run here.
  if (!probeMode) {
    _goLive();
  }

  testWidgets('the list', (tester) async {
    await _open(tester, '01-the-list');

    // Long enough to read two rows before anything moves. The whole claim of
    // the app is in this frame — what was read, beside what it matched — and an
    // advert that scrolls it away before it can be read has thrown the shot.
    await _wait(tester, 1.8);
    await _scroll(tester, dy: -260, seconds: 1.6);
    await _wait(tester, 0.9);
    await _scroll(tester, dy: 260, seconds: 1.4);
    await _wait(tester, 1.0);
  });

  testWidgets('which city', (tester) async {
    await _open(tester, '04-which-city');

    // The scene opens the dialog from a post-frame callback, so it is not on
    // screen the instant the tree is built. The wait covers that and then
    // leaves it up long enough to be read.
    await _wait(tester, 2.6);
    await _tapText(tester, (l) => l.findPlaces);

    // The scene's resolver answers instantly and always, so this is the list
    // resolving rather than a spinner. That is a fair thing to show: the real
    // resolver is a network call and can be slower, but it is the same screen.
    await _wait(tester, 2.8);
  });

  testWidgets('correct a place', (tester) async {
    await _open(tester, '03-correct-a-place');

    // A name the map did not recognise, with the lookup already open on it.
    // Worth its five seconds: it is the app admitting a miss, which is the
    // difference between a tool and a magic trick, and it pre-empts the
    // obvious objection to anything that reads text off a picture.
    await _wait(tester, 4.5);
  });
}

/// Hands frame scheduling to the device, for the real recording.
///
/// The default policy draws only when the test asks for a frame, which is
/// correct for a test and useless here: the recording would show a slideshow of
/// the states the test happened to stop at. `fullyLive` draws on the device's
/// own vsync, so what `simctl` records is what a person would have seen.
///
/// The consequence is not obvious, and an earlier version of this file got it
/// wrong: once the binding is drawing frames, the test must not also pump them.
/// `await tester.pump(duration)` in a hold loop leaves a frame outstanding that
/// the binding has already taken responsibility for. So in live mode nothing
/// below pumps — it waits in real time and lets the binding draw. See [_waitFor].
void _goLive() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
}

/// Builds the real app around one of the scenes and waits for its first frame.
Future<void> _open(WidgetTester tester, String scene) async {
  final home = sceneFor(scene);
  if (home == null) {
    // Loud rather than a black clip nobody can explain a week later. The scene
    // names live in `sceneNames`; if one was renamed, this file is stale.
    fail('no scene called "$scene" — the names are ${sceneNames.join(', ')}');
  }
  await tester.pumpWidget(WrenApp(home: home));
  await _wait(tester, 0.6);
}

/// Holds the shot for [seconds].
///
/// Live, this is real time and the binding draws throughout — the test must not
/// pump, or it fights the binding for frame scheduling. Probing, it is the fake
/// clock, so the whole file runs in well under a second and animations still
/// advance.
Future<void> _wait(WidgetTester tester, double seconds) =>
    _waitFor(tester, Duration(milliseconds: (seconds * 1000).round()));

Future<void> _waitFor(WidgetTester tester, Duration d) async {
  if (probeMode) {
    await tester.pump(d);
    return;
  }
  await tester.runAsync<void>(() => Future<void>.delayed(d));
}

/// A visible, hand-paced scroll.
///
/// `tester.drag` moves the finger in one jump, which the list follows in one
/// jump too — correct for a test, and on video it reads as a cut rather than a
/// gesture. This walks the finger down in frame-sized steps.
Future<void> _scroll(
  WidgetTester tester, {
  required double dy,
  required double seconds,
}) async {
  final scrollable = find.byType(Scrollable);
  final origin = scrollable.evaluate().isEmpty
      ? tester.getCenter(find.byType(CapturePage))
      : tester.getCenter(scrollable.first);

  final steps = (seconds * 1000 / _frame.inMilliseconds).round().clamp(2, 600);
  final gesture = await tester.startGesture(origin);
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(0, dy / steps));
    await _waitFor(tester, _frame);
  }
  await gesture.up();
  await _waitFor(tester, _frame);
}

/// Taps a button by its localised label, so this runs in any language.
///
/// Looking the string up through [L] rather than writing "Find places" here:
/// the footage is meant to be retakeable in all forty-seven languages, and a
/// hardcoded English label would pass in English and silently find nothing in
/// every other one.
Future<void> _tapText(WidgetTester tester, String Function(L) pick) async {
  final context = tester.element(find.byType(CapturePage));
  final label = pick(L.of(context));
  final target = find.text(label);
  if (target.evaluate().isEmpty) {
    fail('nothing on screen reads "$label" — the dialog did not open, or the '
        'string moved');
  }
  await tester.tap(target);
  await _waitFor(tester, _frame);
}
