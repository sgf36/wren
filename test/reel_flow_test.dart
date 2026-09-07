import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wren/main.dart';
import 'package:wren/src/entitlement.dart';
import 'package:wren/src/guide_link.dart';
import 'package:wren/src/reel_import.dart';
import 'package:wren/src/resolver.dart';
import 'package:wren/src/share_inbox.dart';

import 'harness.dart';
import 'import_flow_test.dart' show addFrom;
import 'paywall_test.dart' show FakeStore;

/// Sharing a post, from the paste box to the list.
///
/// The reading itself is tested in reel_import_test.dart against a fake server.
/// What is tested here is everything around it: that a post link goes to the
/// reader rather than the guide parser, that nothing is sent before the
/// purchase is held, that each failure says its own sentence, and that the
/// names come out into the same list a screenshot's names do.
///
/// Every test pins `canMakeGuides` rather than trusting the platform, because
/// the suite runs on a desktop where neither branch is the default.

/// A resolver that finds whatever it is asked for, so the assertions can be
/// about the reel path rather than about matching.
class FindsAnything extends PlaceResolver {
  final List<String> asked = [];

  @override
  Future<List<PlaceMatch>> resolve(String query, {Region? region}) async {
    asked.add(query);
    return [
      PlaceMatch(
        // A different identifier per query, because the list drops a match it
        // already holds — so one shared id would silently make every place
        // after the first look like a duplicate.
        id: PlaceId.parse('I43FA2531C5B5D6${asked.length.toRadixString(16)}5'),
        name: query,
        address: 'Somewhere',
        // A category, because usable() rejects a match without one: MapKit
        // returns points of interest and plain addresses through the same
        // call, and only the first carries a category.
        category: 'Restaurant',
        lat: 51.5,
        lon: -0.12,
      ),
    ];
  }

  @override
  Future<PlaceLookup> lookup(List<PlaceId> ids) async =>
      PlaceLookup(failed: ids.toSet());

  @override
  Future<Region?> locate(String query) async =>
      Region(name: query, lat: 51.5, lon: -0.12);
}

/// Stands in for the Worker. Records what it was sent.
({Sender send, List<Map<String, Object?>> sent}) worker(
  int status,
  Object body,
) {
  final sent = <Map<String, Object?>>[];
  Future<({int status, String body})> send(url, payload, timeout) async {
    sent.add(jsonDecode(payload) as Map<String, Object?>);
    return (status: status, body: jsonEncode(body));
  }

  return (send: send, sent: sent);
}

const reel = 'https://www.instagram.com/reel/Cx1yZ_aBcDe/';

/// The receipt a bought reel product leaves behind, in the shape the app
/// stores it. Seeded rather than bought, because what is under test here is
/// what happens after the purchase, and paywall_test covers the purchase.
Map<String, Object> entitled({String store = 'appstore'}) => {
  'owned_products': [everythingProductId],
  'reel_purchase_proof': jsonEncode({
    'productId': everythingProductId,
    'proof': 'signed-transaction',
    'store': store,
  }),
};

