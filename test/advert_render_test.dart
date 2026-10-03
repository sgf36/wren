/// Renders the advert beats frame by frame, for `store/compose.py`.
///
///     python store/render.py --locale fr-FR
///
/// which runs this file with the environment below. Without `WREN_RENDER_OUT`
/// it skips, so an ordinary `flutter test` does not spend a minute writing PNGs.
///
/// ## Why the beats are rendered here and not recorded
///
/// Until October 2026 they were played in an iOS Simulator on a CI runner and
/// captured with `simctl io recordVideo`. Two runs measured frame by frame
/// (34 and 35) found that the recording itself could not be trusted: about a
/// quarter of the clips carried presentation timestamps up to three seconds out
/// of order, so any cut by time pulled in the home screen or replayed motion
/// backwards; the debug build's first run of a scene stalled for two to four
/// seconds in eight locales out of eight; and the launch screen lasted anywhere
/// from two to thirty-three seconds. Every fix uncovered the next fault, each at
/// thirty minutes a try.
///
/// Here the clock is the test's fake clock and every frame is drawn on demand:
/// frame n is the app exactly n/30 s after its first frame, every time, on any
/// machine. The choreography is the same code — [Choreography] posts the same
/// pointer events through the same binding — so the advert still shows the real
/// [CapturePage], not a rebuild of it.
///
/// ## What it cannot show
///
/// Nothing the operating system draws: no status bar (compose.py crops that
/// band anyway), no home indicator (likewise) and **no keyboard**. A text field
/// that takes focus is therefore unfocused before each frame is captured — a
/// focused field with a blinking cursor and no keyboard under it would be a
/// state no phone ever shows. Decided 2 October 2026: the beats show the moment
/// before typing, with the field already filled.
///
/// ## Environment
///
/// - `WREN_RENDER_OUT`: directory; frames go to `<out>/<beat>/00000.png` and a
///   `manifest.json` beside them.
/// - `WREN_RENDER_LOCALE`: e.g. `en-GB`, `zh-Hant`, `ar-SA`.
/// - `WREN_RENDER_BEATS`: comma-separated beat names, in order.
/// - `WREN_RENDER_FONTS`: a JSON file written by store/render.py —
///   `families` (family name → font files), `serifFallback` and
///   `sansFallback` (family names). Fonts are loaded from the machine, never
///   committed: on the macOS runner they are Apple's own system fonts.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wren/main.dart';
import 'package:wren/src/advert.dart';

const _fps = 30;

/// The device the simulator footage was recorded on: a 6.9-inch iPhone,
/// 1320x2868 at 3x. Safe-area insets match compose.py's crop (59pt, 34pt).
const _physical = Size(1320, 2868);
const _ratio = 3.0;
const _padTop = 59.0 * _ratio;
const _padBottom = 34.0 * _ratio;

final _env = Platform.environment;

Locale _parseLocale(String tag) {
  final parts = tag.split('-');
  if (parts.length >= 2 && parts[1].length == 4) {
    return Locale.fromSubtags(languageCode: parts[0], scriptCode: parts[1]);
  }
  return parts.length >= 2 ? Locale(parts[0], parts[1]) : Locale(parts[0]);
}

Future<_Cascade> _loadFonts(String configPath) async {
  final config =
      jsonDecode(File(configPath).readAsStringSync()) as Map<String, dynamic>;
  final families = config['families'] as Map<String, dynamic>;
  final loaded = <String>[];
  for (final entry in families.entries) {
    final loader = FontLoader(entry.key);
    var any = false;
    for (final path in (entry.value as List).cast<String>()) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final bytes = file.readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      any = true;
    }
    if (!any) {
      throw StateError(
        'no file found for font family "${entry.key}" in '
        '${entry.value} — a missing font renders as boxes, not as an error',
      );
    }
    await loader.load();
    loaded.add(entry.key);
  }
  List<String> names(String key) =>
      ((config[key] as List?) ?? const []).cast<String>();
  return _Cascade(loaded, names('serifFallback'), names('sansFallback'));
}

