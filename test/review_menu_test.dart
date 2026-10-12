import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wren/main.dart';
import 'package:wren/src/review_prompt.dart';

import 'harness.dart';
import 'paywall_test.dart' show FakeStore;

/// The menu's "Rate Wren": always offered, and it opens the store's own review
/// page rather than raising a prompt of Wren's (Apple forbids custom prompts).
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
  }

  testWidgets('Rate Wren is in the menu on an empty list', (tester) async {
    final prompt = FakeReviewPrompt();
    await tester.pumpWidget(
      app(
        CapturePage(
          store: FakeStore(),
          reviewPrompt: prompt,
          skipOnboarding: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openMenu(tester);
    expect(find.text('Rate Wren'), findsOneWidget);

    await tester.tap(find.text('Rate Wren'));
    await tester.pumpAndSettle();
    expect(prompt.storePageOpens, 1);
    // Choosing to rate is not a success and spends nothing of the prompt.
    expect(prompt.asks, 0);
    expect(prompt.successes, 0);
  });

  testWidgets('Rate Wren stays after everything is bought', (tester) async {
    await tester.pumpWidget(
      app(
        CapturePage(
          store: FakeStore(),
          reviewPrompt: FakeReviewPrompt(),
          skipOnboarding: true,
          initialOwned: const {
            'com.spencerfields.littlebird.unlimited',
            'com.spencerfields.littlebird.reels.upgrade',
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openMenu(tester);
    expect(find.text('Rate Wren'), findsOneWidget);
  });
}
