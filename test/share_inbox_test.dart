import 'package:flutter_test/flutter_test.dart';
import 'package:wren/src/share_inbox.dart';

/// The handoff from the iOS share sheet.
///
/// Wren appears in that sheet through a share extension, which runs in its own
/// process and is gone before the app opens. It leaves what it was given in the
/// App Group container and the app collects it.
///
/// The failure worth designing against is not a missing share — it is one that
/// never goes away. Read it without removing it and every launch imports the
/// same guide again, producing a duplicate in Apple Maps each time, which is
/// precisely the thing this app exists to avoid. So the contract is *take*, not
/// read: the native side removes each item as it hands it over, and this pins
/// that behaviour on the stub every other test uses.
void main() {
  // A MethodChannel needs the services binding, even from a plain test.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a shared link is handed over exactly once', () async {
    final inbox = StubShareInbox(
      const SharedInput(link: 'https://maps.apple/ug/IgmWnPF.ByS5J5gZk36cDB'),
    );
    expect((await inbox.take())!.link, contains('maps.apple/ug/'));
    // Second call: nothing left. An import loop starts here if this ever fails.
    expect(await inbox.take(), isNull);
    expect(await inbox.take(), isNull);
  });

  test('shared screenshots are handed over exactly once', () async {
    final inbox = StubShareInbox(
      const SharedInput(imagePaths: ['/tmp/1-0.png', '/tmp/1-1.png']),
    );
    final taken = await inbox.take();
    expect(taken!.imagePaths, hasLength(2));
    expect(taken.link, isNull);
    expect(await inbox.take(), isNull);
  });

  test('an empty inbox is the normal case, not an error', () async {
    final inbox = StubShareInbox();
    expect(await inbox.take(), isNull);
  });

  test('the channel implementation degrades to nothing waiting', () async {
    // No plugin in a test binding, which is also what a missing App Group looks
    // like on a device. Either way the answer is "nothing", never an exception:
    // the paste and picker routes still work and a share extension the user has
    // not set up must not break the app they have.
    const inbox = MethodChannelShareInbox();
    expect(await inbox.take(), isNull);
  });

  group('what the native side sends', () {
    // The parser is exercised directly because the alternative is a device.
    // Each case here is a shape iOS has actually produced or could produce, and
    // the ones that matter are the degenerate ones: a share that arrives empty
    // must read as "nothing waiting" rather than as a share of nothing, which
    // would open the reader on an empty list.

    test('a bare string is still understood', () {
      // What the shell returned before screenshots could be shared. Dart and
      // Swift ship in one binary so they cannot normally drift, but a partial
      // local build can, and a crash on launch is a poor way to learn that.
      final parsed = MethodChannelShareInbox.debugParse(
        'https://maps.apple/ug/x',
      );
      expect(parsed!.link, 'https://maps.apple/ug/x');
      expect(parsed.imagePaths, isEmpty);
    });

    test('a map carries both a link and images', () {
      final parsed = MethodChannelShareInbox.debugParse({
        'link': 'https://maps.apple/ug/x',
        'images': ['/tmp/a.png', '/tmp/b.png'],
      });
      expect(parsed!.link, 'https://maps.apple/ug/x');
      expect(parsed.imagePaths, ['/tmp/a.png', '/tmp/b.png']);
    });

    test('a null link with images is images', () {
      final parsed = MethodChannelShareInbox.debugParse({
        'link': null,
        'images': ['/tmp/a.png'],
      });
      expect(parsed!.link, isNull);
      expect(parsed.imagePaths, ['/tmp/a.png']);
    });

    test('an empty map is nothing waiting, not an empty share', () {
      expect(
        MethodChannelShareInbox.debugParse({'link': null, 'images': []}),
        isNull,
      );
      expect(MethodChannelShareInbox.debugParse({}), isNull);
      expect(MethodChannelShareInbox.debugParse(''), isNull);
      expect(MethodChannelShareInbox.debugParse(null), isNull);
    });

    test('rubbish in the images list is dropped, not carried', () {
      // A platform channel hands back Object?, so the list is not typed until
      // it is checked. A null in it used to be a cast error on launch.
      final parsed = MethodChannelShareInbox.debugParse({
        'link': null,
        'images': ['/tmp/a.png', null, '', 7],
      });
      expect(parsed!.imagePaths, ['/tmp/a.png']);
    });
  });
}
