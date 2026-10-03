import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wren/src/comp_unlock.dart';

/// The nonce and device hash the Worker checks before granting Android's free
/// read.
///
/// The Worker accepts a Play Integrity token only when its nonce starts with
/// SHA-256 of the link being read and then SHA-256 of the phone's ANDROID_ID,
/// and the same device hash arrives beside it. If this side drifted -- a
/// different hash, padded base64, the standard alphabet, the halves swapped --
/// every Android free read would be refused and nothing would say why.
void main() {
  const link = 'https://www.instagram.com/reel/ABC123/';
  const androidId = '9774d56d682e549c';

  test('the device hash is unpadded base64url SHA-256 of ANDROID_ID', () async {
    final device = await deviceHash(androidId);
    final sha = await Sha256().hash(utf8.encode(androidId));
    expect(device, hasLength(43));
    expect(device, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(base64Url.decode(base64Url.normalize(device)), sha.bytes);
    expect(device, isNot(contains(androidId)));
  });

  test(
    'the nonce is link hash, then device hash, then 16 random bytes',
    () async {
      final device = await deviceHash(androidId);
      final nonce = await integrityNonce(link, device, random: Random(1));
      final raw = base64Url.decode(base64Url.normalize(nonce));
      final linkHash = await Sha256().hash(utf8.encode(link));
      expect(raw.length, 80);
      expect(raw.sublist(0, 32), linkHash.bytes);
      expect(
        raw.sublist(32, 64),
        base64Url.decode(base64Url.normalize(device)),
      );
    },
  );

  test(
    'the nonce is URL-safe, unpadded, and within Google\'s limits',
    () async {
      final device = await deviceHash(androidId);
      final nonce = await integrityNonce(link, device, random: Random(2));
      expect(nonce, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(nonce.length, inInclusiveRange(16, 500));
    },
  );

  test('two nonces for the same link and phone differ', () async {
    final device = await deviceHash(androidId);
    final a = await integrityNonce(link, device);
    final b = await integrityNonce(link, device);
    expect(a, isNot(b));
  });
}
