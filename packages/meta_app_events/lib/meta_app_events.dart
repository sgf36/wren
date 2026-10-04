/// Wren's bridge to Meta's SDK on iPhone. The SDK reports installs, opens and
/// purchases by itself; this only exposes Apple's tracking question.
///
/// iOS only by design: the plugin declares no Android platform, so the
/// Android build never links Meta's SDK and its Play listing and Data safety
/// answers are unchanged. Every call here is a no-op elsewhere.
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class MetaAppEvents {
  MetaAppEvents._();

  static const _channel = MethodChannel('wren/meta_app_events');

  /// Whether Apple has not yet asked this install the tracking question.
  static Future<bool> trackingUndetermined() async {
    if (!Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('trackingUndetermined') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Shows Apple's tracking prompt if it has never been answered. Returns
  /// whether it was shown. Never throws.
  static Future<bool> requestTracking() async {
    if (!Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('requestTracking') ?? false;
    } catch (_) {
      return false;
    }
  }
}
