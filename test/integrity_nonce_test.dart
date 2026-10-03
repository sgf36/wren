import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wren/src/comp_unlock.dart';

/// The nonce the Worker checks before granting Android's free read.
///
/// The Worker accepts a Play Integrity token only when the first 32 bytes of
/// its nonce are SHA-256 of the link being read. If this side drifted -- a
/// different hash, padded base64, standard rather than URL-safe alphabet --
/// every Android free read would be refused and nothing would say why.
void main() {
  const link = 'https://www.instagram.com/reel/ABC123/';

  test('the nonce starts with SHA-256 of the link', () async {
    final nonce = await integrityNonce(link, random: Random(1));
    final raw = base64Url.decode(base64Url.normalize(nonce));
    final hash = await Sha256().hash(utf8.encode(link));
    expect(raw.length, 48);
    expect(raw.sublist(0, 32), hash.bytes);
  });

  test(
    'the nonce is URL-safe, unpadded, and within Google\'s limits',
    () async {
      final nonce = await integrityNonce(link, random: Random(2));
      expect(nonce, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(nonce.length, inInclusiveRange(16, 500));
    },
  );

  test('two nonces for the same link differ', () async {
    // The Worker keys a free read on the nonce, so a repeat would make a
    // second share of the same post look like a replay of the first.
    final a = await integrityNonce(link);
    final b = await integrityNonce(link);
    expect(a, isNot(b));
  });
}
