import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Asking for a rating, at the one moment worth asking.
///
/// Wren shipped with nothing that ever asked, and an app with no ratings is
/// penalised twice: the count feeds App Store search ranking, and it is the
/// first thing a visitor's eye lands on. An app with no ratings reads as an app
/// nobody uses.
///
/// Three rules, each of which exists because the obvious implementation gets it
/// wrong:
///
/// 1. **Never on the first success.** Somebody whose first guide has just
///    appeared has not yet formed a view; asking then harvests a shrug. The ask
///    waits for a second publish, by which point the app has been chosen twice.
///
/// 2. **Never while the user is in Maps.** Publishing hands off to Apple Maps
///    and backgrounds Wren, so a prompt raised at that moment appears behind
///    another app and is spent without ever being seen. [recordSuccess] only
///    arms it; [maybeAsk] fires on the next return to Wren.
///
/// 3. **Never mid-split.** A guide over the size cap is handed over one link at
///    a time, and the job is not done until the last one. Asking between them
///    interrupts a task the user is in the middle of.
///
/// Apple caps the system prompt at three appearances a year per device and
/// silently ignores the rest, so the count kept here is about not wasting those
/// three rather than about rate limiting. Nothing here can tell whether the
/// prompt was shown, or what was said — Apple deliberately reports neither.
abstract class ReviewPrompt {
  /// A guide reached Apple Maps in full. Arms the ask; never shows anything.
  Future<void> recordSuccess();

  /// Called when Wren comes back to the foreground. Shows the system prompt if
  /// this device has earned one and has not been asked recently.
  Future<void> maybeAsk();
}

class StoreReviewPrompt implements ReviewPrompt {
  const StoreReviewPrompt();

  static const _successes = 'review-successful-publishes';
  static const _armed = 'review-armed';
  static const _lastAsked = 'review-last-asked-ms';

  /// Publishes before the first ask. Two, not one — see rule 1.
  static const _minSuccesses = 2;

  /// A quiet period of our own, well inside Apple's. Someone who publishes
  /// every day should not meet this prompt every day, and Apple's own limit is
  /// invisible to us, so declining to ask is the only lever there is.
  static const _quietDays = 120;

  @override
  Future<void> recordSuccess() async {
    final prefs = await SharedPreferences.getInstance();
    final count = (prefs.getInt(_successes) ?? 0) + 1;
    await prefs.setInt(_successes, count);
    if (count >= _minSuccesses) await prefs.setBool(_armed, true);
  }

  @override
  Future<void> maybeAsk() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_armed) ?? false)) return;

    final last = prefs.getInt(_lastAsked) ?? 0;
    final since = DateTime.now().millisecondsSinceEpoch - last;
    if (last != 0 && since < _quietDays * 86400 * 1000) {
      // Still in the quiet period. Disarm rather than leave it pending, or the
      // ask lands the instant the period ends, months after the publish that
      // earned it and with no connection to anything the user just did.
      await prefs.setBool(_armed, false);
      return;
    }

    // Disarmed before the prompt rather than after. Apple's call can take a
    // moment and the user may background the app during it; leaving it armed
    // would ask again on the next resume.
    await prefs.setBool(_armed, false);

    final review = InAppReview.instance;
    if (!await review.isAvailable()) return;
    await prefs.setInt(_lastAsked, DateTime.now().millisecondsSinceEpoch);
    await review.requestReview();
  }
}

/// Asks for nothing, ever.
///
/// Used on Android, where there is no moment to ask about: the Android edition
/// hands a file to another map app rather than publishing an Apple Maps guide,
/// so the success this prompt is built around never happens there. Wiring the
/// real one up anyway would put a prompt behind a door that does not open.
///
/// It does **not** remove `in_app_review` from the Android build. That package
/// pulls in `com.google.android.play:review` and `play-services-base`, whose
/// manifests merge into the app's — and permissions come from dependencies, not
/// from the manifest as written. Wren already ships BILLING and INTERNET it
/// never asked for by this route. Before the Play listing goes live, read the
/// **built** manifest rather than the source and check nothing new arrived.
class NoReviewPrompt implements ReviewPrompt {
  const NoReviewPrompt();

  @override
  Future<void> recordSuccess() async {}

  @override
  Future<void> maybeAsk() async {}
}

/// Records what it was asked to do, and shows nothing. For tests, and for any
/// platform where the system prompt does not exist.
@visibleForTesting
class FakeReviewPrompt implements ReviewPrompt {
  int successes = 0;
  int asks = 0;

  @override
  Future<void> recordSuccess() async => successes++;

  @override
  Future<void> maybeAsk() async => asks++;
}