/// iOS's font cascade, applied where iOS applies it: to each run of text as it
/// is drawn.
///
/// The test engine has no system fallback — a character missing from the
/// requested family draws as a box, whatever else is registered (measured:
/// Japanese in a Latin family stayed boxes with a Japanese family loaded
/// beside it) — and a style with no family draws in its box font whatever
/// family is registered under any name, including 'FlutterTest' itself.
///
/// So before each frame is captured every paragraph on screen is given what
/// the phone would have used:
///
/// - no family → the system sans ([_systemFamily]), as on iOS;
/// - a fallback chain chosen by that family. Georgia falls back to the
///   locale's serif script font, everything else to its sans one — the
///   simulator footage of 2 October shows exactly that split (ja: a Mincho
///   heading under Georgia, Gothic body text).
///
/// Every character drawn is recorded against its chain, and store/render.py
/// proves each one is in one of the chain's font files. A family that was not
/// loaded fails here.
class _Cascade {
  _Cascade(this.loaded, this.serifFallback, this.sansFallback);

  final List<String> loaded;
  final List<String> serifFallback;
  final List<String> sansFallback;

  /// Chain ("Georgia>WrenSerif>WrenSans") → every character drawn with it.
  final glyphs = <String, Set<String>>{};

  static const _systemFamily = 'CupertinoSystemText';

  List<String> _chainFor(String family) =>
      family == 'Georgia' ? [...serifFallback, ...sansFallback] : sansFallback;

  InlineSpan _patch(InlineSpan span, String? inherited) {
    if (span is! TextSpan) return span;
    final family = span.style?.fontFamily ?? inherited ?? _systemFamily;
    if (!loaded.contains(family)) {
      throw StateError(
        'text "${span.text}" asks for font family "$family", '
        'which was not loaded',
      );
    }
    final chain = _chainFor(family);
    final text = span.text ?? '';
    if (text.isNotEmpty) {
      final key = [family, ...chain].join('>');
      (glyphs[key] ??= <String>{}).addAll(text.runes.map(String.fromCharCode));
    }
    final style = (span.style ?? const TextStyle()).copyWith(
      fontFamily: family,
      fontFamilyFallback: chain,
    );
    return TextSpan(
      text: span.text,
      style: style,
      children: span.children?.map((c) => _patch(c, family)).toList(),
      recognizer: span.recognizer,
      mouseCursor: span.mouseCursor,
      onEnter: span.onEnter,
      onExit: span.onExit,
      semanticsLabel: span.semanticsLabel,
      locale: span.locale,
      spellOut: span.spellOut,
    );
  }

  /// Patch every paragraph and field, then lay out and paint again so the
  /// frame about to be captured is the patched one.
  ///
  /// In the frame pipeline's own order — pending builds, then layout — and
  /// repeated until a pass changes nothing, because layout can build new
  /// paragraphs (a lazy list's children) that the previous pass never saw.
  void apply() {
    var changed = 0;
    void visit(RenderObject object) {
      if (object is RenderParagraph) {
        final next = _patch(object.text, null);
        if (object.text.compareTo(next) != RenderComparison.identical) {
          object.text = next;
          changed++;
        }
      } else if (object is RenderEditable && object.text != null) {
        final next = _patch(object.text!, null);
        if (object.text!.compareTo(next) != RenderComparison.identical) {
          object.text = next;
          changed++;
        }
      }
      object.visitChildren(visit);
    }

    final build = WidgetsBinding.instance.buildOwner!;
    final root = WidgetsBinding.instance.rootElement!;
    final pipeline = RendererBinding.instance.rootPipelineOwner;
    for (var pass = 0; ; pass++) {
      build.buildScope(root);
      changed = 0;
      for (final view in RendererBinding.instance.renderViews) {
        visit(view);
      }
      pipeline.flushLayout();
      if (changed == 0) break;
      if (pass == 5) {
        throw StateError('text kept changing under the font cascade');
      }
    }
    pipeline.flushCompositingBits();
    pipeline.flushPaint();
  }
}

