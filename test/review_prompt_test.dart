import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wren/src/review_prompt.dart';

/// When Wren asks for a rating.
///
/// Apple reports neither whether its prompt appeared nor what was said, so the
/// only thing that can be asserted is when Wren *asks* — and the interesting
/// cases are all the ones where it must not.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<bool> armed() async =>
      (await SharedPreferences.getInstance()).getBool('review-armed') ?? false;

  test('nothing is armed before a success', () async {
    expect(await armed(), isFalse);
  });

  test('the first success arms the ask', () async {
    // Since 12 Oct 2026: waiting for a second publish meant almost nobody was
    // ever asked (one rating in eight weeks). See rule 1 in review_prompt.dart.
    const prompt = StoreReviewPrompt();
    await prompt.recordSuccess();
    expect(await armed(), isTrue);
  });

  test('recording a success never shows anything by itself', () async {
    // The whole point of the two-step: publishing hands off to Apple Maps and
    // backgrounds Wren, so a prompt raised here would appear behind another app
    // and be spent without being seen.
    const prompt = StoreReviewPrompt();
    await prompt.recordSuccess();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('review-last-asked-ms'), isNull);
  });

  test('an unearned resume asks for nothing', () async {
    const prompt = StoreReviewPrompt();
    await prompt.maybeAsk();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('review-last-asked-ms'), isNull);
  });

  test('a recent ask disarms rather than queueing', () async {
    // The trap this pins: leaving it armed through the quiet period means the
    // ask fires the instant the period ends, months after the publish that
    // earned it and attached to nothing the user just did.
    SharedPreferences.setMockInitialValues({
      'review-armed': true,
      'review-last-asked-ms': DateTime.now().millisecondsSinceEpoch,
    });
    await const StoreReviewPrompt().maybeAsk();
    expect(await armed(), isFalse);
  });

  test('asking disarms, so a resume during it cannot ask twice', () async {
    SharedPreferences.setMockInitialValues({'review-armed': true});
    // isAvailable() is false in a test binding, so this stops before Apple's
    // call — which is exactly the path where the flag must already be down.
    await const StoreReviewPrompt().maybeAsk();
    expect(await armed(), isFalse);
  });

  test('the Android build asks for nothing at all', () async {
    // Not merely disabled: there is no event to attach it to, because the
    // Android edition hands a file to another map app rather than publishing an
    // Apple Maps guide. Recording a success there must still arm nothing.
    const prompt = NoReviewPrompt();
    await prompt.recordSuccess();
    await prompt.recordSuccess();
    await prompt.maybeAsk();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('review-armed'), isNull);
    expect(prefs.getInt('review-last-asked-ms'), isNull);
  });

  test('the fake records without showing', () async {
    final fake = FakeReviewPrompt();
    await fake.recordSuccess();
    await fake.maybeAsk();
    expect(fake.successes, 1);
    expect(fake.asks, 1);
  });
}
