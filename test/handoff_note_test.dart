import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wren/l10n/app_localizations.dart';
import 'package:wren/main.dart';
import 'package:wren/src/advert.dart';
import 'package:wren/src/map_targets.dart';

/// The send sheet's per-app notes follow the phone's language.
///
/// Until 3 October 2026 they were MapTarget.note, English constants, so a
/// German phone read "Senden an", "Andere App" and every other line in German
/// and these four in English. The Android advert showed it in German, French
/// and Italian before anyone had noticed on a phone.
void main() {
  testWidgets('a German phone reads the notes in German', (tester) async {
    tester.platformDispatcher.localesTestValue = [const Locale('de')];
    tester.platformDispatcher.localeTestValue = const Locale('de');
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    await tester.pumpWidget(WrenApp(home: advertFor('advert-android-send')));
    await tester.pump(const Duration(milliseconds: 300));
    final l = L.of(tester.element(find.byType(CapturePage)));
    expect(l.localeName, 'de');

    for (var t = 0.0; t < advertLeadIn + 2.0; t += 0.1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Positive control first: the sheet is open.
    expect(find.text('Organic Maps'), findsOneWidget);

    expect(find.text(l.handoffNoteOsmand), findsOneWidget);
    expect(find.text(l.handoffNoteLocus), findsOneWidget);
    expect(find.text(l.handoffNoteGoogleMaps), findsOneWidget);
    for (final english in [
      namedTargets.firstWhere((t) => t.id == 'osmand').note,
      namedTargets.firstWhere((t) => t.id == 'locus').note,
      googleMapsTarget.note,
    ]) {
      expect(find.text(english), findsNothing, reason: 'still English');
    }
  });
}
