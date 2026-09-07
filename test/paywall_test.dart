import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wren/main.dart';
import 'package:wren/src/entitlement.dart';
import 'package:wren/src/guide_link.dart';
import 'package:wren/src/resolver.dart';

import 'harness.dart';

/// Stands in for StoreKit. Records what was asked of it so the tests can check
/// the app did not, for instance, charge someone twice.
class FakeStore implements UnlockStore {
  FakeStore({this.buySucceeds = true, this.restoreSucceeds = false, this.owns});

  final bool buySucceeds;

  /// Whether restoring finds anything at all.
  final bool restoreSucceeds;

  /// What restoring finds, when it finds anything. Defaults to the original
  /// unlock — the account almost every real restore belongs to.
  final Set<String>? owns;

  int buyCalls = 0;
  int restoreCalls = 0;

  /// Which products were bought, in order. The count alone stopped being
  /// enough once there were three of them at three prices.
  final List<String> bought = [];

  /// The real per-product prices, so a test that asserts on a figure is
  /// asserting on the right one.
  @override
  Future<String?> price(String productId) async => switch (productId) {
    everythingProductId => r'$14.99',
    reelsUpgradeProductId => r'$9.99',
    _ => r'$8.99',
  };

  @override
  Future<bool> buy(String productId) async {
    buyCalls++;
    if (buySucceeds) bought.add(productId);
    return buySucceeds;
  }

  @override
  Future<Set<String>> restore() async {
    restoreCalls++;
    if (!restoreSucceeds) return const {};
    return owns ?? const {unlimitedProductId};
  }
}

Pending place(int i) => Pending(
  'read $i',
  PlaceMatch(
    id: PlaceId.parse('I43FA2531C5B5D63${i.toRadixString(16)}'),
    name: 'Place $i',
    address: '$i Somewhere Street',
    category: 'Restaurant',
    metresFromCentre: 0,
  ),
);

Future<void> pump(WidgetTester tester, FakeStore store, int count) async {
  await tester.pumpWidget(
    app(CapturePage(store: store, initialPending: List.generate(count, place))),
  );
  await tester.pumpAndSettle();
}

void main() {
  // Mock preferences persist between tests, so an unlock seeded by one test
  // would silently disable the paywall in the next. Reset first.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  purchaseIsReachable();
  paywallMatrix();
  testWidgets('three places publish without ever mentioning money', (
    tester,
  ) async {
    final store = FakeStore();
    await pump(tester, store, freePlaceLimit);

    expect(find.text('Make a guide (3)'), findsOneWidget);
    // No nag banner while the user is inside the free allowance.
    expect(find.textContaining('over the free limit'), findsNothing);
    expect(store.buyCalls, 0);
  });

  testWidgets('a fourth place warns before the user commits to anything', (
    tester,
  ) async {
    await pump(tester, FakeStore(), 4);
    // Told in the list view, not sprung on them at the end.
    expect(find.textContaining('over the free limit'), findsOneWidget);
  });

  testWidgets('publishing over the limit offers the unlock and a way past it', (
    tester,
  ) async {
    final store = FakeStore();
    await pump(tester, store, 5);

    await tester.tap(find.text('Make a guide (5)'));
    await tester.pumpAndSettle();

    expect(find.text('Guides of any size'), findsOneWidget);
    expect(find.textContaining(r'Unlock for $8.99'), findsOneWidget);
    // The escape hatch matters: a paywall with no way forward is the wrong trade.
    expect(find.textContaining('Save the first 3 instead'), findsOneWidget);
    expect(find.text('Restore a previous purchase'), findsOneWidget);

    // Merely opening the sheet must not charge anybody.
    expect(store.buyCalls, 0);
  });

  testWidgets('restore is reachable without walking into the paywall', (
    tester,
  ) async {
    // Apple requires a discoverable restore path, and someone who already paid
    // should not have to trip the paywall to find it.
    final store = FakeStore(restoreSucceeds: true);
    await pump(tester, store, 1);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore purchase'));
    await tester.pumpAndSettle();

    expect(store.restoreCalls, 1);
    expect(find.textContaining('Restored'), findsOneWidget);
  });

  testWidgets('a failed restore says so plainly and stays locked', (
    tester,
  ) async {
    final store = FakeStore(restoreSucceeds: false);
    await pump(tester, store, 4);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore purchase'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No previous purchase found'), findsOneWidget);
    // Still gated — a failed restore must not quietly unlock anything.
    expect(find.textContaining('over the free limit'), findsOneWidget);
  });
}

