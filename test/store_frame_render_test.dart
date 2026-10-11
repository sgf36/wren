/// Renders the captioned store images, for `store/frames.py`.
///
///     python store/frames.py --locale en-GB
///
/// which runs this file with the environment below. Without `WREN_FRAME_OUT`
/// it skips, so an ordinary `flutter test` writes nothing.
///
/// ## Why captioned images (11 Oct 2026)
///
/// The product page's images were bare app screens, the first one headed "2
/// over the free limit of 3": a paywall before any promise. In the fortnight
/// to 10 Oct, 266 product-page views referred by TikTok produced no download
/// that Apple credited to TikTok. These lead with what the adverts promise and
/// say it in words, a headline and one line over each screen.
///
/// ## How
///
/// Two passes per slide. The scene is drawn first exactly as the adverts are
/// (the real [CapturePage], full phone size, iOS's font cascade), into an
/// image. Then the frame is drawn — background, caption, and that image in a
/// phone-shaped window with the empty status-bar band cropped off. Drawing the
/// app as a picture rather than nesting it keeps its MediaQuery a real phone's.
/// A slide can instead name a real-device image (the guide in Apple Maps,
/// which a simulator cannot open; see SCREENSHOTS-RUNBOOK.md §3).
///
/// Nothing the system draws appears (status bar, keyboard), as in the adverts;
/// a focused field is unfocused before capture.
///
/// ## Environment
///
/// - `WREN_FRAME_OUT`: directory; images go to `<out>/<slide id>.png`.
/// - `WREN_RENDER_LOCALE`: App Store locale, e.g. `en-GB`.
/// - `WREN_RENDER_FONTS`: the font config store/render.py writes (shared).
/// - `WREN_FRAME_SPEC`: store/frames.json.
/// - `WREN_FRAME_PRICES`: JSON {productId: price} for this locale.
/// - `WREN_FRAME_ROOT`: the repository root, for image slides' paths.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wren/main.dart';
import 'package:wren/src/entitlement.dart';
import 'package:wren/src/screenshots.dart';
import 'package:wren/src/theme.dart';

import 'render_support.dart';

/// The App Store's largest iPhone slot, APP_IPHONE_67: 1290x2796, a 430x932 pt
/// phone at 3x. Safe-area insets as the 6.7-inch phones report them.
const _physical = Size(1290, 2796);
const _ratio = 3.0;
const _padTop = 59.0;
const _padBottom = 34.0;

final _env = Platform.environment;

/// Right-to-left scripts among the locales a frame may be drawn in.
const _rtl = {'ar', 'he', 'fa', 'ur'};