/// Seconds of footage a beat needs: its script, the lead-in the app holds
/// before the script, and a half-second tail so the last state is seen.
double beatLength(String beat) {
  final b = advertBeats[beat]!;
  return b.seconds + (b.scene == 'splash' ? 0 : advertLeadIn) + 0.5;
}

void main() {
  final out = _env['WREN_RENDER_OUT'];

  testWidgets('render advert beats', (tester) async {
    final locale = _parseLocale(_env['WREN_RENDER_LOCALE'] ?? 'en-GB');
    final beats = (_env['WREN_RENDER_BEATS'] ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    expect(beats, isNotEmpty, reason: 'WREN_RENDER_BEATS names no beats');
    for (final b in beats) {
      expect(advertBeats.containsKey(b), isTrue, reason: 'no beat "$b"');
    }

    final cascade = (await tester.runAsync(
      () => _loadFonts(_env['WREN_RENDER_FONTS']!),
    ))!;
    debugPrint(
      'fonts: ${cascade.loaded.join(', ')}; serif fallback '
      '${cascade.serifFallback}; sans fallback ${cascade.sansFallback}',
    );

    // iOS, so Material picks the iOS typography, scroll physics and dialog
    // shapes the phone shows. The test binding defaults to Android.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    // The test binding flattens shadows for determinism; this is a picture,
    // and the cards have them.
    debugDisableShadows = false;
    tester.view.physicalSize = _physical;
    tester.view.devicePixelRatio = _ratio;
    tester.view.padding = FakeViewPadding(top: _padTop, bottom: _padBottom);
    tester.view.viewPadding = FakeViewPadding(top: _padTop, bottom: _padBottom);
    tester.platformDispatcher.localesTestValue = [locale];
    tester.platformDispatcher.localeTestValue = locale;

    final manifest = <String, Object>{
      'locale': _env['WREN_RENDER_LOCALE'] ?? 'en-GB',
      'fps': _fps,
      'width': _physical.width.round(),
      'height': _physical.height.round(),
      'beats': <Map<String, Object>>[],
    };

    for (final beat in beats) {
      SharedPreferences.setMockInitialValues({});
      final dir = Directory('$out/$beat');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);

      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: WrenApp(home: advertFor(beat)),
        ),
      );

      final frames = (beatLength(beat) * _fps).round();
      var elapsed = Duration.zero;
      for (var i = 0; i < frames; i++) {
        final target = Duration(microseconds: (i * 1e6 / _fps).round());
        if (target > elapsed) await tester.pump(target - elapsed);
        elapsed = target;
        // No keyboard exists here, so nothing may look as if it is typing.
        // The focus node's context is the Focus widget inside EditableText,
        // not EditableText itself — so look up, not at.
        final focus = FocusManager.instance.primaryFocus;
        final context = focus?.context;
        if (focus != null &&
            context != null &&
            (context.widget is EditableText ||
                context.findAncestorWidgetOfExactType<EditableText>() !=
                    null)) {
          focus.unfocus();
          await tester.pump();
        }
        cascade.apply();
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: _ratio);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          File(
            '${dir.path}/${i.toString().padLeft(5, '0')}.png',
          ).writeAsBytesSync(png!.buffer.asUint8List());
        });
      }
      (manifest['beats']! as List).add({
        'name': beat,
        'frames': frames,
        'seconds': frames / _fps,
      });
      debugPrint('$beat: $frames frames');

      // Unmount, then run out the clock, so the next beat starts on a fresh
      // app and no timer from this one is left pending at the end.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 30));
    }

    manifest['glyphs'] = {
      for (final e in cascade.glyphs.entries)
        e.key: (e.value.toList()..sort()).join(),
    };
    File(
      '$out/manifest.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));

    debugDefaultTargetPlatformOverride = null;
    debugDisableShadows = true;
    tester.view.reset();
    tester.platformDispatcher.clearAllTestValues();
  }, skip: out == null);
}
