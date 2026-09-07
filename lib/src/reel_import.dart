/// Turning a shared reel or post into place names.
///
/// The app cannot do this itself. What Instagram, TikTok and YouTube put in a
/// share sheet is a URL and never the media, so reading what is written across
/// a reel's frames — or said out loud in it — means fetching the video from
/// somewhere, and that needs a vendor, a key, and a network posture that has no
/// business inside a shipped app.
///
/// So the server answers with *names*, and this file's whole job is to ask. The
/// names then go through exactly the path a screenshot's names already take:
/// the same resolver, the same region hint, the same confirmation screen. That
/// screen is where the app's accuracy actually comes from, and keeping the
/// resolution on the device is also what keeps this inside Apple's rules —
/// Wren never receives the media, never stores it, and never shows it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Where the Worker lives. Overridable so a build can be pointed at a local
/// one, mirroring `WREN_CODES_URL` in comp_unlock.dart.
const String reelsEndpoint = String.fromEnvironment(
  'WREN_REELS_URL',
  defaultValue: 'https://wren-reels.sgf36.workers.dev',
);

/// Hosts whose links this feature can read.
///
/// Checked before anything is sent, so that a link Wren cannot do anything with
/// costs nothing and answers instantly. The server keeps the same list and is
/// the one that matters — this copy is a courtesy, not a security boundary, and
/// it is deliberately the shorter of the two questions: whether the host is one
/// of these, not whether that particular post can be read.
const Set<String> reelHosts = {
  'instagram.com',
  'www.instagram.com',
  'instagr.am',
  'www.instagr.am',
  'tiktok.com',
  'www.tiktok.com',
  'vm.tiktok.com',
  'vt.tiktok.com',
  'youtube.com',
  'www.youtube.com',
  'm.youtube.com',
  'youtu.be',
};

/// The first web link inside some shared text, or null if there is none.
///
/// A share sheet does not promise a bare URL. TikTok sends the link with a
/// sentence of its own around it, Instagram sometimes prefixes the caption, and
/// a person forwarding a message may send a whole paragraph. Treating the lot
/// as a URL fails on every one of those, and it fails as "not a link", which
/// is a confusing thing to be told about a message that plainly contains one.
///
/// Deliberately the *first* rather than the best. A share holds one link and
/// whatever else came with it; picking among several would be guessing at which
/// of two things somebody meant, and there is nothing here to guess with.
String? firstLinkIn(String text) {
  final match = RegExp(r'https?://[^\s<>"]+').firstMatch(text);
  if (match == null) return null;
  var link = match.group(0)!;
  // Trailing punctuation belongs to the sentence, not to the link: "look at
  // https://example.com/p/abc." resolves to a path that does not exist.
  link = link.replaceFirst(RegExp(r'[.,;:!?]+$'), '');
  // A closing bracket is only punctuation if nothing opened it inside the link
  // itself. "(see https://example.com/p/a)" ends a sentence; a Wikipedia link
  // ending in "_(disambiguation)" does not, and trimming that breaks it.
  if (link.endsWith(')') && !link.contains('(')) {
    link = link.substring(0, link.length - 1);
  }
  if (link.endsWith(']') && !link.contains('[')) {
    link = link.substring(0, link.length - 1);
  }
  return link;
}

/// Whether this is a link the reel feature can be asked about.
bool isReelLink(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || uri.scheme != 'https') return false;
  return reelHosts.contains(uri.host.toLowerCase());
}

/// Why an attempt did not produce places.
///
/// These map one to one onto the codes the Worker returns, because the app
/// shows different copy for each and a collapsed set would mean telling
/// somebody to try screenshots when the real answer is that they have run out
/// of their allowance for the month.
enum ReelFailure {
  /// Not a link this feature reads. Should be caught before asking.
  unsupported,

  /// The purchase is not held. The paywall, not an error.
  notEntitled,

  /// The monthly allowance is used up.
  quotaExceeded,

  /// Another post is already being read for this purchase.
  busy,

  /// Private, deleted, or not available in this country.
  postUnavailable,

  /// The vendor could not fetch it. Offer screenshots.
  fetchFailed,

  /// It was fetched but nothing readable came back.
  nothingFound,

  /// No network, or the Worker did not answer.
  unreachable,
}

/// One place the server read, before the device resolves it.
///
/// Deliberately not a `Place`: nothing here has been looked up yet, and giving
/// it the same type as a resolved place is how an unresolved name ends up in a
/// guide.
@immutable
class ReelCandidate {
  const ReelCandidate({required this.name, this.city, this.kind});

  final String name;
  final String? city;
  final String? kind;

  static ReelCandidate? tryFrom(Object? raw) {
    if (raw is! Map) return null;
    final name = (raw['name'] as Object?)?.toString().trim() ?? '';
    if (name.isEmpty) return null;
    String? text(String key) {
      final v = (raw[key] as Object?)?.toString().trim();
      return (v == null || v.isEmpty) ? null : v;
    }

    return ReelCandidate(name: name, city: text('city'), kind: text('kind'));
  }
}

/// What the server said.
@immutable
class ReelReading {
  const ReelReading({
    required this.candidates,
    this.regionHint,
    this.used,
    this.limit,
    this.resetsAt,
  });

  final List<ReelCandidate> candidates;

