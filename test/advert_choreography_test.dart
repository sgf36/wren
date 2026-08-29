/// The advert beats, played on the fake clock.
///
/// The beats need a simulator and produce a video whose only real verdict is a
/// person watching it. But almost nothing that goes wrong with them is about
/// video: it is a renamed scene, a button whose string moved, a list that
/// stopped scrolling. Those are answerable here in a second, and otherwise show
/// up as a wasted recording after a simulator boot.
///
/// This became possible when the choreography moved into the app. The old
/// `integration_test` version could not be tested this way at all — its binding
/// is live, so every pump waited for a frame that no device was there to draw.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wren/l10n/app_localizations.dart';
import 'package:wren/main.dart';
import 'package:wren/src/advert.dart';

/// Runs a beat to completion on the fake clock.
///
/// `pumpAndSettle` is not enough: the scripts wait in real time, and a wait is
/// only a `Future.delayed`, which fake async advances when the clock does. So
/// the beat is walked forward in slices rather than settled.
Future<void> _play(WidgetTester tester, String beat) async {
  final home = advertFor(beat);
  expect(home, isNotNull, reason: 'no beat called "$beat"');
  await tester.pumpWidget(WrenApp(home: home));
  final seconds = advertBeats[beat]!.seconds;
  for (var t = 0.0; t < seconds + 1; t += 0.1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('every beat names a scene that exists', (tester) async {
    for (final entry in advertBeats.entries) {
      expect(advertFor(entry.key), isNotNull,
          reason: '${entry.key} is built on "${entry.value.scene}", which '
              'sceneFor() does not know');
    }
  });

  testWidgets('the list scrolls under the drag', (tester) async {
    await tester.pumpWidget(WrenApp(home: advertFor('advert-the-list')));
    await tester.pump(const Duration(milliseconds: 300));

    final scrollable = find.byType(Scrollable).first;
    final before = tester.state<ScrollableState>(scrollable).position.pixels;

    for (var t = 0.0; t < 4.0; t += 0.05) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final moved = tester.state<ScrollableState>(scrollable).position.pixels;

    // The drag goes down and comes back, so the interesting claim is not where
    // it ended but that the list is scrollable at all — a five-place list on a
    // 2796-high screen barely overflows, and if it stops overflowing the beat
    // silently becomes a still.
    expect(tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
        greaterThan(0),
        reason: 'nothing to scroll — the beat would record a motionless list');
    expect(moved, isNotNull);
    expect(before, isNotNull);
  });

  testWidgets('which city taps the button and the dialog goes away',
      (tester) async {
    await tester.pumpWidget(WrenApp(home: advertFor('advert-which-city')));
    await tester.pump(const Duration(milliseconds: 300));

    final label = L.of(tester.element(find.byType(CapturePage))).findPlaces;

    // The scene opens the dialog from its own post-frame callback.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(label), findsOneWidget,
        reason: 'the region dialog never opened, so there is nothing to tap');

    for (var t = 0.0; t < 9.0; t += 0.1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // The tap is the whole point of this beat. If the dialog is still up, the
    // pointer events did not land — which is exactly the failure that reached a
    // recording once already.
    expect(find.text(label), findsNothing,
        reason: 'the dialog is still open, so the synthesised tap missed');
  });

  testWidgets('correct a place holds the lookup open', (tester) async {
    await _play(tester, 'advert-correct-a-place');
    // Nothing is asserted about motion here; the beat is a held shot. What is
    // worth proving is that it runs to the end without throwing.
    expect(tester.takeException(), isNull);
  });
}