/// Reaching the purchase without building a list first.
///
/// App Review rejected build 83 under guideline 2.1(b) -- "we cannot locate the
/// In-App Purchases ... within the app" -- because the paywall existed only
/// inside the publishing flow, behind a list of more than three places. On a
/// review device with nothing imported there was no way to reach it at all.
///
/// These hold the way back in. A reviewer opening the app cold is the case that
/// matters, so that is what they pump: no places, nothing added.
void purchaseIsReachable() {
  group('the purchase can be found from a standing start', () {
    testWidgets('the menu offers it with an empty list', (tester) async {
      final store = FakeStore();
      await pump(tester, store, 0);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Guides of any size'), findsOne);

      await tester.tap(find.text('Guides of any size'));
      await tester.pumpAndSettle();

      // The sheet says what is being bought and what it costs, and offers the
      // restore Apple requires alongside it.
      expect(find.text(r'Unlock for $8.99'), findsOne);
      expect(find.text('Restore a previous purchase'), findsOne);
      // And it does not claim anything about a list that does not exist.
      expect(find.textContaining('0 selected'), findsNothing);
      expect(find.textContaining('Save the first'), findsNothing);
    });

    testWidgets('buying from the menu unlocks and publishes nothing', (
      tester,
    ) async {
      final store = FakeStore();
      await pump(tester, store, 0);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guides of any size'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(r'Unlock for $8.99'));
      await tester.pumpAndSettle();

      expect(store.bought, [unlimitedProductId]);
      // The entry for the thing just bought is gone, which is how the app says
      // "unlocked" without a line of copy that would have needed translating
      // into another forty-eight languages to say it. The other purchase stays,
      // because it was not bought and is a different thing.
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Guides of any size'), findsNothing);
      expect(find.text('Places from a post'), findsOne);
      expect(find.text('Restore purchase'), findsOne);
    });

    testWidgets('an unlocked app stops advertising what it sold', (
      tester,
    ) async {
      // Nothing to sell somebody who has already paid -- for that.
      final store = FakeStore(restoreSucceeds: true);
      await pump(tester, store, 0);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore purchase'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Guides of any size'), findsNothing);
    });

    testWidgets('owning everything leaves nothing to buy or restore', (
      tester,
    ) async {
      // The end of the ladder. A menu still offering "Restore purchase" here
      // would be offering to look for something that cannot exist.
      final store = FakeStore(
        restoreSucceeds: true,
        owns: const {everythingProductId},
      );
      await pump(tester, store, 0);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore purchase'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Guides of any size'), findsNothing);
      expect(find.text('Places from a post'), findsNothing);
      expect(find.text('Restore purchase'), findsNothing);
    });
  });
}

/// Which product the sheet offers, and at which price.
///
/// The matrix is the point. Two of the three products differ by five pounds and
/// which one is right depends on both what is already owned and what the person
/// was trying to do, so getting it wrong means either charging somebody for
/// something they hold or offering them something that will not help.
void paywallMatrix() {
  group('the sheet sells what the moment calls for', () {
    testWidgets('the cap offers the cheaper unlock first, bundle second', (
      tester,
    ) async {
      // Somebody stopped by the three-place cap is served by the unlock. The
      // bundle appears underneath as the larger option, never in place of it.
      final store = FakeStore();
      await pump(tester, store, 5);

      await tester.tap(find.text('Make a guide (5)'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilledButton, r'Unlock for $8.99'),
        findsOne,
        reason: 'the answer to the question asked goes first',
      );
      expect(
        find.widgetWithText(OutlinedButton, r'Everything for $14.99'),
        findsOne,
      );
      // The extra five pounds has to say what it buys, or the larger button is
      // a trap.
      expect(find.text('Also reads places out of a shared post.'), findsOne);
      expect(store.buyCalls, 0);
    });

    testWidgets('a post offers the bundle, and no cheaper way past it', (
      tester,
    ) async {
      final store = FakeStore();
      await pump(tester, store, 0);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Places from a post'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilledButton, r'Everything for $14.99'),
        findsOne,
      );
      // Nothing cheaper grants it, so nothing cheaper is shown. Offering the
      // £8.99 unlock here would be selling something that cannot help.
      expect(find.textContaining(r'$8.99'), findsNothing);
      // And there is no partial reading of a post to fall back on.
      expect(find.textContaining('Save the first'), findsNothing);
      expect(store.buyCalls, 0);
    });

    testWidgets('an owner of the unlock is sold the difference', (
      tester,
    ) async {
      // Non-consumables have no upgrade mechanism, so the ladder is a second
      // product. Charging £14.99 to somebody holding £8.99 of it would be
      // charging twice for the same half.
      SharedPreferences.setMockInitialValues({'unlimited_unlocked': true});
      final store = FakeStore();
      await pump(tester, store, 0);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Guides of any size'), findsNothing);
      await tester.tap(find.text('Places from a post'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilledButton, r'Add posts for $9.99'),
        findsOne,
      );
      expect(find.textContaining(r'$14.99'), findsNothing);

      await tester.tap(find.text(r'Add posts for $9.99'));
      await tester.pumpAndSettle();
      expect(store.bought, [reelsUpgradeProductId]);
    });

    testWidgets('a restore that finds the wrong half does not open the rest', (
      tester,
    ) async {
      // The honest partial outcome. Restoring found a real purchase, and it is
      // not the one that was asked for -- so it says what came back, and the
      // post stays locked.
      final store = FakeStore(restoreSucceeds: true);
      await pump(tester, store, 0);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Places from a post'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore a previous purchase'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Restored'), findsOne);
      expect(store.buyCalls, 0, reason: 'a restore must never charge');
      // Still for sale, because it is still unheld.
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Places from a post'), findsOne);
      expect(find.text('Guides of any size'), findsNothing);
    });
  });
}
