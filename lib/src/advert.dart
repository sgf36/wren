/// The advert beats, choreographed by the app itself.
///
/// A beat is one of the store scenes with a script played over it: hold, scroll,
/// tap, hold. `store/record.py` launches the app once per beat with
/// `simctl launch`, records the screen with `simctl io recordVideo`, and stops.
///
/// This replaced an `integration_test` harness that worked and was still wrong.
/// It rendered at a genuine 55fps and drove real gestures, but
/// `LiveTestWidgetsFlutterBinding` **paints a crosshair at the pointer**, which
/// landed in the middle of the money shot. There is no supported way to turn it
/// off, and a marketing frame cannot carry a test artefact. Two lesser faults
/// went with it: `flutter test` rebuilds and reinstalls before running, so the
/// recorder captured four hundred seconds of build for seven seconds of app;
/// and the region dialog opened reliably on the fake clock but not under
/// `runAsync` on a device.
///
/// So the gestures here are still real — [Choreography] posts them through
/// [GestureBinding.handlePointerEvent], the same pipeline a finger uses — but
/// there is no test binding anywhere, so there is nothing to draw a crosshair.
/// The app is an ordinary debug build being launched normally.
///
/// Like `screenshots.dart`, every beat is built on the **real** [CapturePage] by
/// way of [sceneFor]. Nothing here reimplements a card or a dialog, so a change
/// to the interface reaches the advert and the store screenshots together.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'screenshots.dart';
import 'splash.dart';
import 'theme.dart';

/// One beat: the scene it dresses, how long it runs, and what happens.
class AdvertBeat {
  const AdvertBeat(this.scene, this.seconds, this.script);

  /// The `screenshots.dart` scene this is played over.
  final String scene;

  /// Wall-clock length, used by `record.py` to know when to stop recording.
  /// Keep it a little longer than the script actually needs.
  final double seconds;

  final Future<void> Function(Choreography) script;
}

/// Waited after the first frame, before any beat starts.
///
/// **The first frame is not the first frame the recorder sees.** On a CI
/// simulator the app draws for about two and a half seconds before the
/// compositor presents anything, and the recording is plain white throughout.
/// Without this, `advert-which-city` spent its whole 2.6-second hold behind that
/// white, and the region dialog was visible for under half a second before the
/// tap dismissed it — the beat played perfectly and recorded almost nothing.
///
/// `store/record.py` reads this value out of this file and adds it to every
/// beat's length, so the two cannot drift apart.
const advertLeadIn = 3.0;

/// Every beat, by the name `record.py` passes in.
///
/// The `advert-` prefix keeps these clear of [sceneNames]; `shoot.py` iterates
/// that list and must never try to photograph one of these.
const advertBeats = <String, AdvertBeat>{
  'advert-intro': AdvertBeat('splash', 5.0, _intro),
  'advert-add': AdvertBeat('empty', 2.5, _add),
  'advert-the-list': AdvertBeat('01-the-list', 4.0, _theList),
  'advert-which-city': AdvertBeat('04-which-city', 4.0, _whichCity),
  'advert-make-guide': AdvertBeat('01-the-list-unlocked', 5.0, _makeGuide),
  'advert-correct-a-place': AdvertBeat(
    '03-correct-a-place',
    6.0,
    _correctAPlace,
  ),
};

/// The beat named, or null so `main` falls through to [sceneFor] and then to the
/// unknown-scene screen.
Widget? advertFor(String name) {
  final beat = advertBeats[name];
  if (beat == null) return null;
  if (beat.scene == 'splash') {
    return _withSentinel(
      const SplashGate(
        child: ColoredBox(color: Wren.ground, child: SizedBox.expand()),
      ),
    );
  }
  final scene = sceneFor(beat.scene);
  if (scene == null) return null;
  return _withSentinel(_Stage(script: beat.script, child: scene));
}

/// A magenta marker in the status-bar zone, invisible in the final video
/// (compose.py crops it) but detectable by [_find_content_start] to locate
/// the exact frame where the app's UI first appears. Eliminates timing
/// guesses that broke the splash beat on CI runners.
Widget _withSentinel(Widget child) => Stack(
  children: [
    Positioned.fill(child: child),
    const Positioned(
      top: 2,
      left: 2,
      child: SizedBox(
        width: 6,
        height: 6,
        child: ColoredBox(color: Color(0xFFFF00FF)),
      ),
    ),
  ],
);

// --- the scripts -------------------------------------------------------------

Future<void> _intro(Choreography c) async {
  await c.hold(5.0);
}

Future<void> _add(Choreography c) async {
  final addPlaces = L.of(c.context).addPlaces;
  await c.tapText(addPlaces);
  await c.hold(2.0);
}

Future<void> _theList(Choreography c) async {
  await c.hold(4.0);
}

Future<void> _whichCity(Choreography c) async {
  final findPlaces = L.of(c.context).findPlaces;
  await c.hold(1.5);
  await c.tapText(findPlaces);
  await c.hold(2.0);
}

Future<void> _makeGuide(Choreography c) async {
  final l = L.of(c.context);
  await c.hold(1.0);
  await c.tapText(l.makeGuide(5));
  await c.hold(3.0);
}

Future<void> _correctAPlace(Choreography c) async {
  // A name the map did not recognise, with the lookup already open on it. Worth
  // its five seconds: it is the app admitting a miss, which is the difference
  // between a tool and a magic trick.
  await c.hold(5.0);
}

// --- the stage ---------------------------------------------------------------

class _Stage extends StatefulWidget {
  const _Stage({required this.script, required this.child});

