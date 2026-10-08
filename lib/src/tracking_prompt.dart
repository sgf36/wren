import 'package:meta_app_events/meta_app_events.dart';

/// Apple's App Tracking Transparency question, asked as soon as Wren is first
/// on screen.
///
/// Why Wren asks at all, decided 4 October 2026: Meta's SDK (see
/// packages/meta_app_events) declares in its privacy manifest that it tracks,
/// and App Review guideline 5.1.2(i) requires the system prompt for that. The
/// answer changes nothing in Wren: "Ask App Not to Track" leaves every feature
/// as it was, and Meta then measures adverts only in aggregate. TikTok's SDK,
/// added 8 Oct 2026, sits behind the same prompt and no longer shows its own.
///
/// Why at first launch rather than after the first guide (the first design):
/// the events the adverts are judged on happen early. The install is reported
/// on the first launch, and a purchase can come before any guide reaches Maps,
/// because the paywall sits in front of publishing. Asked later, the prompt
/// would arrive after both, too late to matter for either.
///
/// Apple shows the prompt only to an app in the foreground, so it is asked a
/// moment after the first frame, and again on any later return to the app for
/// as long as it has never been answered. Apple itself never shows it twice.
abstract class TrackingPrompt {
  /// Asks if the question has never been answered. Returns whether the system
  /// prompt was shown, so the caller can hold the review prompt back.
  Future<bool> maybeAsk();
}

class AppleTrackingPrompt implements TrackingPrompt {
  const AppleTrackingPrompt();

  @override
  Future<bool> maybeAsk() async {
    if (!await MetaAppEvents.trackingUndetermined()) return false;
    return MetaAppEvents.requestTracking();
  }
}

/// Never asks. For tests, and for any build without the advertising SDKs.
class NoTrackingPrompt implements TrackingPrompt {
  const NoTrackingPrompt();

  @override
  Future<bool> maybeAsk() async => false;
}
