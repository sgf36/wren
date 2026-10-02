/// Every language the phone can report resolves to that language's
/// translation, never to the fallback.
///
/// Flutter's fallback for an unmatched locale is the first supported one,
/// which is Arabic. Norwegian phones report `nb` and the translation is `no`,
/// so until 2 October 2026 a Norwegian phone got the Arabic app — visible in
/// the simulator footage of the nb advert, and never caught by a check that
/// only asked whether a translation existed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wren/l10n/app_localizations.dart';
import 'package:wren/main.dart';

Locale _resolve(Locale phone) =>
    basicLocaleListResolution([canonicalLocale(phone)], L.supportedLocales);

Locale _parse(String tag) {
  final p = tag.split('-');
  if (p.length >= 2 && p[1].length == 4) {
    return Locale.fromSubtags(languageCode: p[0], scriptCode: p[1]);
  }
  return p.length >= 2 ? Locale(p[0], p[1]) : Locale(p[0]);
}

void main() {
  test('Norwegian Bokmål and Nynorsk get the Norwegian translation', () {
    expect(_resolve(const Locale('nb', 'NO')).languageCode, 'no');
    expect(_resolve(const Locale('nb')).languageCode, 'no');
    expect(_resolve(const Locale('nn', 'NO')).languageCode, 'no');
  });

  test('every advert locale resolves to its own language', () {
    final strings =
        jsonDecode(File('store/advert_strings.json').readAsStringSync())
            as Map<String, dynamic>;
    final locales = (strings['problem'] as Map<String, dynamic>).keys;
    expect(locales, isNotEmpty);
    for (final tag in locales) {
      final phone = _parse(tag);
      final got = _resolve(phone);
      expect(
        got.languageCode,
        canonicalLocale(phone).languageCode,
        reason: '$tag resolved to $got — the fallback, not a translation',
      );
    }
  });

  test('Traditional Chinese keeps its script', () {
    final got = _resolve(
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    );
    expect(got.scriptCode, 'Hant');
  });
}