  final Future<void> Function(Choreography) script;
  final Widget child;

  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> {
  Choreography? _choreography;
  final _touch = ValueNotifier<Offset?>(null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final choreography = Choreography(context, touchIndicator: _touch);
      _choreography = choreography;
      await choreography.hold(advertLeadIn);
      if (!mounted) return;
      await widget.script(choreography);
    });
  }

  @override
  void dispose() {
    _choreography?.stop();
    _touch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(child: widget.child),
      ValueListenableBuilder<Offset?>(
        valueListenable: _touch,
        builder: (context, position, _) {
          if (position == null) return const SizedBox.shrink();
          return IgnorePointer(
            child: CustomPaint(
              painter: _TouchDot(position),
              size: Size.infinite,
            ),
          );
        },
      ),
    ],
  );
}

/// Drives one beat: waits, drags and taps, posted as real pointer events.
class Choreography {
  Choreography(this.context, {this.touchIndicator})
    : _clock = Stopwatch()..start(),
      _centre = _centreOf(context);

  final BuildContext context;
  final Stopwatch _clock;

  /// Measured once, at construction. Reading the view after an await risks a
  /// context that is no longer mounted.
  final Offset _centre;

  /// Set by [_Stage] to show a gold dot at the active pointer position.
  final ValueNotifier<Offset?>? touchIndicator;

  int _pointer = 1;

  Timer? _pending;
  Timer? _touchFade;
  bool _stopped = false;

  Duration get _now => _clock.elapsed;

  void _post(PointerEvent event) {
    if (_stopped) return;
    GestureBinding.instance.handlePointerEvent(event);
    if (touchIndicator != null) {
      if (event is PointerDownEvent || event is PointerMoveEvent) {
        _touchFade?.cancel();
        touchIndicator!.value = event.position;
      } else if (event is PointerUpEvent) {
        _touchFade = Timer(const Duration(milliseconds: 600), () {
          touchIndicator?.value = null;
        });
      }
    }
  }

  /// Hold the shot. Ordinary real time — the app is drawing on its own vsync.
  Future<void> hold(double seconds) =>
      _wait(Duration(milliseconds: (seconds * 1000).round()));

  /// Every wait in a beat goes through here, so [stop] can end all of them.
  Future<void> _wait(Duration d) {
    if (_stopped) return Future<void>.value();
    final done = Completer<void>();
    _pending = Timer(d, () {
      _pending = null;
      if (!done.isCompleted) done.complete();
    });
    return done.future;
  }

  /// Abandon the beat. Remaining waits return at once, so the script runs out
  /// harmlessly rather than being left suspended forever.
  void stop() {
    _stopped = true;
    _pending?.cancel();
    _pending = null;
    _touchFade?.cancel();
    _touchFade = null;
    touchIndicator?.value = null;
  }

  /// A tap on the first widget whose text reads [label].
  ///
  /// Looked up through [L] by the caller rather than written as a literal, so a
  /// beat plays in any of the app's languages. Returns false if nothing matched,
  /// which the caller may ignore — a missing button should not abort a
  /// recording that is otherwise usable.
  Future<bool> tapText(String label) async {
    final box = _boxForText(label);
    if (box == null) return false;
    await tapAt(box.localToGlobal(box.size.center(Offset.zero)));
    return true;
  }

  Future<void> tapAt(Offset at) async {
    final id = _pointer++;
    _post(PointerDownEvent(pointer: id, position: at, timeStamp: _now));
    await hold(0.09);
    _post(PointerUpEvent(pointer: id, position: at, timeStamp: _now));
  }

  /// A hand-paced drag, walked out in frame-sized steps.
  ///
  /// One large move would be followed in one jump by the list, which on video
  /// reads as a cut rather than a gesture.
  Future<void> drag(Offset total, {double seconds = 1.4, Offset? from}) async {
    final steps = (seconds * 60).round().clamp(2, 600);
    final step = total / steps.toDouble();
    var at = from ?? _centre;
    final id = _pointer++;

    _post(PointerDownEvent(pointer: id, position: at, timeStamp: _now));
    for (var i = 0; i < steps && !_stopped; i++) {
      at += step;
      _post(
        PointerMoveEvent(
          pointer: id,
          position: at,
          delta: step,
          timeStamp: _now,
        ),
      );
      await _wait(const Duration(milliseconds: 16));
    }
    _post(PointerUpEvent(pointer: id, position: at, timeStamp: _now));
  }

  static Offset _centreOf(BuildContext context) {
    final view = View.of(context);
    final size = view.physicalSize / view.devicePixelRatio;
    // Above centre: low enough to be over the list, high enough to miss the
    // buttons pinned to the bottom.
    return Offset(size.width / 2, size.height * 0.45);
  }

  /// The render box of the first [Text] reading [label], anywhere on screen.
  ///
  /// Walked from the root rather than from [context] so it reaches dialogs and
  /// sheets, which hang off the [Navigator]'s overlay and are not descendants of
  /// the scene.
  RenderBox? _boxForText(String label) {
    RenderBox? found;

    void visit(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is Text && _textOf(widget) == label) {
        final object = element.renderObject;
        if (object is RenderBox && object.hasSize && object.attached) {
          found = object;
          return;
        }
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return found;
  }

  static String? _textOf(Text widget) =>
      widget.data ?? widget.textSpan?.toPlainText();
}

/// A gold circle drawn at the active touch position.
class _TouchDot extends CustomPainter {
  _TouchDot(this.position);
  final Offset position;

  static const _radius = 36.0;
  static final _fill = Paint()..color = const Color(0x80F2C879);
  static final _ring = Paint()
    ..color = const Color(0xD9F2C879)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(position, _radius, _fill);
    canvas.drawCircle(position, _radius, _ring);
  }

  @override
  bool shouldRepaint(_TouchDot old) => position != old.position;
}
