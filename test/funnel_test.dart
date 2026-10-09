import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wren/main.dart';
import 'package:wren/src/entitlement.dart';
import 'package:wren/src/funnel.dart';

import 'harness.dart';
import 'paywall_test.dart' show FakeStore, place;

/// Keeps what was recorded, in order, instead of sending it.
class RecordingFunnel extends Funnel {
  final List<String> steps = [];

  @override
  void record(FunnelStep step, {String? detail}) =>
      steps.add(detail == null ? step.wire : '${step.wire}:$detail');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the version the funnel reports is the version being shipped', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*([0-9.]+)\+',
      multiLine: true,
    ).firstMatch(pubspec)!.group(1);
    expect(appVersion, version);
  });

  // The server drops any step it does not know, silently, so a step named here
  // and not there would be a count that never arrives.
  test('every step the app sends is one the server accepts', () {
    final php = File('web/f/index.php').readAsStringSync();
    for (final step in FunnelStep.values) {
      expect(php, contains("'${step.wire}'"), reason: step.wire);
    }
  });

  testWidgets('a paywall that ends in a purchase records every step', (
    tester,
  ) async {
    final funnel = RecordingFunnel();
    await tester.pumpWidget(
      app(
        CapturePage(
          store: FakeStore(),
          funnel: funnel,
          initialPending: List.generate(5, place),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Make a guide (5)'));
    await tester.pumpAndSettle();
    expect(funnel.steps, contains('paywall_shown:places'));

    await tester.tap(find.textContaining(r'Unlock for $8.99'));
    await tester.pumpAndSettle();
    expect(
      funnel.steps,
      containsAllInOrder([
        'paywall_shown:places',
        'buy_tapped:unlimited',
        'purchased:unlimited',
      ]),
    );
  });

  testWidgets('a declined purchase is counted as failed, not bought', (
    tester,
  ) async {
    final funnel = RecordingFunnel();
    await tester.pumpWidget(
      app(
        CapturePage(
          store: FakeStore(buySucceeds: false),
          funnel: funnel,
          initialPending: List.generate(5, place),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make a guide (5)'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(r'Unlock for $8.99'));
    await tester.pumpAndSettle();

    expect(funnel.steps, contains('purchase_failed:unlimited'));
    expect(funnel.steps, isNot(contains('purchased:unlimited')));
  });

  testWidgets('the sheet leads with the places the user already has', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        CapturePage(
          store: FakeStore(),
          initialPending: List.generate(5, place),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make a guide (5)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Your 5 places are ready.'), findsOneWidget);
    expect(
      find.textContaining('up to $freePlaceLimit per guide'),
      findsOneWidget,
    );
  });
}
