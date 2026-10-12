/// What the two still/frame renderers share: the locale tag parser, the font
/// loader and iOS's font cascade. Moved out of advert_render_test.dart on
/// 11 Oct 2026 when store_frame_render_test.dart needed the same fonts; one
/// copy, so the advert and the store images can never be drawn two ways.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

Locale parseLocale(String tag) {
  final parts = tag.split('-');
  if (parts.length >= 2 && parts[1].length == 4) {
    return Locale.fromSubtags(languageCode: parts[0], scriptCode: parts[1]);
  }
  return parts.length >= 2 ? Locale(parts[0], parts[1]) : Locale(parts[0]);
}

Future<FontCascade> loadRenderFonts(String configPath) async {
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
  return FontCascade(
    loaded,
    names('serifFallback'),
    names('sansFallback'),
    (config['systemFamily'] as String?) ?? 'CupertinoSystemText',
  );
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
class FontCascade {
  FontCascade(
    this.loaded,
    this.serifFallback,
    this.sansFallback,
    this.systemFamily,
  );

  final List<String> loaded;
  final List<String> serifFallback;
  final List<String> sansFallback;

  /// The face text with no family of its own is drawn in: SF on iOS,
  /// Roboto on Android.
  final String systemFamily;

  /// Chain ("Georgia>WrenSerif>WrenSans") → every character drawn with it.
  final glyphs = <String, Set<String>>{};

  /// The fallback chain text set in [family] is drawn with. Public so a frame
  /// can measure text in the fonts it will be drawn in.
  List<String> chainFor(String family) =>
      family == 'Georgia' ? [...serifFallback, ...sansFallback] : sansFallback;

  InlineSpan _patch(InlineSpan span, String? inherited) {
    if (span is! TextSpan) return span;
    final family = span.style?.fontFamily ?? inherited ?? systemFamily;
    if (!loaded.contains(family)) {
      throw StateError(
        'text "${span.text}" asks for font family "$family", '
        'which was not loaded',
      );
    }
    final chain = chainFor(family);
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