  /// The city the post is about, when most of its places agree on one. Null is
  /// a real answer: a post naming ten castles in seven countries has no single
  /// region, and guessing one aims every lookup at the wrong place.
  final String? regionHint;

  final int? used;
  final int? limit;
  final DateTime? resetsAt;
}

/// Thrown for everything that is not a reading.
class ReelFailed implements Exception {
  const ReelFailed(this.reason, {this.resetsAt});

  final ReelFailure reason;

  /// When the allowance comes back, for [ReelFailure.quotaExceeded]. The window
  /// rolls, so this is a real date rather than the first of the month.
  final DateTime? resetsAt;
}

/// How the caller proves it is allowed to spend money.
///
/// The server verifies this itself — an App Store transaction against Apple's
/// certificate chain, a Play token against Google, a comp token against the
/// signing key. Nothing here is trusted, which is why the app can send it
/// without the app having to be trustworthy.
@immutable
class ReelAuth {
  const ReelAuth.appStore(String jws) : _kind = 'appstore', _a = jws, _b = null;
  const ReelAuth.play(String purchaseToken, String productId)
    : _kind = 'play',
      _a = purchaseToken,
      _b = productId;
  const ReelAuth.comp(String token) : _kind = 'comp', _a = token, _b = null;

  final String _kind;
  final String _a;
  final String? _b;

  Map<String, Object?> toJson() => switch (_kind) {
    'appstore' => {'kind': 'appstore', 'jws': _a},
    'play' => {'kind': 'play', 'purchaseToken': _a, 'productId': _b},
    _ => {'kind': 'comp', 'token': _a},
  };
}

/// Asks the Worker to read a post.
///
/// The timeout is generous because the work is genuinely slow — fetching a
/// video and reading it takes tens of seconds — and because giving up early
/// would spend the money and then throw the answer away. The caller shows
/// progress rather than blocking.
Future<ReelReading> readReel(
  String link, {
  required ReelAuth auth,
  // Not marked visible-for-testing, though a test is the only thing that ever
  // passes one: it travels from the widget, which is production code holding a
  // test seam, and an annotation here would make that call site an error.
  Sender? send,
  @visibleForTesting Duration timeout = const Duration(seconds: 120),
}) async {
  if (!isReelLink(link)) throw const ReelFailed(ReelFailure.unsupported);

  final ({int status, String body}) reply;
  try {
    reply = await (send ?? _post)(
      Uri.parse('$reelsEndpoint/process'),
      jsonEncode({'url': link, 'auth': auth.toJson()}),
      timeout,
    );
  } on Object {
    // No network, DNS, TLS, timeout. Deliberately one reason: the app offers
    // the same advice for all of them, and a person on a train does not need
    // to know which layer gave up.
    throw const ReelFailed(ReelFailure.unreachable);
  }

  Map<String, Object?> body;
  try {
    body = jsonDecode(reply.body) as Map<String, Object?>;
  } on Object {
    throw const ReelFailed(ReelFailure.unreachable);
  }

  if (reply.status != 200) {
    throw ReelFailed(
      _failureOf(body['error']),
      resetsAt: _resetOf(body['quota']),
    );
  }

  final raw = body['candidates'];
  final candidates = raw is List
      ? raw.map(ReelCandidate.tryFrom).nonNulls.toList(growable: false)
      : const <ReelCandidate>[];
  if (candidates.isEmpty) throw const ReelFailed(ReelFailure.nothingFound);

  final quota = body['quota'];
  return ReelReading(
    candidates: candidates,
    regionHint: body['regionHint']?.toString(),
    used: quota is Map ? (quota['used'] as num?)?.toInt() : null,
    limit: quota is Map ? (quota['limit'] as num?)?.toInt() : null,
    resetsAt: _resetOf(quota),
  );
}

/// The one network call this file makes, injectable for tests.
///
/// dart:io rather than package:http, matching comp_unlock.dart — the app has
/// exactly two servers it talks to and no reason to carry a dependency for
/// them. The timeout is a parameter because reading a video genuinely takes
/// tens of seconds and the default would give up on a working request.
typedef Sender =
    Future<({int status, String body})> Function(
      Uri url,
      String body,
      Duration timeout,
    );

Future<({int status, String body})> _post(
  Uri url,
  String body,
  Duration timeout,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.postUrl(url);
    request.headers.contentType = ContentType.json;
    request.write(body);
    final response = await request.close().timeout(timeout);
    return (
      status: response.statusCode,
      body: await response.transform(utf8.decoder).join(),
    );
  } finally {
    client.close(force: true);
  }
}

/// Anything unrecognised is a fetch failure, because that is the one whose copy
/// offers the screenshot path — the advice that is useful whatever went wrong.
ReelFailure _failureOf(Object? code) => switch (code) {
  'unsupported_host' => ReelFailure.unsupported,
  'not_entitled' => ReelFailure.notEntitled,
  'quota_exceeded' => ReelFailure.quotaExceeded,
  'busy' => ReelFailure.busy,
  'post_unavailable' => ReelFailure.postUnavailable,
  _ => ReelFailure.fetchFailed,
};

DateTime? _resetOf(Object? quota) {
  if (quota is! Map) return null;
  final ms = (quota['resetsAt'] as num?)?.toInt();
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}
