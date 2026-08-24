import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the iOS share sheet left behind: a guide link, some screenshots, or both.
///
/// Both, because a share sheet does not promise one attachment of one kind, and
/// a shape that can only hold one would silently drop the other.
class SharedInput {
  const SharedInput({this.link, this.imagePaths = const []});

  /// An Apple Maps guide link, shared out of Maps.
  final String? link;

  /// Screenshots, already copied into a container this app can read. Paths, not
  /// bytes: the reader takes a path and there is no reason to hold images in
  /// memory across a process boundary.
  final List<String> imagePaths;

  bool get isEmpty => (link == null || link!.isEmpty) && imagePaths.isEmpty;
}

/// Things arriving from the iOS share sheet.
///
/// Wren appears in that sheet through a share extension. The extension runs in
/// its own process and is gone before the app opens, so it leaves what it was
/// given in a shared container and this collects it.
///
/// Collect, not read: the native side removes each item before returning it, so
/// a failed import cannot turn into the same share importing on every launch.
///
/// Returns null when there is nothing waiting, which is almost always, and also
/// when the App Group is missing — that has to be created by hand in the
/// developer portal, since the App Store Connect API has no such resource. A
/// missing group degrades to "nothing waiting" rather than to a broken app.
abstract class ShareInbox {
  Future<SharedInput?> take();
}

class MethodChannelShareInbox implements ShareInbox {
  const MethodChannelShareInbox();

  static const _channel = MethodChannel('littlebird/share');

  @override
  Future<SharedInput?> take() async {
    try {
      final result = await _channel.invokeMethod<Object?>('take');
      return _parse(result);
    } on MissingPluginException {
      // Not iOS, or an older build of the app shell. Not an error.
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// The parser, reachable from tests. Everything it guards against is a shape
  /// that can only otherwise be produced by a device.
  @visibleForTesting
  static SharedInput? debugParse(Object? result) => _parse(result);

  /// Accepts both shapes the native side has ever returned.
  ///
  /// Before screenshots could be shared it answered with a bare string, and a
  /// Dart build newer than the shell it is running in would otherwise throw on
  /// the cast rather than degrade. The two cannot normally drift — they ship in
  /// one binary — but they can during a partial local build, and a crash on
  /// launch is a poor way to learn that.
  static SharedInput? _parse(Object? result) {
    if (result == null) return null;

    if (result is String) {
      final link = result.trim();
      return link.isEmpty ? null : SharedInput(link: link);
    }

    if (result is Map) {
      final link = (result['link'] as String?)?.trim();
      final images = <String>[
        for (final p in (result['images'] as List? ?? const []))
          if (p is String && p.isNotEmpty) p,
      ];
      final input = SharedInput(
        link: (link == null || link.isEmpty) ? null : link,
        imagePaths: images,
      );
      return input.isEmpty ? null : input;
    }

    return null;
  }
}

/// Hands back whatever it was given, once. For tests and for platforms with no
/// share sheet.
class StubShareInbox implements ShareInbox {
  StubShareInbox([this._pending]);

  SharedInput? _pending;

  @override
  Future<SharedInput?> take() async {
    final v = _pending;
    _pending = null;
    return v;
  }
}