Future<void> pump(
  WidgetTester tester, {
  required Sender send,
  PlaceResolver? resolver,
  FakeStore? store,
  ShareInbox? shareInbox,
  bool canMakeGuides = true,
}) async {
  await tester.pumpWidget(
    app(
      CapturePage(
        reelSender: send,
        resolver: resolver ?? FindsAnything(),
        store: store ?? FakeStore(),
        shareInbox: shareInbox,
        canMakeGuides: canMakeGuides,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> paste(
  WidgetTester tester,
  String text, {
  String from = 'From a link',
}) async {
  await addFrom(tester, from);
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.text('Read it'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('a post reaches the reader, and a guide still reaches the parser', () {
    testWidgets('an unentitled post raises the paywall and sends nothing', (
      tester,
    ) async {
      // The order that matters. Every call costs real money, so the purchase
      // is checked before the request rather than the server refusing it after
      // the vendor has already been paid.
      final http = worker(200, {
        'candidates': [
          {'name': 'Padella'},
        ],
      });
      await pump(tester, send: http.send);
      await paste(tester, reel);

      expect(find.text('Places from a post'), findsOne);
      expect(
        http.sent,
        isEmpty,
        reason:
            'the server was asked, and paid, for '
            'somebody who had not bought it',
      );
    });

    testWidgets('a guide link is not mistaken for a post', (tester) async {
      // The two arrive through the same box. Catching a guide here would break
      // a shipped feature to add a new one.
      final http = worker(200, {'candidates': <Object>[]});
      SharedPreferences.setMockInitialValues(entitled());
      await pump(tester, send: http.send);
      await paste(tester, 'https://maps.apple.com/?ug=nonsense');

      expect(http.sent, isEmpty);
      expect(find.text('Places from a post'), findsNothing);
    });

    testWidgets('a platform Wren cannot read still gets the old advice', (
      tester,
    ) async {
      // Facebook and X are not read, and the sentence about screenshots is
      // still the true answer for them. It is said to fewer people now.
      final http = worker(200, {'candidates': <Object>[]});
      SharedPreferences.setMockInitialValues(entitled());
      await pump(tester, send: http.send);
      await paste(tester, 'https://www.facebook.com/reel/123456');

      expect(http.sent, isEmpty);
      expect(find.textContaining('Wren reads screenshots'), findsOne);
    });
  });

  group('a share arrives from another app', () {
    testWidgets('the link is pulled out of the sentence around it', (
      tester,
    ) async {
      // What TikTok's share sheet actually sends. Handing the whole string to
      // the importer answers "that is not a link", about a message that
      // plainly contains one.
      final http = worker(200, {
        'candidates': [
          {'name': 'Padella'},
        ],
      });
      SharedPreferences.setMockInitialValues(entitled());
      await pump(
        tester,
        send: http.send,
        shareInbox: StubShareInbox(
          const SharedInput(
            link:
                'Check out this video on TikTok '
                'https://vm.tiktok.com/ZTdAbCdEf/ Find TikTok on the app store',
          ),
        ),
      );

      expect(http.sent.single['url'], 'https://vm.tiktok.com/ZTdAbCdEf/');
    });

    testWidgets('a share nobody has paid for costs nothing', (tester) async {
      // The share sheet is open to everyone — the extension has no idea what
      // was bought — so this is the common case, not an edge one.
      final http = worker(200, {'candidates': <Object>[]});
      await pump(
        tester,
        send: http.send,
        shareInbox: StubShareInbox(const SharedInput(link: reel)),
      );

      expect(http.sent, isEmpty);
      expect(find.text('Places from a post'), findsOne);
    });

    testWidgets('shared text holding no link is still not a link', (
      tester,
    ) async {
      final http = worker(200, {'candidates': <Object>[]});
      SharedPreferences.setMockInitialValues(entitled());
      await pump(
        tester,
        send: http.send,
        shareInbox: StubShareInbox(const SharedInput(link: 'just some words')),
      );

      expect(http.sent, isEmpty);
      expect(find.textContaining('is not'), findsWidgets);
    });
  });

  group('a reading becomes a list', () {
    testWidgets('the places land, the city is confirmed, the allowance shows', (
      tester,
    ) async {
      final resolver = FindsAnything();
      final http = worker(200, {
        'candidates': [
          {'name': 'Padella', 'city': 'London', 'kind': 'restaurant'},
          {'name': 'Bar Termini', 'city': 'London'},
        ],
        'regionHint': 'London',
        'quota': {'used': 12, 'limit': 250},
      });
      SharedPreferences.setMockInitialValues(entitled());
      await pump(tester, send: http.send, resolver: resolver);
      await paste(tester, reel);

      // The same confirmation a screenshot import raises, filled in with what
      // the post said. A wrong region aims every lookup at the wrong city, so
      // it is confirmed rather than assumed — for posts exactly as for shots.
      expect(find.text('London'), findsWidgets);
      await tester.tap(find.textContaining('Find places'));
      await tester.pumpAndSettle();

      // The city travels with the name into the lookup: "Padella, London"
      // finds the right one where "Padella" alone finds a chain.
      expect(resolver.asked.first, 'Padella, London');
      expect(find.text('Padella, London'), findsOne);
      expect(find.text('Bar Termini, London'), findsOne);
      // Said after each reading rather than sprung on the user when it runs out.
      expect(find.textContaining('238 posts left this month'), findsOne);
    });

    testWidgets('the proof goes to the server, and nothing else does', (
      tester,
    ) async {
      // The app is not trusted and does not need to be: the server verifies
      // this receipt against Apple's certificate chain itself.
      final http = worker(200, {
        'candidates': [
          {'name': 'Padella'},
        ],
      });
      SharedPreferences.setMockInitialValues(entitled());
      await pump(tester, send: http.send);
      await paste(tester, reel);

      expect(http.sent.single, {
        'url': reel,
        'auth': {'kind': 'appstore', 'jws': 'signed-transaction'},
      });
    });

    testWidgets('an Android receipt is sent as a Play purchase', (
      tester,
    ) async {
      // Two different objects verified against two different authorities, and
      // the device that took the payment is the one that knows which.
      final http = worker(200, {
        'candidates': [
          {'name': 'Padella'},
        ],
      });
      SharedPreferences.setMockInitialValues(entitled(store: 'play'));
      await pump(tester, send: http.send, canMakeGuides: false);
      await paste(tester, reel, from: 'From a post');

      expect(http.sent.single['auth'], {
        'kind': 'play',
        'purchaseToken': 'signed-transaction',
        'productId': everythingProductId,
      });
    });
  });

  group('each failure says its own sentence', () {
    Future<void> failing(
      WidgetTester tester,
      int status,
      Map<String, Object?> body,
    ) async {
      SharedPreferences.setMockInitialValues(entitled());
      await pump(tester, send: worker(status, body).send);
      await paste(tester, reel);
    }

    testWidgets('the allowance names the day it comes back', (tester) async {
      // The window rolls over the trailing thirty days rather than resetting
      // on the first, so "next month" would be wrong about half the time.
      await failing(tester, 429, {
        'error': 'quota_exceeded',
        'quota': {'resetsAt': 1800000000000},
      });
      expect(
        find.textContaining('That is all the posts for this month'),
        findsOne,
      );
      // The date itself is formatted by the platform, because "15 January" and
      // "January 15" are both correct and which is right is not a decision
      // this app should be making. So the year is what is asserted.
      expect(find.textContaining('2027'), findsOne);
    });

    testWidgets('an allowance with no date says so vaguely, not falsely', (
      tester,
    ) async {
      await failing(tester, 429, {'error': 'quota_exceeded'});
      expect(find.textContaining('a few weeks'), findsOne);
    });

    testWidgets('an unreadable post offers screenshots', (tester) async {
      await failing(tester, 502, {'error': 'fetch_failed'});
      expect(find.textContaining('Screenshot it'), findsOne);
    });

    testWidgets('a private post does not offer screenshots', (tester) async {
      // Somebody who cannot open a post cannot screenshot it either, so the
      // advice that helps everywhere else is useless exactly here.
      await failing(tester, 404, {'error': 'post_unavailable'});
      expect(find.textContaining('may be private'), findsOne);
      expect(find.textContaining('Screenshot it'), findsNothing);
    });

    testWidgets('a post with no places in it is not a fault', (tester) async {
      await failing(tester, 200, {'candidates': <Object>[]});
      expect(find.textContaining('looked like a place'), findsOne);
    });

    testWidgets('a dead network says the allowance was not spent', (
      tester,
    ) async {
      // The allowance is the thing people are protective of, and a failed
      // attempt does not touch it.
      SharedPreferences.setMockInitialValues(entitled());
      await pump(
        tester,
        send: (url, body, timeout) async => throw const _NoNetwork(),
      );
      await paste(tester, reel);
      expect(find.textContaining('Nothing was charged'), findsOne);
    });

    testWidgets('entitled with no receipt is told to restore', (tester) async {
      // A purchase made before this version existed: real, and unprovable,
      // because the receipt was never kept. Restoring asks for one.
      SharedPreferences.setMockInitialValues({
        'owned_products': [everythingProductId],
      });
      await pump(
        tester,
        send: (url, body, timeout) async {
          fail('the server was asked without a receipt to show it');
        },
      );
      await paste(tester, reel);
      expect(find.textContaining('Restore purchase'), findsOne);
    });
  });
}

class _NoNetwork implements Exception {
  const _NoNetwork();
}
