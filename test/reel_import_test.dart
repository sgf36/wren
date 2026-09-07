import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wren/src/reel_import.dart';

/// Asking the Worker to read a post, and what the answers mean.
///
/// The failure taxonomy carries most of the weight here. Each reason shows
/// different copy, and collapsing two of them would mean telling somebody to
/// try screenshots when the real answer is that they have used their allowance
/// for the month — advice that cannot work, about a problem they do not have.
void main() {
  const auth = ReelAuth.comp('token');

  /// A sender that records what it was given and replies with what it is told.
  ({Sender send, List<Map<String, Object?>> sent}) replying(
    int status,
    Object body,
  ) {
    final sent = <Map<String, Object?>>[];
    Future<({int status, String body})> send(url, payload, timeout) async {
      sent.add(jsonDecode(payload) as Map<String, Object?>);
      return (status: status, body: body is String ? body : jsonEncode(body));
    }

    return (send: send, sent: sent);
  }

  group('which links are worth asking about', () {
    test('the platforms, in the forms their share sheets produce', () {
      for (final link in [
        'https://www.instagram.com/p/DcZzVx4Da6a/?stkn=abc',
        'https://www.instagram.com/reel/Cx1yZ_aBcDe/',
        'https://instagr.am/p/Cx1yZ_aBcDe/',
        'https://vm.tiktok.com/ZTdAbCdEf/',
        'https://www.tiktok.com/@someone/video/7234567890123456789',
        'https://youtu.be/dQw4w9WgXcQ',
        'https://m.youtube.com/shorts/dQw4w9WgXcQ',
      ]) {
        expect(isReelLink(link), isTrue, reason: link);
      }
    });

    test('and nothing else, including the links Wren already reads', () {
      for (final link in [
        // These must keep reaching the guide importer. Catching one here would
        // break a shipped feature to add a new one.
        'https://maps.apple.com/?ug=abc123',
        'https://maps.apple/ug/qai3oPE2QtpYfaNFg27D3C',
        // http is refused rather than upgraded: every host above serves https,
        // so plain http means something rewrote the link.
        'http://www.instagram.com/p/DcZzVx4Da6a/',
        'https://instagram.com.evil.example/p/abc',
        'https://example.com/reel/abc',
        'not a link',
        '',
      ]) {
        expect(isReelLink(link), isFalse, reason: link);
      }
    });

    test(
      'a link nobody can read is refused without asking the server',
      () async {
        var asked = false;
        await expectLater(
          readReel(
            'https://example.com/x',
            auth: auth,
            send: (url, body, timeout) async {
              asked = true;
              return (status: 200, body: '{}');
            },
          ),
          throwsA(
            isA<ReelFailed>().having(
              (ReelFailed e) => e.reason,
              'reason',
              ReelFailure.unsupported,
            ),
          ),
        );
        expect(
          asked,
          isFalse,
          reason: 'the server was asked, and paid, for free',
        );
      },
    );
  });

  group('pulling the link out of what was shared', () {
    test('a bare link is itself', () {
      expect(
        firstLinkIn('https://www.instagram.com/p/ABC/'),
        'https://www.instagram.com/p/ABC/',
      );
    });

    test('the link is found inside the sentence a platform wraps it in', () {
      // What TikTok's share sheet actually produces. Treating the whole string
      // as a URL fails, and fails as "that is not a link" — a confusing thing
      // to be told about a message that plainly contains one.
      expect(
        firstLinkIn(
          'Check out this video on TikTok '
          'https://vm.tiktok.com/ZTdAbCdEf/ Find TikTok on the app store',
        ),
        'https://vm.tiktok.com/ZTdAbCdEf/',
      );
    });

    test('a link at the end of a sentence loses the full stop', () {
      // Not the URL's. A trailing dot resolves to a path that does not exist.
      expect(
        firstLinkIn('look at https://youtu.be/dQw4w9WgXcQ.'),
        'https://youtu.be/dQw4w9WgXcQ',
      );
      expect(
        firstLinkIn('is it https://youtu.be/dQw4w9WgXcQ?'),
        'https://youtu.be/dQw4w9WgXcQ',
      );
    });

    test('a bracket only goes if nothing inside the link opened it', () {
      expect(
        firstLinkIn('(see https://example.com/a)'),
        'https://example.com/a',
      );
      // A real part of the address. Trimming it breaks the link.
      expect(
        firstLinkIn('https://en.wikipedia.org/wiki/Wren_(disambiguation)'),
        'https://en.wikipedia.org/wiki/Wren_(disambiguation)',
      );
    });

    test('the first is taken, not the best', () {
      // A share holds one link and whatever came with it. Choosing between
      // several would be guessing at which of two things somebody meant, with
      // nothing to guess from.
      expect(
        firstLinkIn('https://vm.tiktok.com/A/ and https://youtu.be/B'),
        'https://vm.tiktok.com/A/',
      );
    });

    test('text with no link at all is not a link', () {
      for (final text in ['', 'hello', 'instagram.com/p/ABC', 'ftp://x/y']) {
        expect(firstLinkIn(text), isNull, reason: text);
      }
    });
  });

  group('a reading', () {
    test('carries the places, the region and the allowance', () async {
      final http = replying(200, {
        'candidates': [
          {'name': 'Padella', 'city': 'London', 'kind': 'restaurant'},
          {'name': 'Bar Termini', 'city': 'London'},
        ],
        'regionHint': 'London',
        'quota': {'used': 12, 'limit': 250, 'resetsAt': 1800000000000},
      });
      final reading = await readReel(
        'https://www.instagram.com/p/ABC/',
        auth: auth,
        send: http.send,
      );

      expect(reading.candidates.map((c) => c.name), ['Padella', 'Bar Termini']);
      expect(reading.candidates.first.kind, 'restaurant');
      expect(reading.candidates.last.kind, isNull);
      expect(reading.regionHint, 'London');
      expect(reading.used, 12);
      expect(reading.limit, 250);
      expect(
        reading.resetsAt,
        DateTime.fromMillisecondsSinceEpoch(1800000000000),
      );
    });

    test('sends the link and the proof, and nothing else', () async {
      final http = replying(200, {
        'candidates': [
          {'name': 'A'},
        ],
      });
      await readReel(
        'https://www.instagram.com/p/ABC/',
        auth: const ReelAuth.play('purchase-token', 'com.example.reels'),
        send: http.send,
      );
      expect(http.sent.single, {
        'url': 'https://www.instagram.com/p/ABC/',
        'auth': {
          'kind': 'play',
          'purchaseToken': 'purchase-token',
          'productId': 'com.example.reels',
        },
      });
    });

    test('no region is a real answer, not a missing one', () async {
      // A post naming ten castles across seven countries has no single region,
      // and guessing one aims every lookup at the wrong place.
      final http = replying(200, {
        'candidates': [
          {'name': 'Ashford Castle', 'city': 'Ireland'},
          {'name': 'Amberley Castle', 'city': 'England'},
        ],
      });
      final reading = await readReel(
        'https://www.instagram.com/p/ABC/',
        auth: auth,
        send: http.send,
      );
      expect(reading.regionHint, isNull);
      expect(reading.candidates, hasLength(2));
    });

    test('rubbish among the candidates is dropped, not fatal', () async {
      final http = replying(200, {
        'candidates': [
          {'name': 'Padella'},
          {'name': '   '},
          {'city': 'London'},
          'not an object',
          null,
          {'name': 'Bar Termini'},
        ],
      });
      final reading = await readReel(
        'https://www.instagram.com/p/ABC/',
        auth: auth,
        send: http.send,
      );
      expect(reading.candidates.map((c) => c.name), ['Padella', 'Bar Termini']);
    });
  });

  group('failures keep their own identity', () {
    Future<ReelFailure> reasonFor(int status, Object body) async {
      final http = replying(status, body);
      try {
        await readReel(
          'https://www.instagram.com/p/ABC/',
          auth: auth,
          send: http.send,
        );
      } on ReelFailed catch (e) {
        return e.reason;
      }
      fail('did not fail');
    }

    test('each server code maps to its own reason', () async {
      expect(
        await reasonFor(402, {'error': 'not_entitled'}),
        ReelFailure.notEntitled,
      );
      expect(
        await reasonFor(429, {'error': 'quota_exceeded'}),
        ReelFailure.quotaExceeded,
      );
      expect(await reasonFor(409, {'error': 'busy'}), ReelFailure.busy);
      expect(
        await reasonFor(404, {'error': 'post_unavailable'}),
        ReelFailure.postUnavailable,
      );
      expect(
        await reasonFor(400, {'error': 'unsupported_host'}),
        ReelFailure.unsupported,
      );
    });

    test('an unknown code offers the advice that always helps', () async {
      // fetch_failed is the one whose copy points at screenshots, which is
      // useful whatever actually went wrong.
      expect(
        await reasonFor(503, {'error': 'something_new'}),
        ReelFailure.fetchFailed,
      );
      expect(
        await reasonFor(500, <String, Object?>{}),
        ReelFailure.fetchFailed,
      );
    });

    test('quota carries the date the allowance returns', () async {
      final http = replying(429, {
        'error': 'quota_exceeded',
        'quota': {'used': 250, 'limit': 250, 'resetsAt': 1800000000000},
      });
      try {
        await readReel(
          'https://www.instagram.com/p/ABC/',
          auth: auth,
          send: http.send,
        );
        fail('did not fail');
      } on ReelFailed catch (e) {
        expect(e.reason, ReelFailure.quotaExceeded);
        // The window rolls, so the copy says a date rather than "next month".
        expect(e.resetsAt, DateTime.fromMillisecondsSinceEpoch(1800000000000));
      }
    });

    test('a success holding no places is not a success', () async {
      // Spending the money and then showing an empty confirmation screen would
      // read as the app losing the answer.
      final http = replying(200, {'candidates': <Object>[]});
      await expectLater(
        readReel(
          'https://www.instagram.com/p/ABC/',
          auth: auth,
          send: http.send,
        ),
        throwsA(
          isA<ReelFailed>().having(
            (ReelFailed e) => e.reason,
            'reason',
            ReelFailure.nothingFound,
          ),
        ),
      );
    });

    test('a dead network and a mangled reply are both unreachable', () async {
      for (final send in <Sender>[
        (url, body, timeout) async => throw const SocketExceptionStub(),
        (url, body, timeout) async => (status: 200, body: 'not json at all'),
      ]) {
        await expectLater(
          readReel('https://www.instagram.com/p/ABC/', auth: auth, send: send),
          throwsA(
            isA<ReelFailed>().having(
              (ReelFailed e) => e.reason,
              'reason',
              ReelFailure.unreachable,
            ),
          ),
        );
      }
    });
  });
}

/// Stands in for anything dart:io throws when there is no network.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