void main() {
  final out = _env['WREN_FRAME_OUT'];

  testWidgets('render captioned store frames', (tester) async {
    final tag = _env['WREN_RENDER_LOCALE'] ?? 'en-GB';
    final locale = parseLocale(tag);
    final spec =
        jsonDecode(File(_env['WREN_FRAME_SPEC']!).readAsStringSync())
            as Map<String, dynamic>;
    final slides = (spec['slides'] as List).cast<Map<String, dynamic>>();
    final captions = ((spec['captions'] as Map)[tag] as List?)
        ?.map((c) => (c as List).cast<String>())
        .toList();
    expect(captions, isNotNull, reason: 'no captions for $tag in frames.json');
    expect(
      captions!.length,
      slides.length,
      reason: '$tag: one caption per slide',
    );
    final prices =
        (jsonDecode(File(_env['WREN_FRAME_PRICES']!).readAsStringSync()) as Map)
            .cast<String, String>();
    SceneRequest.usePrices(prices);
    final price = prices[unlimitedProductId];

    final cascade = (await tester.runAsync(
      () => loadRenderFonts(_env['WREN_RENDER_FONTS']!),
    ))!;

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    debugDisableShadows = false;
    tester.view.physicalSize = _physical;
    tester.view.devicePixelRatio = _ratio;
    tester.platformDispatcher.localesTestValue = [locale];
    tester.platformDispatcher.localeTestValue = locale;
    Directory(out!).createSync(recursive: true);

    Future<ui.Image> capture(GlobalKey key) async {
      cascade.apply();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      return (await tester.runAsync(
        () => boundary.toImage(pixelRatio: _ratio),
      ))!;
    }

    for (var i = 0; i < slides.length; i++) {
      final slide = slides[i];
      final id = slide['id'] as String;
      final caption = captions[i];
      if (caption.any((c) => c.contains('{price}')) && price == null) {
        fail('$tag: "$id" quotes {price} and shot_prices.json has none');
      }

      // Pass one: the screen, as a phone draws it.
      ui.Image screen;
      double cropTop;
      if (slide['scene'] != null) {
        SharedPreferences.setMockInitialValues({});
        tester.view.padding = const FakeViewPadding(
          top: _padTop * _ratio,
          bottom: _padBottom * _ratio,
        );
        tester.view.viewPadding = const FakeViewPadding(
          top: _padTop * _ratio,
          bottom: _padBottom * _ratio,
        );
        final key = GlobalKey();
        final scene = sceneFor(slide['scene'] as String);
        expect(scene, isNotNull, reason: 'no scene "${slide['scene']}"');
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: WrenApp(home: scene),
          ),
        );
        // Overlays open in a post-frame callback and animate in.
        for (var t = 0; t < 30; t++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final focus = FocusManager.instance.primaryFocus;
        if (focus?.context != null &&
            (focus!.context!.widget is EditableText ||
                focus.context!.findAncestorWidgetOfExactType<EditableText>() !=
                    null)) {
          focus.unfocus();
          await tester.pump(const Duration(milliseconds: 300));
        }
        screen = await capture(key);
        cropTop = (_padTop - 12) * _ratio; // keep a little air above the header
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 30));
      } else {
        final path = '${_env['WREN_FRAME_ROOT']}/${slide['image']}';
        final bytes = File(path).readAsBytesSync();
        screen = (await tester.runAsync(() async {
          final codec = await ui.instantiateImageCodec(bytes);
          return (await codec.getNextFrame()).image;
        }))!;
        cropTop = 0;
      }

      // Pass two: the frame.
      tester.view.padding = FakeViewPadding.zero;
      tester.view.viewPadding = FakeViewPadding.zero;
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: _Frame(
            headline: caption[0].replaceAll('{price}', price ?? ''),
            line: caption[1].replaceAll('{price}', price ?? ''),
            screen: screen,
            cropTop: cropTop,
            rtl: _rtl.contains(locale.languageCode),
            locale: locale,
          ),
        ),
      );
      await tester.pump();
      final image = await capture(key);
      await tester.runAsync(() async {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$out/$id.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
      image.dispose();
      screen.dispose();
      debugPrint('$tag $id');
    }

    File('$out/glyphs.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        for (final e in cascade.glyphs.entries)
          e.key: (e.value.toList()..sort()).join(),
      }),
    );

    debugDefaultTargetPlatformOverride = null;
    debugDisableShadows = true;
    tester.view.reset();
    tester.platformDispatcher.clearAllTestValues();
  }, skip: out == null);
}

/// One store image: Wren's green, the caption, and the screen in a window.
class _Frame extends StatelessWidget {
  const _Frame({
    required this.headline,
    required this.line,
    required this.screen,
    required this.cropTop,
    required this.rtl,
    required this.locale,
  });

  final String headline;
  final String line;
  final ui.Image screen;

  /// Physical pixels cut off the top of [screen]: the band a status bar would
  /// fill, empty here because nothing the system draws is rendered.
  final double cropTop;
  final bool rtl;
  final Locale locale;

  static const _windowTop = 236.0;
  static const _windowBottom = 900.0;
  static const _windowWidth = 327.0;

  @override
  Widget build(BuildContext context) {
    final srcHeight = screen.height - cropTop;
    // The window keeps the screen's own proportions, up to the space there is;
    // a taller screen is cut at the bottom rather than squashed.
    final height = (_windowWidth * srcHeight / screen.width).clamp(
      0.0,
      _windowBottom - _windowTop,
    );
    return Directionality(
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      child: Localizations(
        locale: locale,
        delegates: const [
          DefaultWidgetsLocalizations.delegate,
          DefaultMaterialLocalizations.delegate,
        ],
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Wren.raised, Wren.ground],
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                left: 30,
                right: 30,
                top: 62,
                height: _windowTop - 62 - 14,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      headline,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: const TextStyle(
                        fontFamily: Wren.serif,
                        fontSize: 33,
                        height: 1.15,
                        color: Wren.text,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      line,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      style: const TextStyle(
                        fontSize: 17,
                        height: 1.35,
                        color: Wren.muted,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: _windowTop,
                left: (430 - _windowWidth) / 2,
                width: _windowWidth,
                height: height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(34),
                    border: Border.all(color: Wren.line, width: 2.5),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 30,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(32),
                    child: CustomPaint(
                      painter: _ScreenPainter(screen, cropTop),
                      size: Size(_windowWidth, height),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paints [image] from [cropTop] down, scaled to the window's width.
class _ScreenPainter extends CustomPainter {
  _ScreenPainter(this.image, this.cropTop);

  final ui.Image image;
  final double cropTop;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / image.width;
    final srcHeight = size.height / scale;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, cropTop, image.width.toDouble(), srcHeight),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(_ScreenPainter old) =>
      old.image != image || old.cropTop != cropTop;
}
