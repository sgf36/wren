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
/// 1. **On the first success.** It used to wait for a second publish, on
///    the theory that a first guide has not yet formed a view. Measured on
///    11 Oct 2026: about 25 iPhone installs a month, few of them publishing
///    twice, and one rating on the store in eight weeks. Waiting for a second
///    success meant almost nobody was ever asked. The first guide reaching
///    Maps is the moment the app has done the one thing it promised, and rule
///    2 still holds the ask until the user is back from seeing it there.
///
/// 2. **Never while the user is in Maps.** Publishing hands off to Apple Maps
///    and backgrounds Wren, so a prompt raised at that moment appears behind
///    another app and is spent without ever being seen. [recordSuccess] only
///    arms it; [maybeAsk] fires on the next return to Wren.
///
/// 4. **Once more, at the third success.** Added 19 Oct 2026, on Spencer's
///    call: someone who has sent a third guide has shown the app is useful to
///    them, which is the likeliest moment of all to get a rating. It needs only
///    a few days' gap from the first ask rather than the full quiet period;
///    after that second ask the quiet period applies as before. Apple's own
///    limit still caps what is actually shown.
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

  /// The menu's "Rate Wren": the store's own write-a-review page, opened
  /// because the user chose it. Not a prompt and not rationed: Apple allows a
  /// link like this (5.6.1 forbids custom *prompts*), and it is the one way to
  /// rate the app that does not depend on Apple deciding to show its prompt.
  Future<void> openStorePage();
}

class StoreReviewPrompt implements ReviewPrompt {
  const StoreReviewPrompt();

  static const _successes = 'review-successful-publishes';
  static const _armed = 'review-armed';
  static const _lastAsked = 'review-last-asked-ms';
  static const _asks = 'review-asks';

  /// Publishes before the first ask — see rule 1.
  static const _minSuccesses = 1;

  /// Publishes before the second ask — see rule 4.
  static const _secondAskAt = 3;

  /// The gap the second ask needs after the first: enough that it is not the
  /// same sitting, far short of [_quietDays].
  static const _secondAskDays = 3;

  /// Wren's App Store id; Android opens Wren's Play listing from its package.
  static const _appStoreId = '6802053382';

  /// A quiet period of our own, well inside Apple's. Someone who publishes
  /// every day should not meet this prompt every day, and Apple's own limit is
  /// invisible to us, so declining to ask is the only lever there is.
  static const _quietDays = 120;

  /// Whether an ask now would fall inside the gap the previous one earned:
  /// a few days after the first ask, [_quietDays] after any later one.
  @visibleForTesting
  static bool quiet({required int lastAskedMs, required int asks, int? nowMs}) {
    if (lastAskedMs == 0) return false;
    final days = asks == 1 ? _secondAskDays : _quietDays;
    final since =
        (nowMs ?? DateTime.now().millisecondsSinceEpoch) - lastAskedMs;
    return since < days * 86400 * 1000;
  }

  @override
  Future<void> recordSuccess() async {
    final prefs = await SharedPreferences.getInstance();
    final count = (prefs.getInt(_successes) ?? 0) + 1;
    await prefs.setInt(_successes, count);
    if (count == _minSuccesses || count >= _secondAskAt) {
      await prefs.setBool(_armed, true);
    }
  }

  @override
  Future<void> maybeAsk() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_armed) ?? false)) return;

    final last = prefs.getInt(_lastAsked) ?? 0;
    // Devices asked before the count existed (2.1.11) have a date and no
    // count; they have been asked exactly once.
    final asked = prefs.getInt(_asks) ?? (last == 0 ? 0 : 1);
    if (quiet(lastAskedMs: last, asks: asked)) {
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
    await prefs.setInt(_asks, asked + 1);
    await review.requestReview();
  }

  @override
  Future<void> openStorePage() =>
      InAppReview.instance.openStoreListing(appStoreId: _appStoreId);
}

/// Asks for nothing, ever.
///
/// **No longer used on either platform**, and kept for the record and for one
/// test. It used to be Android's, on the argument that the Android edition
/// hands a file to another map app rather than publishing an Apple Maps guide,
/// so the success this prompt is built around never happened there.
///
/// That was wrong in the same way the free-on-Android decision was wrong: the
/// hand-off *is* the Android success. A list reaching Organic Maps is exactly
/// as much a job finished as a guide reaching Apple Maps, and it is the moment
/// the user is most pleased with the app. Both platforms now arm on their own
/// success and ask on the next resume.
///
/// **The manifest check this comment used to demand has been done.** The
/// concern was real: `in_app_review` pulls in `com.google.android.play:review`
/// and `play-services-base`, whose manifests merge into the app's, and
/// permissions come from dependencies rather than from the manifest as
/// written. Measured 2026-08-28 against the built bundle now in Google's
/// review queue (versionCode 4), the review library contributes a
/// `PlayCoreDialogWrapperActivity` and **no `uses-permission` at all**. The
/// bundle asks for three: BILLING, INTERNET, and androidx's own
/// `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`, which is self-declared and
/// invisible on a listing. `DUMP` and `BIND_JOB_SERVICE` appear in that
/// manifest as `android:permission` attributes guarding components — read them
/// as requests and you will chase a permission the app never asks for.
class NoReviewPrompt implements ReviewPrompt {
  const NoReviewPrompt();

  @override
  Future<void> recordSuccess() async {}

  @override
  Future<void> maybeAsk() async {}

  @override
  Future<void> openStorePage() async {}
}

/// Records what it was asked to do, and shows nothing. For tests, and for any
/// platform where the system prompt does not exist.
@visibleForTesting
class FakeReviewPrompt implements ReviewPrompt {
  int successes = 0;
  int asks = 0;
  int storePageOpens = 0;

  @override
  Future<void> recordSuccess() async => successes++;

  @override
  Future<void> maybeAsk() async => asks++;

  @override
  Future<void> openStorePage() async => storePageOpens++;
}
