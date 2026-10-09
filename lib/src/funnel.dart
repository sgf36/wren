/// Anonymous counts of the steps between installing Wren and buying an unlock.
///
/// Why it exists (9 Oct 2026): Wren had downloads and no purchases, and nothing
/// said where people stopped -- before reaching a paywall, at the price, or at
/// a purchase that failed. Each step now adds one to a daily tally on
/// wren.spencerfields.com/f/, which the private dashboard reads.
///
/// What is sent is the step, an optional detail from a fixed list (which
/// paywall, which product, which kind of import), the platform, the app version
/// and the language. Nothing identifies a person or a phone: no id, no
/// advertising identifier, and nothing stored on the device to recognise it
/// again. The server keeps the counts, not the requests, and not the address
/// they came from. So it is not tracking in Apple's sense and needs no consent
/// prompt; it is declared in the privacy policy and the App Store label.
///
/// Counts are of events, not of people: one person opening the paywall twice
/// is two. Without an identifier that is the honest unit, and it is enough to
/// see which step loses everybody.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The app's version, sent with each event so a change can be judged by the
/// release that carried it. Kept equal to pubspec.yaml by
/// test/funnel_test.dart, so it cannot quietly go stale.
const String appVersion = '2.1.9';

/// The steps, and the only details each may carry. The server accepts nothing
/// else, so a typo here is a test failure rather than a new row nobody reads.
enum FunnelStep {
  /// First launch on this install: the welcome sheet was shown.
  firstOpen('first_open'),

  /// An import began: detail is the source.
  importStarted('import_started'),

  /// A post was read: detail is free or paid.
  reelRead('reel_read'),

  /// The purchase sheet opened: detail is places, combine or reels.
  paywallShown('paywall_shown'),

  /// A buy button was tapped: detail is the product.
  buyTapped('buy_tapped'),

  /// The store confirmed a purchase: detail is the product.
  purchased('purchased'),

  /// The store did not complete it (cancelled or failed): detail is the product.
  purchaseFailed('purchase_failed'),

  /// Restore was tapped on the sheet.
  restoreTapped('restore_tapped'),

  /// Chose to save the free number of places instead of buying.
  savedFreeInstead('saved_free_instead'),

  /// The sheet was dismissed without a choice.
  paywallDismissed('paywall_dismissed'),

  /// A guide was saved to Maps, or places sent to another map app.
  guideSaved('guide_saved');

  const FunnelStep(this.wire);

  /// The name on the wire and in the tally.
  final String wire;
}

/// Records funnel steps. Injectable so tests and screenshot runs send nothing.
abstract class Funnel {
  const Funnel();

  /// Fire and forget. Never throws and never delays the caller: a lost count
  /// must not cost the user anything.
  void record(FunnelStep step, {String? detail});
}

/// Sends nothing. For tests, screenshot scenes and anything automated.
class NoFunnel extends Funnel {
  const NoFunnel();

  @override
  void record(FunnelStep step, {String? detail}) {}
}

/// Posts each step to the tally.
class HttpFunnel extends Funnel {
  HttpFunnel({
    this.endpoint = 'https://wren.spencerfields.com/f/',
    required this.platform,
    required this.language,
  });

  final String endpoint;

  /// 'ios' or 'android'.
  final String platform;

  /// Language code only ('ja', 'pt'), never a region: the country a person is
  /// in is not needed to count steps.
  final String Function() language;

  @override
  void record(FunnelStep step, {String? detail}) {
    unawaited(_send(step, detail).catchError((Object _) {}));
  }

  Future<void> _send(FunnelStep step, String? detail) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client
          .postUrl(Uri.parse(endpoint))
          .timeout(const Duration(seconds: 5));
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'e': step.wire,
          'd': ?detail,
          'p': platform,
          'v': appVersion,
          'l': language(),
        }),
      );
      final res = await req.close().timeout(const Duration(seconds: 5));
      await res.drain<void>();
    } finally {
      client.close(force: true);
    }
  }
}
