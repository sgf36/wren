import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'l10n/app_localizations.dart';
import 'src/advert.dart';
import 'src/entitlement.dart';
import 'src/file_source.dart';
import 'src/guide_expand.dart';
import 'src/guide_import.dart';
import 'src/guide_link.dart';
import 'src/ocr.dart';
import 'src/place_files.dart';
import 'src/map_targets.dart';
import 'src/place_export.dart';
import 'src/place_search_sheet.dart';
import 'src/reel_import.dart';
import 'src/place_share.dart';
import 'src/region_hint.dart';
import 'src/resolver.dart';
import 'src/review_prompt.dart';
import 'src/share_inbox.dart';
import 'src/admin_sheet.dart';
import 'src/comp_unlock.dart' as comp;
import 'src/screenshots.dart';
import 'src/splash.dart';
import 'src/store_unlock.dart';
import 'src/theme.dart';
import 'src/wren_mark.dart';

/// True only in the build made for taking store screenshots.
///
/// A compile-time constant, so the normal build contains none of the scene
/// fixtures — tree shaking removes them — and a shipped app cannot be talked
/// into showing a fake list of places by any runtime input.
const _shots = bool.fromEnvironment('WREN_SHOTS');

void main() {
  if (_shots) {
    // Named per launch, so one build covers every scene and every language. Two
    // routes are tried — see [SceneRequest] — because the environment variable
    // alone arrived empty on iOS 26 and cost a whole run.
    final request = SceneRequest.resolve();
    // Read back off the device log by shoot.py after every launch, so the log
    // says which route delivered the scene even on a run that succeeds.
    debugPrint(request.logLine);
    // Advert beats first: they are scenes with a script played over them, and
    // their names are prefixed so they cannot collide with a plain scene.
    runApp(
      WrenApp(
        home:
            advertFor(request.name) ??
            sceneFor(request.name) ??
            UnknownScene.from(request),
      ),
    );
    return;
  }
  runApp(const WrenApp());
}

class WrenApp extends StatelessWidget {
  const WrenApp({super.key, this.home});

  /// Replaced only by the screenshot build. Normally the splash gate.
  final Widget? home;

  @override
  Widget build(BuildContext context) => MaterialApp(
    // Not translated. It is the app's name, and it is a bird.
    title: 'Wren',
    debugShowCheckedModeBanner: false,
    theme: Wren.theme,
    // Both lists come from the generated class, so adding an .arb file is the
    // whole of adding a language — there is no second place to keep in step.
    localizationsDelegates: L.localizationsDelegates,
    supportedLocales: L.supportedLocales,
    // No splash in the screenshot build: it animates, and a screenshot taken
    // during it catches the mark half-faded.
    home: home ?? const SplashGate(child: CapturePage()),
  );
}

/// Where a place in the list came from.
///
/// Worth distinguishing because it changes three things: whether the row shows
/// what was read (a place taken from Apple's own guide has no reading to
/// second-guess), whether it counts against the free limit, and whether it can
/// be truncated when someone publishes free — places the user already had must
/// never be dropped to fit a cap.
enum Origin { screenshot, file, guide }

/// One thing on the list, matched or not.
///
/// Unmatched readings are kept rather than dropped. Previously a name the map
/// did not recognise vanished with only a count to show for it, which threw
/// away the one record of what the user had actually seen — and left them no
/// way to fix it.
class Pending {
  /// What OCR read, or what the imported file called it. Never edited: it is
  /// the evidence, and the only trace of what the source said.
  final String readAs;

  /// What it resolved to, or null while it is still unidentified.
  PlaceMatch? match;

  /// What the file itself said, when the file supplied a coordinate.
  ///
  /// A file import is the one source that arrives already positioned: a KML or
  /// GPX carries the coordinate, so there is nothing to look up. That matters
  /// because looking up is the part that needs Apple's map — and on Android
  /// there is no Apple map, which used to make an import of a perfectly good
  /// file end in "Place lookup needs an iPhone" and an empty list.
  ///
  /// Such a place can be written into a file for another app. It cannot go into
  /// an Apple Maps guide, which identifies places by Apple's own id and nothing
  /// else.
  final ExportPlace? fromFile;

  bool keep;

  final Origin origin;

  Pending(
    this.readAs,
    this.match, {
    this.keep = true,
    this.origin = Origin.screenshot,
    this.fromFile,
  });

  bool get resolved => match != null;

  /// Only a place Apple has identified can go in a guide — the link is built
  /// out of place ids and carries nothing else. A geocoded match has a
  /// coordinate and no id, which is enough to send and not enough to publish.
  bool get publishable => match?.id != null && keep;

  /// Whether this place can be written into a file another map app will read.
  ///
  /// Wider than [publishable] on purpose. An OpenStreetMap app wants a
  /// coordinate and does not care whether Apple has ever heard of the place; a
  /// guide wants Apple's identifier and does not care about the coordinate.
  bool get exportable =>
      keep &&
      ((match?.hasCoordinate ?? false) || (fromFile?.hasCoordinate ?? false));

  /// The place as a file should carry it, or null when it cannot be written.
  ExportPlace? get forExport =>
      ExportPlace.from(match, readAs: readAs) ?? fromFile;

  /// Whether this place is one the user is being charged for. A place carried
  /// over from a guide they already own is not.
  bool get billable => origin != Origin.guide;
}

/// Empty strings are a name nobody chose. Reads better than a chain of
/// `isEmpty ? null : x` at each call site, and keeps the two places that pick a
/// list's name agreeing on what "no name" means.
extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

class CapturePage extends StatefulWidget {
  const CapturePage({
    super.key,
    this.store,
    this.saver,
    this.reelSender,
    this.canMakeGuides,
    this.sellsUnlock,
    this.resolver,
    this.files,
    this.expander,
    this.shareInbox,
    this.sharer,
    this.reviewPrompt,
    this.initialPending,
    this.initialGuideName,
    this.initialOverlay = ScreenshotOverlay.none,
  });

  /// Injectable so the paywall, the list and the importers can be tested
  /// without StoreKit, MapKit or a document picker, none of which exists
  /// off-device.
  final UnlockStore? store;
  final PlaceResolver? resolver;
  final FileSource? files;

  /// Writes a file the user names. Injected so the Google Maps route can be
  /// tested without a save dialog.
  final FileSaver? saver;

  /// Speaks to the Worker that reads shared posts. Injected so the whole reel
  /// flow — paywall, progress, failure copy, resolution — can be tested without
  /// a network, a vendor account or a real purchase.
  final Sender? reelSender;

  /// Whether this build can publish an Apple Maps guide.
  ///
  /// Null means "decide from the platform", and the platform that cannot is
  /// Android: there is no Apple Maps there, so a guide link opens a web page
  /// nobody asked for. Where it is false the main button hands the list to
  /// another map app instead, which is the whole Android product.
  ///
  /// One flag rather than two for the *button*. "Makes guides" and "sends
  /// places elsewhere" are exact opposites on every platform Wren runs on, and
  /// a pair of fields that must always disagree is a bug waiting to be written.
  ///
  /// It does **not** gate the purchase; [sellsUnlock] does. It briefly did,
  /// on the argument that the unlock sells guides of any size so where there
  /// are no guides there is nothing to sell. That was wrong: the cap is the
  /// product, and sending three places at a time rather than all of them is
  /// the same restriction whichever button reached it. Collapsing the two
  /// questions into this flag is the specific mistake to avoid here.
  ///
  /// What it does still decide is the paywall's *wording* -- "guides of any
  /// size" against "any number of places" -- because the sheet has to describe
  /// the button the user actually pressed.
  ///
  /// A test sets it either way, so both products can be exercised on whatever
  /// machine the tests run on -- otherwise the one path that hands a file to
  /// another app could only ever be checked by hand, on a phone.
  final bool? canMakeGuides;

  /// Whether this platform sells the unlock at all.
  ///
  /// Deliberately NOT the same question as [canMakeGuides], and the two must be
  /// allowed to disagree. "Does this build Apple Maps guides?" is false on
  /// Android. "Does this sell the unlock?" is true everywhere, because the two
  /// stores carry the same product at the same price and a cap that existed on
  /// one platform and not the other would be a different app wearing the same
  /// name.
  ///
  /// An earlier version folded these together and the comment on that flag said
  /// two fields that must always disagree is a bug waiting to be written. That
  /// was right about *always*: these two agree on iOS and part company only on
  /// Android, because each answers its own question. Do not re-collapse them.
  final bool? sellsUnlock;

  final LinkExpander? expander;

  /// Injectable so the share-sheet handoff can be tested without an extension.
  final ShareInbox? shareInbox;

  /// Injectable so sending to another map app can be tested without a device.
  final PlaceSharer? sharer;

  /// Injectable so the rating prompt can be tested without the App Store.
  /// Apple reports neither whether its prompt appeared nor what was said, so
  /// the only thing that can be asserted anywhere is when Wren asks for it.
  final ReviewPrompt? reviewPrompt;

  @visibleForTesting
  final List<Pending>? initialPending;

  /// The guide imported places came from, when the list starts with some.
  @visibleForTesting
  final String? initialGuideName;

  /// Opens one of the app's own overlays as soon as the first frame is up.
  ///
  /// Only for the store-screenshot build. It calls the same methods a tap
  /// calls, deliberately: a screenshot harness that rebuilt these dialogs to
  /// look right would keep looking right after the real ones changed.
  final ScreenshotOverlay initialOverlay;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> with WidgetsBindingObserver {
  final _picker = ImagePicker();
  late final PlaceResolver _resolver = widget.resolver ?? MapKitResolver();
  late final UnlockStore _store =
      widget.store ??
      (_sellsUnlock ? StoreUnlockStore() : UnavailableUnlockStore());
  late final FileSource _files = widget.files ?? DocumentFileSource();
  late final FileSaver _saver = widget.saver ?? const DocumentFileSaver();
  late final LinkExpander _expander = widget.expander ?? HttpLinkExpander();
  late final ShareInbox _shareInbox =
      widget.shareInbox ?? const MethodChannelShareInbox();
  late final PlaceSharer _sharer =
      widget.sharer ?? const MethodChannelPlaceSharer();
  // Real on both platforms, and deliberately not tied to [_makesGuides]. Every
  // build has a moment worth asking about: on iPhone a guide reaching Apple
  // Maps, on Android a list reaching whichever map app the user chose. Both are
  // armed below and asked for on the next resume. [NoReviewPrompt] records why
  // Android briefly had nothing.
  late final ReviewPrompt _reviewPrompt =
      widget.reviewPrompt ?? (const StoreReviewPrompt());

  /// Whether guides -- and therefore the purchase that sells bigger ones --
  /// exist on this platform at all. See [CapturePage.canMakeGuides].
  bool get _makesGuides => widget.canMakeGuides ?? !Platform.isAndroid;

  /// Whether the unlock is for sale here. True on both stores — see
  /// [CapturePage.sellsUnlock] for why this is a separate question.
  bool get _sellsUnlock => widget.sellsUnlock ?? true;

  /// Set once a lookup has reported that this platform has no map at all.
  ///
  /// Not a platform check. MapKit backs the search on iOS and the system
  /// geocoder backs it on Android, so both normally have one -- but an Android
  /// phone without Google services has no geocoder, and there is no way to
  /// know that except by asking. Discovered rather than assumed, and sticky
  /// once discovered.
  bool _noMapHere = false;

  /// Whether a wrong or missing match is something the user can act on.
  ///
  /// Offering a search that can only answer "there is no map search on this
  /// platform" turns every unmatched row into an error nobody can clear, which
  /// is what the Android build did while it had no lookup at all.
  bool get _canSearch => !_noMapHere;

  /// The My Map the user chose to keep adding to, if they have picked one.
  ///
  /// Remembering it is worth two taps every time: with an id the Custom Tab can
  /// open that map's edit page directly instead of the list plus a create step.
  String? _myMapId;
  late final List<Pending> _pending = [...?widget.initialPending];

  /// Guide links still to be handed to Apple Maps.
  ///
  /// Maps takes one link at a time, so a list that needs splitting is opened
  /// across several trips. Held here rather than rebuilt each time, so the
  /// numbering in the guide names cannot drift if the list changes in between.
  final List<String> _queued = [];

  /// How many links the current batch started with, so progress can be counted
  /// forwards rather than reported as a shrinking remainder.
  int _queuedTotal = 0;

  /// What the user may do, rebuilt from [_owned] and [_role] rather than
  /// raised in place. Never assigned directly: see [_recompose].
  Entitlement _entitlement = const Entitlement.free();

  /// Product ids the store has confirmed for this account.
  Set<String> _owned = const {};

  /// Completes when the first read of both purchases and complimentary role is
  /// in. Until then [_entitlement] is the free one because nothing has been
  /// read yet, not because nothing is held — and a share arriving on a cold
  /// start is exactly the moment those two look the same.
  Future<void>? _entitlementSettled;

  /// What this device's complimentary token grants, if it holds one.
  ///
  /// Only [comp.CompRole.admin] changes anything on screen, and only by
  /// changing where the long press goes. Held as state rather than asked for
  /// at the moment of the press so the press cannot pause on a disk read; the
  /// value it is compared against is re-derived from the signature every time
  /// it is set, never remembered as a flag.
  comp.CompRole _role = comp.CompRole.none;

  /// Set when an administrator's access is within days of lapsing because the
  /// server has not been reachable. Null the rest of the time, which is nearly
  /// always — a successful renewal clears it by making the token young again.
  bool _compExpiring = false;
  String? _status;
  bool _busy = false;
  int _readCount = 0;
  int _totalCount = 0;
  Region? _region;

  /// The guide the carried-over places came from, if any. Kept so the combined
  /// guide can be offered the same name.
  late String? _guideName = widget.initialGuideName;

  /// Entries in the pasted guide that carried no usable identifier. Kept so the
  /// summary can be recomposed if the lookup later proves some places gone.
  int _carriedUnusable = 0;

  /// Whether the carried-over places are showing. Collapsed by default: they
  /// are context, and a guide of forty would bury the two places just added.
  bool _showCarried = false;

  /// Distinguishes the two things that report progress the same way — reading
  /// screenshots and matching names against the map.
  bool _lookingUp = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A link may be waiting from before the app was even running.
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeSharedGuide());
    // Both feed [_recompose], and a share landing on a cold start can reach
    // the entitlement before either has answered. Kept as a future so the one
    // path that must not guess can wait for it.
    _entitlementSettled = Future.wait([_syncPurchases(), _refreshCompAccess()]);

    if (widget.initialOverlay != ScreenshotOverlay.none) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        switch (widget.initialOverlay) {
          case ScreenshotOverlay.none:
            break;
          case ScreenshotOverlay.region:
            _confirmRegion('Borough Market, London');
          case ScreenshotOverlay.paywall:
            _offerUnlock(
              PaywallReason.places,
              selected: _pending.where((p) => p.publishable).length,
            );
          case ScreenshotOverlay.search:
            if (_pending.isNotEmpty) _editPlace(0);
          case ScreenshotOverlay.addMenu:
            _addPlaces();
        }
      });
    }
  }

  /// Reached by long-pressing the title. Nothing on screen advertises it, and
  /// a code has to be issued before it does anything — the entry point on its
  /// own is not a way in.
  ///
  /// One press, two destinations. A device that has redeemed an admin code
  /// gets the code console; everyone else gets the box to type a code into.
  /// Nothing distinguishes the two beforehand — no extra gesture, no second
  /// tap, nothing greyed out — so the console is not a locked door that can be
  /// seen, it is a door that is not there.
  ///
  /// Open on every platform, including where there are no guides.
  ///
  /// It used to return immediately on Android, because `littlebird/identity`
  /// had no implementation there and a code could not be redeemed against a
  /// device that could not name itself. That is implemented now, so the box
  /// opens and codes work.
  ///
  /// There is no longer an asymmetry between the platforms here. This comment
  /// used to warn that an ordinary unlock code on Android was accepted and
  /// granted nothing anybody could see, because Android had no paid feature.
  /// It has one now, and [_refreshCompAccess] turns any role other than
  /// [comp.CompRole.none] into [Entitlement.unlocked] without asking which
  /// platform it is on — so an unlock code lifts the three-place cap on
  /// Android exactly as it does on iPhone.
  ///
  /// That is not a detail: it is the route a store reviewer takes. Google will
  /// not buy the product to review it, so the Play "Sign-in details"
  /// declaration hands over a comp code and this is what redeems it.
  Future<void> _compUnlock() async {
    if (_role == comp.CompRole.admin) {
      final token = await comp.heldToken();
      if (token == null || !mounted) return;
      await showAdminSheet(context, token);
      return;
    }
    // Deliberately still offered to someone who has already paid, because an
    // admin code is the one thing worth entering when the app is unlocked
    // already, and refusing to open the box would make it unreachable for the
    // only person who needs it.
    final l = L.of(context);
    final controller = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          l.compAccess,
          style: const TextStyle(fontFamily: Wren.serif),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: l.code),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.cancel, style: const TextStyle(color: Wren.muted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            child: Text(l.unlock),
          ),
        ],
      ),
    );
    if (entered == null || entered.trim().isEmpty || !mounted) return;

    // Redeeming reaches the network, which the rest of the app never does, so
    // it says so rather than appearing to hang.
    setState(() => _status = l.compChecking);
    final outcome = await comp.redeem(entered);
    // Read back from the stored token rather than from the reply, so what the
    // app believes about this device is decided by a signature either way.
    final role = await comp.heldRole();
    if (!mounted) return;

    setState(() {
      switch (outcome) {
        case comp.RedeemOutcome.unlocked:
          _role = role;
          _recompose();
          // A code just redeemed is a token just issued, so whatever the
          // warning was about is over.
          _compExpiring = false;
          // What the code turned on differs by role, and saying "unlocked" to
          // somebody whose code also bought them reading posts would undersell
          // it while telling the next person something untrue.
          _status = _entitlement.reels
              ? l.compEnabledEverything
              : l.compEnabled;
        case comp.RedeemOutcome.refused:
          _status = l.compRefused;
        case comp.RedeemOutcome.toooften:
          _status = l.compTooOften;
        case comp.RedeemOutcome.unreachable:
          _status = l.compUnreachable;
        case comp.RedeemOutcome.untrusted:
          _status = l.compUntrusted;
      }
    });
  }

  /// Empties the list, after asking.
  ///
  /// The confirmation says what is *not* affected as well as what is. "Clear"
  /// beside a list of places the user has just published reads as though it
  /// might reach into Apple Maps and delete the guide, and it does not.
  Future<void> _clearList() async {
    if (_pending.isEmpty) return;
    final l = L.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          l.clearListTitle,
          style: const TextStyle(fontFamily: Wren.serif),
        ),
        content: Text(
          l.clearListBody(_pending.length),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel, style: const TextStyle(color: Wren.muted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 44),
              backgroundColor: Wren.clay,
            ),
            child: Text(l.clearListConfirm),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() {
      _pending.clear();
      // Everything derived from the list goes with it. A guide name left over
      // from a cleared import would silently name the next, unrelated guide.
      _guideName = null;
      _region = null;
      _showCarried = false;
      _queued.clear();
      _status = l.listCleared;
    });
  }

  Future<void> _restoreFromMenu() async {
    final l = L.of(context);
    setState(() => _status = l.checkingAppleAccount);
    final restored = await _restore();
    if (!mounted) return;
    setState(
      () => _status = restored.isEmpty
          ? l.noPreviousPurchase
          : (_entitlement.reels ? l.restoredEverything : l.restoredUnlocked),
    );
  }

  /// Asks the store what this account owns, and folds the answer in.
  ///
  /// The set matters, not merely whether it is empty: an account can hold the
  /// base unlock without holding reading posts, and reporting that as "restored"
  /// while leaving the reel paywall standing is the honest outcome rather than
  /// a bug. Callers decide what a partial restore means for what they were
  /// doing; this only records it.
  Future<Set<String>> _restore() async {
    final restored = await _store.restore();
    if (!mounted) return restored;
    setState(() {
      _owned = {..._owned, ...restored};
      _recompose();
    });
    return restored;
  }

  /// Asks where the batch is, with whatever the captions suggested filled in.
  ///
  /// Confirming beats guessing here. A wrong region is the expensive failure —
  /// it drags every lookup toward the wrong city and each result comes back
  /// looking perfectly valid — and the caption is not always there to read.
  Future<Region?> _confirmRegion(String? detected) async {
    final l = L.of(context);
    final controller = TextEditingController(text: detected ?? '');
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          l.whereAreThesePlaces,
          style: const TextStyle(fontFamily: Wren.serif),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              detected == null ? l.regionNotDetected : l.regionDetected,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: l.cityOrRegion,
                hintText: l.cityExample,
              ),
              onSubmitted: (v) => Navigator.pop(context, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: Text(
              l.searchAnywhere,
              style: const TextStyle(color: Wren.muted),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            child: Text(l.findPlaces),
          ),
        ],
      ),
    );

    if (answer == null || answer.isEmpty) return null;
    return _resolver.locate(answer);
  }

  /// Turns read names into places, and adds them to the list.
  ///
  /// The half the two readers share. A screenshot and a post differ entirely in
  /// how the names are obtained and not at all in what is done with them, and
  /// this is the part that took the longest to get right — the ranked retry,
  /// the duplicate check, the row kept for a name nothing matched. A second
  /// copy of it for posts would drift, and the drift would show up as posts
  /// resolving slightly worse than screenshots for no reason anybody could see.
  ///
  /// Returns null when the lookup itself failed, having already said so; the
  /// caller stops rather than reporting a count.
  Future<({int added, int unmatched})?> _resolveInto(
    List<({List<String> candidates, String all})> readings,
    Region? region,
  ) async {
    final l = L.of(context);
    var unmatched = 0, added = 0;
    for (final r in readings) {
      List<PlaceMatch> matches = const [];
      var readAs = r.candidates.first;
      try {
        // Each candidate in turn until one is found. The resolver paces
        // itself, so this costs time rather than risking a throttle.
        for (final candidate in r.candidates) {
          matches = usable(await _resolver.resolve(candidate, region: region));
          if (matches.isNotEmpty) {
            readAs = candidate;
            break;
          }
        }
      } on ResolverUnavailable catch (e) {
        if (!mounted) return null;
        setState(() {
          _busy = false;
          if (e.unsupported) _noMapHere = true;
          _status = e.throttled
              ? l.rateLimitedDuringImport(added)
              : e.unsupported
              ? l.lookupUnavailable
              : e.message;
        });
        return null;
      }
      if (matches.isEmpty) {
        // Kept, not discarded: the reading is the only record of what was
        // read, and the user can search for it themselves.
        unmatched++;
        _pending.add(Pending(r.candidates.first, null, keep: false));
        continue;
      }
      // Never write silently: Apple replaces the label with its own record,
      // so a wrong match would ship under a confident name.
      if (!_pending.any((p) => matches.first.isSamePlaceAs(p.match))) {
        _pending.add(Pending(readAs, matches.first));
        added++;
      }
    }
    return (added: added, unmatched: unmatched);
  }

  /// Reads screenshots and turns them into places.
  ///
  /// [paths] arrive from the iOS share sheet, where the user has already chosen
  /// the images — so the picker is skipped rather than asking them to choose
  /// again what they just shared. Everything after the choosing is identical,
  /// deliberately: the reading, ranking and city-confirmation are the part that
  /// took the longest to get right and there is no second copy of it.
  Future<void> _importScreenshots({List<String>? paths}) async {
    final l = L.of(context);
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final files =
          paths ?? [for (final f in await _picker.pickMultiImage()) f.path];
      if (files.isEmpty) {
        setState(() {
          _busy = false;
          _status = null;
        });
        return;
      }

      setState(() {
        _totalCount = files.length;
        _readCount = 0;
      });

      // Pass one: read everything, and keep the whole page of text. The caption
      // is the part that says where we are, and it used to be discarded.
      final readings = <({List<String> candidates, String all})>[];
      var unread = 0;
      // Every screenshot is read before any is ranked, because the strongest
      // signal for interface furniture is that it repeats across the batch while
      // places do not. That works in any language and in any app, which a list
      // of English button labels cannot.
      final perShot = <List<TextLine>>[];
      for (final path in files) {
        perShot.add(await Ocr.recognise(path));
        if (mounted) setState(() => _readCount++);
      }
      final furniture = repeatedLines(perShot);

      for (final lines in perShot) {
        // Ranked, not a single guess. A tester's TikTok screenshot put the
        // caption in the largest text and the real place in a small truncated
        // label, so a miss on the front runner now falls through to the next
        // candidate instead of costing the screenshot entirely.
        final ranked = placeCandidates(lines, repeated: furniture);
        if (ranked.isEmpty) {
          unread++;
          continue;
        }
        readings.add((
          candidates: [for (final c in ranked.take(3)) c.text.trim()],
          all: lines.map((l) => l.text).join('\n'),
        ));
      }

      if (readings.isEmpty) {
        setState(() {
          _busy = false;
          _status = l.nothingReadable(files.length);
        });
        return;
      }

      // Pass two: work out where, and have it confirmed.
      final detected = regionHint(
        readings.map((r) => r.all),
        exclude: readings.map((r) => r.candidates.first),
      );
      setState(() => _busy = false);
      if (!mounted) return;
      final region = await _confirmRegion(detected);
      if (!mounted) return;
      setState(() {
        _busy = true;
        _region = region;
      });

      // Pass three: resolve, now that the search knows where to look.
      final outcome = await _resolveInto(readings, region);
      if (outcome == null || !mounted) return;
      final (:added, :unmatched) = outcome;

      setState(() {
        _busy = false;
        _status = [
          l.importSummary(added),
          if (region != null) l.importSummaryIn(region.name),
          if (unmatched > 0) '· ${l.importSummaryNeedLook(unmatched)}',
          if (unread > 0) '· ${l.importSummaryUnreadable(unread)}',
        ].join(' ');
      });
    } on OcrUnavailable catch (e) {
      setState(() {
        _busy = false;
        _status = e.unsupported ? l.ocrUnavailable : e.message;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _status = '$e';
      });
    }
  }

  /// The file's name with its extension taken off, or null when there is
  /// nothing left worth using.
  ///
  /// Only the extensions the importer actually accepts are stripped. Cutting at
  /// the last dot would turn "Lunch. Tokyo.csv" into "Lunch" and "St. John" into
  /// "St", which is a worse name than the one it replaced.
  static String? _titleFrom(String filename) {
    var name = filename;
    for (final ext in const [
      '.csv',
      '.tsv',
      '.kml',
      '.kmz',
      '.gpx',
      '.geojson',
      '.json',
      '.zip',
      '.txt',
    ]) {
      if (name.toLowerCase().endsWith(ext)) {
        name = name.substring(0, name.length - ext.length);
        break;
      }
    }
    return name.trim().nullIfEmpty;
  }

  /// Reads the places out of a guide the user already has, so new ones can be
  /// added to them.
  ///
  /// Only reads. Publishing later makes a *new* guide holding both sets, because
  /// Apple offers no way to add to an existing one from outside Maps — a
  /// limitation the user is told about at the point it matters, in [_publish],
  /// rather than discovered afterwards.
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Sharing a guide out of Apple Maps brings the app forward rather than
  /// starting it, so resuming is when a link usually arrives.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _takeSharedGuide();
    // A phone that is never restarted would otherwise go a fortnight without
    // asking, and lapse while in daily use.
    _refreshCompAccess();
    // Coming back from Maps having just published is the one moment worth
    // asking for a rating, and it is only reachable from here: publishing
    // backgrounds the app, so nothing raised at that point would be seen.
    _reviewPrompt.maybeAsk();
  }

  /// Re-establishes what this device's complimentary token grants.
  ///
  /// Renewing is a no-op for everyone except an administrator whose token is a
  /// day old, so this is a disk read for almost every user and for every user
  /// who has never entered a code at all.
  ///
  /// The entitlement is recomposed afterwards rather than merely raised: see
  /// [_recompose].
  Future<void> _refreshCompAccess() async {
    final role = await comp.renewIfDue();
    final left = await comp.compTimeLeft();
    if (!mounted) return;
    setState(() {
      _role = role;
      _compExpiring = left != null;
      _recompose();
    });
  }

  /// Reads back what the store has already confirmed.
  ///
  /// Separate from [_refreshCompAccess] so neither waits on the other: this is
  /// a disk read that settles in the first frame, while renewing a token can
  /// reach the network for an administrator. Both feed the same recomposition,
  /// so whichever lands second does not undo the first.
  Future<void> _syncPurchases() async {
    final owned = await StoreUnlockStore.cachedProducts();
    if (!mounted) return;
    setState(() {
      _owned = owned;
      _recompose();
    });
    // Ask the store its prices now, and throw the answer away. The first such
    // call opens a billing connection, and on a cold device that took twelve
    // seconds — twelve seconds of a sheet not appearing, measured on an
    // emulator on 2026-09-07. Warmed here it has usually finished long before
    // anybody taps, and if it has not, [_offerUnlock] gives up and shows the
    // advertised price rather than waiting.
    unawaited(_store.price(unlimitedProductId));
  }

  /// Rebuilds [_entitlement] from everything that can grant something.
  ///
  /// Recomposed rather than merely raised, because a token that has just been
  /// withdrawn must not take a *purchase* down with it — somebody can hold
  /// both, and only one of them is revocable. For the same reason nothing
  /// outside this method assigns [_entitlement]: a single `= unlocked()` at a
  /// call site would silently drop whichever of the four inputs it forgot.
  ///
  /// Must be called inside a [setState].
  void _recompose() {
    _entitlement = Entitlement.from(
      boughtUnlimited: _owned.contains(unlimitedProductId),
      boughtReels: _owned.any(reelProductIds.contains),
      compUnlock: _role != comp.CompRole.none,
      // The ladder: an ordinary unlock code grants guides and nothing else.
      // Reels cost money on every use, and a code handed to a friend for
      // guides must not quietly carry that.
      compReels:
          _role == comp.CompRole.everything || _role == comp.CompRole.admin,
    );
  }

  /// Collects whatever the share extension left, and imports it.
  ///
  /// Guarded against running twice over the same share: the native side removes
  /// each item as it hands it over, and [_busy] keeps a resume that lands mid
  /// import from starting a second one.
  ///
  /// Screenshots are taken before a link. Both in one share is unusual, and if
  /// it happens the screenshots are the part that would be lost — a link can be
  /// shared again from Maps in two taps, whereas the extension has already
  /// consumed the images and there is nowhere to get them back from.
  Future<void> _takeSharedGuide() async {
    if (_busy) return;
    final shared = await _shareInbox.take();
    if (shared == null || shared.isEmpty || !mounted) return;

    if (shared.imagePaths.isNotEmpty) {
      await _importScreenshots(paths: shared.imagePaths);
      if (!mounted) return;
    }

    final shareText = shared.link;
    if (shareText != null && shareText.isNotEmpty && mounted) {
      // A share sheet does not promise a bare URL. TikTok wraps the link in a
      // sentence of its own and a person forwarding a message may send a whole
      // paragraph, so the link is pulled out of whatever arrived. When there is
      // none, the original text goes on unchanged — the importer's own "that is
      // not a link" is the right answer then, and better than one about an
      // empty string.
      await _importGuide(shared: firstLinkIn(shareText) ?? shareText);
    }
  }

  /// Asks the Worker to read a shared post, and puts what it says on the list.
  ///
  /// The app cannot read one itself. A share sheet hands over a URL and never
  /// the media, so the video or the slides have to be fetched from somewhere,
  /// and that needs a vendor, a key and a network posture with no business
  /// inside a shipped app. What comes back is *names*, which then take exactly
  /// the path a screenshot's names take — the same region confirmation, the
  /// same resolver, the same list you can correct. Wren never receives the
  /// media, never stores it and never shows it, and that is what keeps the
  /// feature inside Apple's rules as much as it is what keeps it cheap.
  ///
  /// Every call costs real money, so nothing is sent until the entitlement is
  /// held and the link is one the feature can read.
  Future<void> _importReel(String link) async {
    final l = L.of(context);
    // A share can arrive before the first frame has finished, which is before
    // either source of entitlement has been read from disk. Raising the paywall
    // at somebody who has paid is the failure this avoids, and it is the
    // ordinary case rather than an edge one: a cold start is what a share does.
    await _entitlementSettled;
    if (!mounted) return;
    if (!_entitlement.reels) {
      if (await _sell(PaywallReason.reels) != _Gate.through) return;
      if (!mounted) return;
    }

    final auth = await _reelAuth();
    if (!mounted) return;
    if (auth == null) {
      // Entitled by something that left no proof: a purchase made before this
      // version existed, so the receipt was never kept. Restoring asks the
      // store for it again, which is the only way to get one.
      setState(() => _status = l.reelNeedsRestore);
      return;
    }

    setState(() {
      _busy = true;
      _status = l.readingPost;
    });
    final ReelReading reading;
    try {
      reading = await readReel(link, auth: auth, send: widget.reelSender);
    } on ReelFailed catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = _reelFailure(l, e);
      });
      return;
    }
    if (!mounted) return;

    // The city, confirmed rather than assumed, exactly as for screenshots — a
    // wrong region is the expensive failure, because it drags every lookup
    // toward the wrong place and each result comes back looking valid. A post
    // naming ten castles in seven countries has no single region and arrives
    // here with none, which is a real answer and not a missing one.
    setState(() => _busy = false);
    final region = await _confirmRegion(reading.regionHint);
    if (!mounted) return;
    setState(() {
      _busy = true;
      _region = region;
    });

    final outcome = await _resolveInto([
      for (final c in reading.candidates)
        (
          // One name per candidate rather than a ranked three: the model has
          // already chosen, and a screenshot's alternatives exist because OCR
          // cannot tell a caption from a sign.
          candidates: [
            if (c.city != null && c.city!.isNotEmpty)
              '${c.name}, ${c.city}'
            else
              c.name,
            c.name,
          ],
          all: c.name,
        ),
    ], region);
    if (outcome == null || !mounted) return;
    final (:added, :unmatched) = outcome;

    setState(() {
      _busy = false;
      _status = [
        l.importSummary(added),
        if (region != null) l.importSummaryIn(region.name),
        if (unmatched > 0) '· ${l.importSummaryNeedLook(unmatched)}',
        if (reading.used != null && reading.limit != null)
          '· ${l.reelsLeftThisMonth(reading.limit! - reading.used!)}',
      ].join(' ');
    });
  }

  /// The proof this device can show that it is allowed to spend the money.
  ///
  /// Nothing here is trusted by the server — it verifies an App Store
  /// transaction against Apple's certificate chain, a Play token against
  /// Google, a complimentary token against the signing key — which is exactly
  /// why the app can hand it over without the app having to be trustworthy.
  ///
  /// A purchase is preferred over a complimentary token because it is the
  /// user's own and cannot be withdrawn.
  Future<ReelAuth?> _reelAuth() async {
    final proof = await StoreUnlockStore.reelProof();
    if (proof != null) {
      return proof.store == 'play'
          ? ReelAuth.play(proof.proof, proof.productId)
          : ReelAuth.appStore(proof.proof);
    }
    if (!_entitlement.reels) return null;
    final token = await comp.heldToken();
    return token == null ? null : ReelAuth.comp(token);
  }

  /// What to say when a post could not be read.
  ///
  /// Each reason gets its own sentence. Collapsing two of them would mean
  /// telling somebody to try screenshots when the real answer is that they have
  /// used their allowance for the month — advice that cannot work, about a
  /// problem they do not have.
  String _reelFailure(L l, ReelFailed e) => switch (e.reason) {
    // The allowance rolls over a trailing thirty days rather than resetting on
    // the first, so this says a date. The date is formatted by the platform,
    // because "5 September" and "September 5" are both correct and which one
    // is right is not a decision this app should be making.
    ReelFailure.quotaExceeded => l.reelQuotaUsedUp(
      e.resetsAt == null
          ? l.reelQuotaSoon
          : MaterialLocalizations.of(context).formatFullDate(e.resetsAt!),
    ),
    ReelFailure.busy => l.reelBusy,
    ReelFailure.postUnavailable => l.reelUnavailable,
    ReelFailure.nothingFound => l.reelNoPlaces,
    ReelFailure.unreachable => l.reelUnreachable,
    // Everything else, including anything the server learns to say later. This
    // is the one whose copy offers the screenshot path, which is the advice
    // that helps whatever actually went wrong.
    ReelFailure.notEntitled ||
    ReelFailure.unsupported ||
    ReelFailure.fetchFailed => l.reelCouldNotRead,
  };

  /// [shared] arrives from the iOS share sheet, where the user has already
  /// chosen the guide — so the paste dialog is skipped rather than asking them to
  /// hand over something they just handed over.
  Future<void> _importGuide({String? shared}) async {
    final l = L.of(context);
    final controller = TextEditingController();
    final pasted =
        shared ??
        await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              _makesGuides ? l.importLinkTitle : l.fromPost,
              style: const TextStyle(fontFamily: Wren.serif),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _makesGuides ? l.importGuideBody : l.importPostBody,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLines: 2,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(labelText: l.linkLabel),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  l.cancel,
                  style: const TextStyle(color: Wren.muted),
                ),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                child: Text(l.readLink),
              ),
            ],
          ),
        );
    if (pasted == null || pasted.trim().isEmpty || !mounted) return;

    // Apple's share sheet gives a short link with an opaque id and no payload,
    // so it has to be expanded before there is anything to read. Told plainly
    // that this is happening, because it reaches the network and is the one
    // slow step in an otherwise instant flow.
    var link = pasted.trim();

    // Answered before anything is parsed, because the parser's answer would be
    // about Apple Maps and the question was not. Wren is in the share sheet of
    // every app that shares a link, and the first screen asks for reels and
    // posts by name, so this arrives often.
    //
    // Three of those platforms Wren now reads. The rest still get the advice
    // about screenshots, which is the true answer for them: it is the same
    // sentence it always was, and it is now said to fewer people.
    if (isReelLink(link)) {
      await _importReel(link);
      return;
    }
    if (isSocialPostLink(link)) {
      setState(() => _status = l.importGuideSocialPost);
      return;
    }

    if (isShortGuideLink(link)) {
      setState(() => _status = l.expandingLink);
      try {
        link = await _expander.expand(link);
      } on LinkExpandFailed catch (e) {
        if (!mounted) return;
        setState(
          () => _status = e.offline ? l.linkUnreachable : l.importGuideNotALink,
        );
        return;
      }
      if (!mounted) return;
    }

    final ImportedGuide guide;
    try {
      guide = importGuideLink(link);
    } on GuideLinkFormat {
      // Deliberately not the parser's own message. It says things like "field
      // runs past the end", which is the right thing to have in a log and the
      // wrong thing to put in front of someone who pasted the wrong text.
      setState(() => _status = l.importGuideNotALink);
      return;
    }

    if (guide.places.isEmpty) {
      setState(() => _status = l.importGuideNothing);
      return;
    }

    setState(() {
      var added = 0;
      for (final p in guide.places) {
        if (_pending.any((o) => o.match?.id == p.id)) continue;
        _pending.add(
          Pending(
            p.name,
            // Apple's own name and id, straight out of the guide. There is no
            // address in the payload; the row shows the name alone rather than
            // an empty line where one should be.
            PlaceMatch(id: p.id, name: p.name, address: ''),
            origin: Origin.guide,
          ),
        );
        added++;
      }
      if (guide.name.isNotEmpty) _guideName = guide.name;
      _carriedUnusable = guide.unusable;
      _status = [
        l.importedGuideSummary(added),
        if (guide.unusable > 0) '· ${l.importedGuideUnusable(guide.unusable)}',
      ].join(' ');
    });

    await _nameCarriedPlaces();
  }

  /// Fills in the names of imported places, which the payload does not carry.
  ///
  /// Deliberately after the import has already been reported. The places are
  /// usable without names — the identifier is all a guide link needs — so the
  /// count appears immediately and the labels arrive when they arrive. Making
  /// the user wait on a lookup for something cosmetic would be the wrong trade.
  Future<void> _nameCarriedPlaces() async {
    // Carried places come out of a guide link, so every one of them has an
    // Apple id and nothing else -- that is the whole payload. The id filter is
    // a type requirement rather than a real condition.
    final nameless = _pending
        .where(
          (p) =>
              p.origin == Origin.guide &&
              p.match?.id != null &&
              (p.match?.name ?? '').isEmpty,
        )
        .toList();
    if (nameless.isEmpty) return;

    final result = await _resolver.lookup([
      for (final p in nameless) p.match!.id!,
    ]);
    if (result.isEmpty || !mounted) return;
    final l = L.of(context);

    // Only `gone` is evidence. Apple answered about these and has no record, so
    // they cannot appear in any guide made from this list — Apple drops them on
    // arrival, silently, which is why an 82-place guide came back as 80 with
    // nothing to explain the difference. Dropping them here makes the count the
    // user is shown the count they actually get.
    //
    // `failed` is never pruned. Those requests did not complete, which says
    // nothing about whether the place exists, and treating a network hiccup as
    // proof of death would delete places that are perfectly alive.
    final gone = nameless.where((p) => result.gone.contains(p.match!.id));

    setState(() {
      for (final p in nameless) {
        final match = result.found[p.match!.id];
        if (match != null) p.match = match;
      }
      if (gone.isNotEmpty) {
        final dropped = gone.length;
        // Logged by identifier, because that is the only thing left of them.
        // Apple has no record, so there is no name to show and nothing to look
        // up: a dropped place is a bare muid or it is nothing. Printed rather
        // than shown, since the alternative is putting raw hex in front of
        // someone who wanted a list of restaurants.
        debugPrint(
          'WREN-GONE ${result.gone.length} place(s) Apple no longer serves: '
          '${result.gone.map((id) => id.toString()).join(', ')}',
        );
        _pending.removeWhere((p) => result.gone.contains(p.match?.id));
        final carried = _pending.where((p) => p.origin == Origin.guide).length;
        _status = [
          l.importedGuideSummary(carried),
          '· ${l.importedGuideUnusable(_carriedUnusable + dropped)}',
        ].join(' ');
      }
    });
  }

  /// Imports a list exported from another app.
  ///
  /// The file gives names and, usually, coordinates — never Apple place ids, so
  /// every row still goes through the same map lookup an OCR reading does. The
  /// coordinate is worth having anyway: it aims each search individually, which
  /// is better than the one region a batch of screenshots shares, and it is why
  /// a file of places spread across three cities imports correctly.
  Future<void> _importFile() async {
    final l = L.of(context);
    setState(() {
      _busy = true;
      _status = null;
    });

    final PlaceFileResult read;
    // Kept beyond the try, because the file's own name is the fallback title
    // and the parser's own title is only known afterwards.
    final String pickedName;
    try {
      final picked = await _files.pick();
      if (picked == null || !mounted) {
        setState(() => _busy = false);
        return;
      }
      pickedName = picked.name;
      read = readPlaceFile(picked.text, filename: picked.name);
    } on PlaceFileFormat {
      // Same reasoning as the guide link: the parser's complaint is precise and
      // useless here. What helps is knowing which formats work.
      setState(() {
        _busy = false;
        _status = l.fileUnreadable;
      });
      return;
    } on FileSourceUnavailable catch (e) {
      setState(() {
        _busy = false;
        _status = e.unsupported ? l.fileUnreadable : e.message;
      });
      return;
    } catch (e) {
      setState(() {
        _busy = false;
        _status = '$e';
      });
      return;
    }

    if (read.places.isEmpty) {
      setState(() {
        _busy = false;
        _status = l.fileNoPlaces;
      });
      return;
    }

    setState(() {
      _lookingUp = true;
      _totalCount = read.places.length;
      _readCount = 0;
      // The parser has always returned this — a GeoJSON collection name, a KML
      // document name — and this method quietly dropped it, so importing
      // 8-places.geojson offered no guide name at all. Only taken when there is
      // not already one from an imported guide, which is the stronger claim.
      //
      // Failing that, the file's own name. A CSV carries no title inside it,
      // so a list exported as "Saved places.csv" used to arrive in the other
      // map app called "Places" — or "Places1", once the second one landed.
      // The name the user already gave the file is better than a word Wren
      // made up, and on iOS it is only ever a suggestion in a box they can
      // edit.
      final title = read.title?.trim().nullIfEmpty ?? _titleFrom(pickedName);
      _guideName ??= title;
    });

    var unmatched = 0, added = 0, positioned = 0;
    for (final place in read.places) {
      // What the file said, kept whether or not the map can be asked. This is
      // the fallback that makes an import useful with no lookup at all.
      final own = ExportPlace(
        name: place.name,
        address: place.address ?? '',
        lat: place.lat,
        lon: place.lon,
      );

      List<PlaceMatch> matches;
      try {
        matches = usable(
          await _resolver.resolve(place.query, region: _regionFor(place)),
        );
      } on ResolverUnavailable catch (e) {
        // No map to ask. A file that carried coordinates does not need one, so
        // take the rest of it at its word rather than abandoning the import —
        // which is what used to happen on every platform without MapKit.
        if (e.unsupported) {
          _noMapHere = true;
          for (final rest in read.places.skip(positioned + unmatched + added)) {
            final own = ExportPlace(
              name: rest.name,
              address: rest.address ?? '',
              lat: rest.lat,
              lon: rest.lon,
            );
            if (!own.hasCoordinate) {
              unmatched++;
              _pending.add(
                Pending(rest.name, null, keep: false, origin: Origin.file),
              );
              continue;
            }
            positioned++;
            _pending.add(
              Pending(rest.name, null, origin: Origin.file, fromFile: own),
            );
          }
          setState(() {
            _busy = false;
            _lookingUp = false;
            _status = [
              if (positioned > 0) l.fileImportPositioned(positioned),
              if (added > 0) l.fileImportSummary(added),
              if (unmatched > 0) '· ${l.importSummaryNeedLook(unmatched)}',
            ].join(' ');
          });
          return;
        }
        setState(() {
          _busy = false;
          _lookingUp = false;
          _status = e.throttled ? l.rateLimitedDuringImport(added) : e.message;
        });
        return;
      }
      if (!mounted) return;
      setState(() => _readCount++);

      if (matches.isEmpty) {
        // The map does not know it. If the file positioned it, that is still
        // enough to send elsewhere, so keep it rather than only counting it.
        if (own.hasCoordinate) {
          positioned++;
          _pending.add(
            Pending(place.name, null, origin: Origin.file, fromFile: own),
          );
        } else {
          unmatched++;
          _pending.add(
            Pending(place.name, null, keep: false, origin: Origin.file),
          );
        }
        continue;
      }
      if (!_pending.any((p) => p.match?.id == matches.first.id)) {
        _pending.add(
          Pending(
            place.name,
            matches.first,
            origin: Origin.file,
            // Kept even when the map answered: Apple's record has the better
            // coordinate, but if it arrives without one the file's still works.
            fromFile: own.hasCoordinate ? own : null,
          ),
        );
        added++;
      }
    }

    setState(() {
      _busy = false;
      _lookingUp = false;
      _status = [
        l.fileImportSummary(added),
        if (positioned > 0) '· ${l.fileImportPositioned(positioned)}',
        if (unmatched > 0) '· ${l.importSummaryNeedLook(unmatched)}',
        if (read.skipped > 0) '· ${l.fileImportSkipped(read.skipped)}',
      ].join(' ');
    });
  }

  /// Where to centre the search for one row of a file.
  ///
  /// The file's own coordinate wins when it has one: a per-place centre is
  /// strictly better than the batch region, and a file may span countries. The
  /// name is left empty so nothing invented is appended to the query — only the
  /// coordinate is a fact here.
  Region? _regionFor(FilePlace place) {
    final lat = place.lat, lon = place.lon;
    if (lat == null || lon == null) return _region;
    return Region(name: '', lat: lat, lon: lon);
  }

  Future<String?> _askGuideName(int count, {String? initial}) async {
    final l = L.of(context);
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          l.nameThisGuide,
          style: const TextStyle(fontFamily: Wren.serif),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.nameThisGuideBody(count),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 60,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: l.guideName,
                hintText: l.guideNameExample,
              ),
              onSubmitted: (v) {
                if (v.trim().isNotEmpty) Navigator.pop(context, v.trim());
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.cancel, style: const TextStyle(color: Wren.muted)),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) Navigator.pop(context, name);
            },
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            child: Text(l.createGuide),
          ),
        ],
      ),
    );
  }

  /// The purchase sheet, in one of its three jobs.
  ///
  /// [reason] decides what is being sold, and that is not a marketing choice.
  /// Somebody stopped by the three-place cap is served by the cheaper unlock,
  /// so that is the button they get, with the bundle offered underneath as the
  /// larger option rather than in place of it. Somebody who shared a post has
  /// no cheaper option, because nothing else grants reading one.
  ///
  /// [carried] is how many places came out of a guide the user already keeps.
  /// When there are any, the sheet is selling the combined guide rather than the
  /// size cap, and it deliberately does **not** offer "save the first three
  /// instead": that option exists to trim what Wren found, and applying it here
  /// would publish a guide missing places the user already had. There is no
  /// smaller version of combining to fall back to.
  Future<_UnlockAnswer> _offerUnlock(
    PaywallReason reason, {
    int selected = 0,
    int carried = 0,
  }) async {
    final l = L.of(context);
    final offers = offersFor(reason, _entitlement);
    // Nothing left to sell. Reached when a purchase landed while the sheet was
    // being prepared, and by the caller that has already checked -- never
    // shown, because a sheet with no button is the app failing to explain
    // itself.
    if (offers.isEmpty) return const _UnlockAnswer(_UnlockChoice.cancel);

    // One round trip for every price the sheet shows, together, so the two
    // figures do not appear one after the other — and bounded, because a sheet
    // that does not appear is worse than one quoting the advertised price. The
    // store is normally warm by now: see [_syncPurchases].
    final prices = await Future.wait(offers.map(_store.price)).timeout(
      const Duration(seconds: 6),
      onTimeout: () => List<String?>.filled(offers.length, null),
    );
    if (!mounted) return const _UnlockAnswer(_UnlockChoice.cancel);
    final priced = [
      for (var i = 0; i < offers.length; i++)
        (id: offers[i], price: prices[i] ?? fallbackPriceOf(offers[i])),
    ];

    final reels = reason == PaywallReason.reels;
    final combining = carried > 0;
    final over = _entitlement.overBy(selected);
    final choice = await showModalBottomSheet<_UnlockAnswer>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const WrenMark(size: 44),
              const SizedBox(height: 16),
              Text(
                reels
                    ? l.reelsTitle
                    : combining
                    ? l.unlockCombineTitle
                    : (_makesGuides ? l.guidesOfAnySize : l.anyNumberOfPlaces),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 10),
              // Only said when it is true. Opened from the menu with an empty
              // list, "you have 0 selected -- -3 more than that" is nonsense,
              // and the sheet still has a job to do: show what the purchase is
              // and what it costs.
              if (reels || combining || selected > 0) ...[
                Text(
                  reels
                      ? l.reelsExplain
                      : combining
                      ? l.unlockCombineBody(carried)
                      : (_makesGuides
                            ? l.unlockExplain(freePlaceLimit, selected, over)
                            : l.unlockExplainAndroid(
                                freePlaceLimit,
                                selected,
                                over,
                              )),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 6),
              ],
              Text(
                l.onePaymentKept,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 22),
              for (final (i, offer) in priced.indexed) ...[
                if (i > 0) const SizedBox(height: 10),
                // The price string comes from the store already formatted for
                // the storefront, so it is never reformatted here.
                if (i == 0)
                  FilledButton(
                    onPressed: () => Navigator.pop(
                      context,
                      _UnlockAnswer(_UnlockChoice.buy, productId: offer.id),
                    ),
                    child: Text(_buyLabel(l, offer.id, offer.price)),
                  )
                else
                  OutlinedButton(
                    onPressed: () => Navigator.pop(
                      context,
                      _UnlockAnswer(_UnlockChoice.buy, productId: offer.id),
                    ),
                    child: Text(_buyLabel(l, offer.id, offer.price)),
                  ),
                // Said once, under the button it belongs to: the bundle costs
                // more than the thing that was asked for, and the difference
                // has to be visible or the larger button is a trap.
                if (offer.id == everythingProductId && i > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      l.everythingAlsoReadsPosts,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
              // Trimming to the free cap is only an option when there is
              // something to trim, and never when a post is what was asked for
              // -- there is no partial reading of one.
              if (!reels && !combining && selected > freePlaceLimit) ...[
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () => Navigator.pop(
                    context,
                    const _UnlockAnswer(_UnlockChoice.publishFree),
                  ),
                  child: Text(l.saveFirstInstead(freePlaceLimit)),
                ),
              ],
              const SizedBox(height: 2),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(
                    context,
                    const _UnlockAnswer(_UnlockChoice.restore),
                  ),
                  child: Text(
                    l.restorePrevious,
                    style: const TextStyle(color: Wren.muted),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return choice ?? const _UnlockAnswer(_UnlockChoice.cancel);
  }

  /// What a purchase button says. Each product is named by what it does, not by
  /// its place in a ladder -- "Upgrade" would mean nothing to somebody who has
  /// forgotten which of three things they own.
  String _buyLabel(L l, String productId, String price) => switch (productId) {
    everythingProductId => l.everythingFor(price),
    reelsUpgradeProductId => l.addPostsFor(price),
    _ => l.unlockFor(price),
  };

  /// Raises the sheet, does whatever it was answered with, and says whether the
  /// caller may now go on.
  ///
  /// One method rather than the three near-identical copies this replaced. Each
  /// copy raised the entitlement by hand on success, which was survivable while
  /// there was one product and is not now: buying the upgrade does not grant
  /// the same thing as buying the bundle, and a restore can return neither, one
  /// or both. So the outcome is decided by asking [_entitlement] again after
  /// recomposing it, never by the fact that a call succeeded.
  Future<_Gate> _sell(
    PaywallReason reason, {
    int selected = 0,
    int carried = 0,
  }) async {
    final l = L.of(context);
    final answer = await _offerUnlock(
      reason,
      selected: selected,
      carried: carried,
    );
    if (!mounted) return _Gate.stop;
    switch (answer.choice) {
      case _UnlockChoice.buy:
        if (!await _store.buy(answer.productId!)) {
          if (mounted) setState(() => _status = l.purchaseDidNotComplete);
          return _Gate.stop;
        }
        if (!mounted) return _Gate.stop;
        // Folded in from the answer rather than re-read from the cache. The
        // store is the authority on what was bought and it has just said so;
        // going back to disk would make this depend on a write the injected
        // store knows nothing about.
        setState(() {
          _owned = {..._owned, answer.productId!};
          _recompose();
        });
      case _UnlockChoice.restore:
        final restored = await _restore();
        if (!mounted) return _Gate.stop;
        if (restored.isEmpty) {
          setState(() => _status = l.noPreviousPurchase);
          return _Gate.stop;
        }
      case _UnlockChoice.publishFree:
        return _Gate.trimmed;
      case _UnlockChoice.cancel:
        return _Gate.stop;
    }
    if (!mounted) return _Gate.stop;
    if (_satisfies(reason)) return _Gate.through;
    // A restore that found the base unlock when a post was what was wanted.
    // Real, worth saying, and still short of what was asked for -- so it says
    // what came back rather than "no previous purchase", and stops.
    setState(() => _status = l.restoredUnlocked);
    return _Gate.stop;
  }

  /// Whether what is held now covers what the sheet was raised about.
  bool _satisfies(PaywallReason reason) => switch (reason) {
    PaywallReason.places => _entitlement.unlimited,
    PaywallReason.reels => _entitlement.reels,
  };

  /// Opens the lookup for a row — to correct a wrong match, or to find one that
  /// was never made.
  Future<void> _editPlace(int index) async {
    final l = L.of(context);
    final p = _pending[index];
    final chosen = await showModalBottomSheet<PlaceMatch>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => PlaceSearchSheet(
        readAs: p.readAs,
        resolver: _resolver,
        region: _region,
        initialQuery: p.match?.name ?? p.readAs,
      ),
    );
    if (chosen == null || !mounted) return;

    final duplicate = _pending.indexWhere(
      (o) => o != p && chosen.isSamePlaceAs(o.match),
    );
    setState(() {
      p.match = chosen;
      p.keep = true;
      if (duplicate >= 0) {
        _status = l.alreadyInTheList(chosen.name);
      }
    });
  }

  /// Opens the purchase from the menu, with or without a list.
  ///
  /// The same sheet the publish flow raises, so there is one description of
  /// what is being bought and one price, formatted by the store for the
  /// storefront.
  ///
  /// No banner on success: the menu items disappear the moment the entitlement
  /// covers them, which says it without a line of copy that would have needed
  /// translating into another forty-eight languages to say it.
  Future<void> _unlockFromMenu(PaywallReason reason) async {
    final selected = _pending.where((p) => p.publishable).length;
    // The gate's answer is discarded deliberately. It says whether the caller
    // may go on, and the menu was not on the way to anything -- buying here
    // unlocks and stops, because the user did not ask to publish or read
    // anything.
    await _sell(reason, selected: selected);
  }

  /// Warns that a combined guide is a new guide, before one is made.
  ///
  /// Apple's guide link carries no guide identity, so there is nothing to add
  /// to — publishing always creates. Saying so beforehand is the difference
  /// between an understood limitation and an apparent duplicate.
  Future<bool> _confirmRepublish(int total) async {
    final l = L.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          l.republishTitle,
          style: const TextStyle(fontFamily: Wren.serif),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.republishBody(total),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 10),
            Text(
              l.republishThenDelete,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            // The list is not cleared after publishing, so a guide deleted in
            // error can be made again in one tap. Worth saying, because
            // "delete the old one" is otherwise a frightening instruction.
            Text(
              l.republishKeepsPlaces,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel, style: const TextStyle(color: Wren.muted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            child: Text(l.makeCombinedGuide),
          ),
        ],
      ),
    );
    return go ?? false;
  }

  /// Offers the places to another map app.
  ///
  /// Android only in practice: on iOS the destination is Apple Maps and that is
  /// what [_publish] already does.
  ///
  /// Capped, at [freePlaceLimit], exactly as publishing a guide is.
  ///
  /// This used to be free at any size, on the reasoning that the cap sold an
  /// Apple Maps feature and Android has no guides. That reasoning was sound
  /// about the *mechanism* and wrong about the *product*: the two stores carry
  /// one product at one price, and a free tier that differed by platform would
  /// make them two different apps sharing a name. The unit being sold is
  /// "more than three places at once", which both platforms have.
  ///
  /// What the unlock buys here is one thing, not two. There is no guide to
  /// combine with, so the combining half of the iOS purchase has no Android
  /// equivalent — which is why the sheet is opened with `carried: 0` and shows
  /// the size copy rather than the combining copy.
  ///
  /// Named apps are listed first, but only if they are actually installed —
  /// and "installed" here means installed AND declared in the manifest's
  /// `<queries>`, because from Android 11 the two are the same answer. Anything not listed still reaches the same file through the system
  /// chooser, so the long tail works without Wren claiming to have tested it.
  Future<void> _sendPlacesElsewhere() async {
    final l = L.of(context);
    var places = [
      for (final p in _pending.where((p) => p.exportable)) p.forExport,
    ].whereType<ExportPlace>().toList();
    if (places.isEmpty) return;

    // The same gate publishing uses, so the two platforms cannot drift.
    switch (_entitlement.check(places.length)) {
      case PublishBlock.nothingSelected:
        return;
      case PublishBlock.needsUnlock:
        switch (await _sell(PaywallReason.places, selected: places.length)) {
          case _Gate.through:
            break;
          case _Gate.trimmed:
            places = places.take(freePlaceLimit).toList();
          case _Gate.stop:
            return;
        }
      case PublishBlock.none:
        break;
    }
    if (!mounted) return;

    // Ask the platform which of the named apps are really there. One call per
    // app, all at once, before the sheet is drawn.
    final found = <String, String>{};
    for (final t in namedTargets) {
      final pkg = await _sharer.firstInstalled(t.packages);
      if (pkg != null) found[t.id] = pkg;
    }
    if (!mounted) return;

    final chosen = await showModalBottomSheet<MapTarget>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
                child: Text(
                  l.sendPlacesTo,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  l.sendPlacesReady(places.length),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              for (final t in namedTargets)
                if (found.containsKey(t.id))
                  ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(t.name),
                    subtitle: t.note.isEmpty ? null : Text(t.note),
                    onTap: () => Navigator.pop(context, t),
                  ),
              // Google Maps is always offered, because the route is a web page
              // rather than an installed app.
              ListTile(
                leading: const Icon(Icons.public),
                title: Text(googleMapsTarget.name),
                subtitle: Text(googleMapsTarget.note),
                onTap: () => Navigator.pop(context, googleMapsTarget),
              ),
              const Divider(height: 8),
              ListTile(
                leading: const Icon(Icons.ios_share),
                title: Text(l.sendPlacesOtherApp),
                onTap: () => Navigator.pop(context, null),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;

    // Dismissed with the chooser row, or by swiping down. The chooser is the
    // safe default either way; a swipe simply does nothing.
    //
    // GPX for the chooser as well as for the named apps: it is what all of them
    // read as individual named places, and the one format that is never mistaken
    // for a route.
    final file = exportPlaces(
      places,
      chosen?.format ?? PlaceFormat.gpx,
      title: _guideName ?? 'Places',
    );

    if (chosen?.id == googleMapsTarget.id) {
      await _sendToGoogleMaps(file, l);
      return;
    }

    final outcome = chosen == null
        ? await _sharer.share(file, subject: _guideName ?? 'Places')
        : await _sharer.shareTo(file, chosen, found[chosen.id]!);
    if (!mounted) return;
    setState(() {
      _status = switch (outcome) {
        // "sent" is a hand-off, never an import: not one of these apps reports
        // back, so claiming success on their behalf would be a guess.
        ShareOutcome.sent => [
          l.sendPlacesReady(file.written),
          if (file.droppedForNoCoordinate > 0)
            '· ${l.sendPlacesNoLocation(file.droppedForNoCoordinate)}',
        ].join(' '),
        ShareOutcome.noHandler => l.sendPlacesFailed,
        ShareOutcome.unavailable => l.sendPlacesFailed,
      };
    });

    // Handing the file over is this platform's "it worked" moment, the same
    // way a guide opening in Maps is on iOS. Only arms the rating ask; the
    // prompt itself waits for the user to come back from the other app.
    if (outcome == ShareOutcome.sent) await _reviewPrompt.recordSuccess();
  }

  /// The Google Maps route: save a CSV, then open My Maps in a Custom Tab.
  ///
  /// A CSV rather than a GPX because Google geocodes a name or address column
  /// itself on import, so nothing here needs a coordinate — which is the only
  /// reason this path costs nothing to run.
  ///
  /// **Saved, not shared, and in this order.** Sharing was wrong twice over,
  /// both proven on a device: the chooser opened with no targets at all, because
  /// nothing on a plain Android device volunteers to receive a CSV; and the
  /// Custom Tab launched straight over the top of it, so even a working chooser
  /// would have been buried before it could be used. The browser's file picker
  /// is the next step, so the file has to be somewhere the user chose and can
  /// find again.
  ///
  /// If the save is cancelled, the tab does not open. Landing somebody on an
  /// import page with nothing to import is worse than doing nothing.
  Future<void> _sendToGoogleMaps(ExportResult file, L l) async {
    final saved = await _saver.save(
      file.bytes,
      name: file.fileName,
      mimeType: file.format.mimeType,
    );
    if (!mounted || !saved) return;
    await _sharer.openTab(myMapsUrl(mapId: _myMapId));
    if (!mounted) return;
    setState(() => _status = l.sendPlacesReady(file.written));
  }

  Future<void> _publish() async {
    final l = L.of(context);

    // A batch that had to be split is still being handed over, one link per
    // trip to Maps. Finish it before building anything new, or the second half
    // of a guide would be replaced by a fresh first half.
    if (_queued.isNotEmpty) {
      await _open(_queued.removeAt(0), l);
      return;
    }

    var keep = _pending.where((p) => p.publishable).toList();
    if (keep.isEmpty) return;

    // Places carried over from an existing guide are not counted against the
    // size cap — the cap limits what Wren found, and counting them would make
    // importing a guide of twenty trip a limit built for three. Combining is
    // gated on its own instead, below, because it is the paid feature rather
    // than a bigger version of the free one.
    final billable = keep.where((p) => p.billable).length;
    final carried = keep.length - billable;

    // Nothing new, so there is nothing to add and republishing the guide
    // unchanged would only leave a duplicate in Maps. Checked before the
    // paywall, not after: offering the purchase first and finding this out
    // afterwards would have taken the money and made the duplicate anyway.
    if (billable == 0) {
      setState(() => _status = l.importGuideNothing);
      return;
    }

    // Combining needs the unlock, whatever the counts. Checked before the size
    // cap so someone with two carried places and one new is asked about the
    // thing they are actually doing.
    final block = carried > 0 && !_entitlement.unlimited
        ? PublishBlock.needsUnlock
        : _entitlement.check(billable);

    switch (block) {
      case PublishBlock.nothingSelected:
        return;
      case PublishBlock.needsUnlock:
        switch (await _sell(
          PaywallReason.places,
          selected: billable,
          carried: carried,
        )) {
          case _Gate.through:
            break;
          case _Gate.trimmed:
            // Only reachable when nothing was carried over — the sheet does not
            // offer this while combining, because trimming to the cap would
            // drop places out of a guide the user already had. Asserted rather
            // than assumed, since the two paths meet here.
            assert(carried == 0);
            keep = keep.where((p) => p.billable).take(freePlaceLimit).toList();
          case _Gate.stop:
            return;
        }
      case PublishBlock.none:
        break;
    }

    // Safe to force: `publishable` is now exactly "Apple has identified this",
    // so both the match and its id are present by construction.
    final places = keep
        .map((p) => GuidePlace(id: p.match!.id!, name: p.match!.name))
        .toList();

    final String url;
    if (places.length == 1 && carried == 0) {
      url = buildPlaceLink(places.single.id);
    } else {
      if (carried > 0 && !await _confirmRepublish(places.length)) return;
      if (!mounted) return;
      // Offered the old guide's name, since the combined guide is meant to
      // replace it. Still editable — the trip may have outgrown the name.
      final name = await _askGuideName(places.length, initial: _guideName);
      if (name == null) return;

      final links = buildGuideLinks(name, places);
      if (links.length > 1) {
        // This used to be `.first`, which published the first fifty places and
        // threw the rest away without a word. An 82-place guide imported from
        // Apple Maps would have lost thirty-two of them.
        if (!await _confirmSplit(links.length, places.length)) return;
        if (!mounted) return;
      }
      _queued
        ..clear()
        ..addAll(links);
      _queuedTotal = links.length;
      url = _queued.removeAt(0);
    }

    await _open(url, l);
  }

  /// Hands one link to Apple Maps and says where that leaves things.
  Future<void> _open(String url, L l) async {
    if (!await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    )) {
      setState(() => _status = l.couldNotOpenMaps);
      return;
    }
    if (!mounted) return;
    if (_queued.isNotEmpty) {
      // Maps takes one link per trip, so the rest wait behind the same button.
      setState(
        () => _status = l.splitProgress(
          _queuedTotal - _queued.length,
          _queuedTotal,
        ),
      );
    } else {
      _queuedTotal = 0;
      // The guide is in Maps, whole. Only arms the ask — the user is looking at
      // Maps right now, so the prompt itself waits for them to come back.
      await _reviewPrompt.recordSuccess();
    }
  }

  /// Explains why several guides are about to appear instead of one.
  Future<bool> _confirmSplit(int guides, int places) async {
    final l = L.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          l.splitTitle,
          style: const TextStyle(fontFamily: Wren.serif),
        ),
        content: Text(
          l.splitBody(guides, places),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel, style: const TextStyle(color: Wren.muted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            child: Text(l.splitConfirm(guides)),
          ),
        ],
      ),
    );
    return go ?? false;
  }

  /// Which of the three sources to add from.
  Future<void> _addPlaces() async {
    final l = L.of(context);
    final choice = await showModalBottomSheet<_AddSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_photo_alternate_outlined),
              title: Text(l.addScreenshots),
              onTap: () => Navigator.pop(context, _AddSource.screenshots),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(l.fromFile),
              onTap: () => Navigator.pop(context, _AddSource.file),
            ),
            // On both platforms now, because two different links land here
            // and only one of them is Apple's.
            //
            // A guide link is a list of Apple identifiers and nothing else --
            // no name, no coordinate -- and resolving one needs Apple's own
            // lookup, so read anywhere else it produces a list that looks
            // imported and cannot be sent. That was measured rather than
            // assumed, and it is why this used to be hidden on Android.
            //
            // A post link needs none of that: the server reads it and the
            // names come back as text. Withholding the whole entry on Android
            // would leave the share sheet as the only way in to a feature
            // Android users can buy.
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(_makesGuides ? l.fromGuideOrPost : l.fromPost),
              onTap: () => Navigator.pop(context, _AddSource.guide),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case _AddSource.screenshots:
        await _importScreenshots();
      case _AddSource.file:
        await _importFile();
      case _AddSource.guide:
        await _importGuide();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final keeping = _pending.where((p) => p.publishable).length;
    // Not the same count: a place a file positioned can be sent to another map
    // app without Apple ever having identified it.
    final sendable = _pending.where((p) => p.exportable).length;
    // Not simply "unresolved": a place the file positioned is not lost, and on
    // a platform with no map search there is nothing a tap could do about it.
    // Counting those here announced that five places needed attention while all
    // five were ready to send.
    final unresolved = _pending
        .where((p) => !p.resolved && p.fromFile == null)
        .length;
    // The free limit applies to what Wren found, not to what the user already
    // had, so the banner counts the same thing the paywall does.
    final over = _entitlement.overBy(
      _pending.where((p) => p.publishable && p.billable).length,
    );

    // Carried-over places sit in one collapsed group. Two lists over one index
    // arithmetic: the group is a single row when closed and n rows when open,
    // and offsetting an itemBuilder by that is how off-by-one bugs get in.
    final carried = _pending.where((p) => p.origin == Origin.guide).toList();
    final fresh = _pending.where((p) => p.origin != Origin.guide).toList();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: GestureDetector(
          // Long press opens complimentary access. Undiscoverable on purpose,
          // and useless without a code that the server recognises.
          onLongPress: _compUnlock,
          child: Row(
            children: [
              const WrenMark(size: 30),
              const SizedBox(width: 10),
              Text(
                'Wren',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontSize: 21),
              ),
            ],
          ),
        ),
        actions: [
          // The menu is always present now. It used to appear only when the
          // unlock had not been bought, which meant clearing the list would
          // have been unreachable for anyone who had paid.
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'restore') _restoreFromMenu();
              if (v == 'unlock') _unlockFromMenu(PaywallReason.places);
              if (v == 'reels') _unlockFromMenu(PaywallReason.reels);
              if (v == 'clear') _clearList();
            },
            itemBuilder: (context) => [
              if (_pending.isNotEmpty)
                PopupMenuItem(value: 'clear', child: Text(l.clearList)),
              // The purchases, and the restore that belongs with them.
              //
              // They have to be reachable at any time, from a standing start.
              // The unlock used to exist only inside the publish flow, behind a
              // list of more than three places -- so on a review device with
              // nothing imported there was no way to reach it at all, and App
              // Review rejected the app under 2.1(b) for exactly that: they
              // could not locate the In-App Purchase. Reading posts is behind a
              // shared link, which a reviewer is even less likely to have, so
              // it needs the same door.
              //
              // Each is listed only while it is unheld, which is how the app
              // says "bought" without a line of copy that would have needed
              // translating into another forty-eight languages to say it.
              if (_sellsUnlock) ...[
                if (!_entitlement.unlimited)
                  PopupMenuItem(
                    value: 'unlock',
                    child: Text(
                      _makesGuides ? l.guidesOfAnySize : l.anyNumberOfPlaces,
                    ),
                  ),
                if (!_entitlement.reels)
                  PopupMenuItem(value: 'reels', child: Text(l.reelsTitle)),
                // Restoring is offered while anything is still unheld, and not
                // once everything is: there would be nothing for it to find.
                if (!_entitlement.unlimited || !_entitlement.reels)
                  PopupMenuItem(
                    value: 'restore',
                    child: Text(l.restorePurchase),
                  ),
              ],
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (_busy && _totalCount > 0)
            _Banner(
              accent: Wren.gold,
              child: Text(
                _lookingUp
                    ? l.lookingUpProgress(_readCount, _totalCount)
                    : l.readingProgress(_readCount, _totalCount),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          // Above the status line, because it is about losing something
          // rather than about what just happened.
          if (_compExpiring)
            _Banner(
              accent: Wren.clay,
              child: Text(
                l.compExpiring,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (!_busy && _status != null)
            _Banner(
              accent: Wren.line,
              child: Text(
                _status!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (_region != null && _pending.isNotEmpty)
            _Banner(
              accent: Wren.gold,
              child: Row(
                children: [
                  const Icon(Icons.place_outlined, size: 15, color: Wren.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l.searchedIn(_region!.label),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          if (unresolved > 0)
            _Banner(
              accent: Wren.clay,
              child: Text(
                l.notFoundBanner(unresolved),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (_sellsUnlock && over > 0)
            _Banner(
              accent: Wren.clay,
              child: Text(
                l.overFreeLimit(over, freePlaceLimit),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          // Said as soon as a guide has been read in, not at the end. Finding
          // out after choosing places and naming the guide would be a worse way
          // to learn it.
          if (_makesGuides && carried.isNotEmpty && !_entitlement.unlimited)
            _Banner(
              accent: Wren.clay,
              child: Text(
                l.combineNeedsUnlock,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: _pending.isEmpty
                ? _Empty(makesGuides: _makesGuides)
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    children: [
                      if (carried.isNotEmpty) ...[
                        _CarriedGroup(
                          count: carried.length,
                          guideName: _guideName,
                          expanded: _showCarried,
                          // Apple's payload carries no names, so until the
                          // lookup fills them in there is nothing behind the
                          // toggle. Offering it anyway would open onto a column
                          // of blank cards.
                          canExpand: carried.any(
                            (p) =>
                                (p.match?.name ?? '').isNotEmpty ||
                                (p.match?.address ?? '').isNotEmpty,
                          ),
                          onTap: () =>
                              setState(() => _showCarried = !_showCarried),
                        ),
                        const SizedBox(height: 10),
                        if (_showCarried && carried.isNotEmpty)
                          for (final p in carried) ...[
                            _PlaceCard(
                              pending: p,
                              canSearch: _canSearch,
                              onChanged: (v) =>
                                  setState(() => p.keep = v ?? true),
                              onEdit: () => _editPlace(_pending.indexOf(p)),
                            ),
                            const SizedBox(height: 10),
                          ],
                      ],
                      for (final p in fresh) ...[
                        _PlaceCard(
                          pending: p,
                          canSearch: _canSearch,
                          onChanged: (v) => setState(() => p.keep = v ?? true),
                          onEdit: () => _editPlace(_pending.indexOf(p)),
                        ),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _addPlaces,
                      icon: const Icon(Icons.add, size: 20),
                      label: Text(_busy ? l.readingShort : l.addPlaces),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Two different products behind one button. A guide is
                  // Apple Maps and does not exist on Android, where the same
                  // list goes to whichever map app is installed instead. The
                  // sheet used to hang off the overflow menu; it is the point
                  // of the Android app, so it is the button.
                  Expanded(
                    child: _makesGuides
                        ? FilledButton.icon(
                            onPressed: keeping == 0 ? null : _publish,
                            icon: const Icon(Icons.map_outlined, size: 20),
                            label: Text(
                              keeping == 1
                                  ? l.addToGuide
                                  : l.makeGuide(keeping),
                            ),
                          )
                        : FilledButton.icon(
                            // Counts what can be exported, not what Apple
                            // matched: a place a file positioned is ready to
                            // send without any lookup having succeeded.
                            onPressed: sendable == 0
                                ? null
                                : _sendPlacesElsewhere,
                            icon: const Icon(Icons.place_outlined, size: 20),
                            label: Text(l.sendPlacesTo),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _UnlockChoice { buy, restore, publishFree, cancel }

/// What the purchase sheet was answered with, and for which product.
///
/// The product travels with the answer rather than being inferred afterwards.
/// Two of the three differ by five pounds and the sheet can show either first
/// depending on what is already owned, so a caller that worked it out again
/// would be a second place for the two to disagree.
class _UnlockAnswer {
  const _UnlockAnswer(this.choice, {this.productId});

  final _UnlockChoice choice;

  /// Set for [_UnlockChoice.buy], and null for every other answer.
  final String? productId;
}

/// Whether a caller stopped by the paywall may now go on.
enum _Gate {
  /// Paid, restored, or already held. Proceed at full size.
  through,

  /// Not paid, but the free allowance was accepted. Proceed with that much.
  trimmed,

  /// Cancelled, refused, or restored something short of what was needed.
  stop,
}

enum _AddSource { screenshots, file, guide }

/// Which overlay the store-screenshot build should open on launch.
enum ScreenshotOverlay { none, region, paywall, search, addMenu }

/// The collapsed group holding places carried over from an existing guide.
///
/// Collapsed by default, and it is the reason the group exists: importing a
/// guide of forty places would otherwise bury the two just added under a list
/// the user has already seen in Maps. Open, it is an ordinary list of cards.
class _CarriedGroup extends StatelessWidget {
  const _CarriedGroup({
    required this.count,
    required this.guideName,
    required this.expanded,
    required this.canExpand,
    required this.onTap,
  });

  final int count;
  final String? guideName;
  final bool expanded;

  /// Whether there is anything behind the toggle yet.
  final bool canExpand;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final t = Theme.of(context).textTheme;
    final name = guideName;

    return Material(
      color: Wren.raised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Wren.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: canExpand ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              const Icon(Icons.bookmark_border, size: 18, color: Wren.muted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.alreadyInGuide(count),
                      style: t.titleMedium?.copyWith(fontSize: 16),
                    ),
                    if (name != null && name.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        l.fromGuideNamed(name),
                        style: t.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (canExpand)
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  color: Wren.muted,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.child, required this.accent});
  final Widget child;
  final Color accent;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    decoration: BoxDecoration(
      color: Wren.raised,
      border: Border(left: BorderSide(color: accent, width: 3)),
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
    ),
    child: child,
  );
}

class _PlaceCard extends StatelessWidget {
  const _PlaceCard({
    required this.pending,
    required this.onChanged,
    required this.onEdit,
    required this.canSearch,
  });

  final Pending pending;
  final ValueChanged<bool?> onChanged;
  final VoidCallback onEdit;

  /// Whether there is a map to look a place up in.
  ///
  /// False on Android, and it changes what an unmatched row means. With a map,
  /// no match is a job: tap the card, search, correct it. Without one, no match
  /// is simply the state of every row -- MapKit is the only lookup there is --
  /// so a card that opens a search sheet saying "needs an iPhone" turns the
  /// normal case into an error the user cannot clear.
  final bool canSearch;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final t = Theme.of(context).textTheme;
    final match = pending.match;
    final resolved = match != null;
    // A place the file positioned itself. Apple has not identified it, so it
    // cannot go into a guide -- but it has a name and an address, and showing
    // "Not found on the map. Tap to search for it." would be doubly wrong: the
    // place is not lost, and on a platform with no map search there is nothing
    // for a tap to do.
    final fromFile = pending.fromFile;
    // Whether this row still wants something from the user, which is not the
    // same as "the map did not identify it". A place a file positioned is
    // perfectly usable: it has a name, an address and a coordinate, and
    // outlining it in red under "Not found on the map" would be doubly wrong
    // — the place is not lost, and the user has nothing to fix.
    //
    // A row needs attention when nothing positions it at all: no match and no
    // coordinate. That is the only kind that cannot be sent anywhere.
    final needsAttention =
        !resolved && !(pending.forExport?.hasCoordinate ?? false);
    final shown = resolved
        ? (match.name.isNotEmpty ? match.name : match.address)
        : (fromFile?.name ?? '');
    final shownAddress = resolved ? match.address : (fromFile?.address ?? '');
    final named = shown.isNotEmpty;

    return Opacity(
      opacity: !needsAttention && !pending.keep ? 0.5 : 1,
      child: Material(
        color: Wren.raised,
        // Shape only — Material asserts if both shape and borderRadius are
        // given, which crashed the whole list the moment an unmatched place
        // appeared in it.
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: needsAttention
              ? const BorderSide(color: Wren.clay, width: 1.2)
              : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          // Tapping anywhere opens the lookup. Correcting a wrong match and
          // finding one that failed are the same job, so they are one gesture
          // — including on a row that is already usable, where the reading may
          // still have been wrong. Where there is no lookup at all the card is
          // not a button.
          onTap: canSearch ? onEdit : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (named) ...[
                        // A carried place arrives with a muid and no name. If
                        // the lookup filled one in, use it; failing that the
                        // address is still something true. The group refuses to
                        // expand when neither exists, so this never renders
                        // blank.
                        Text(shown, style: t.titleMedium),
                        // A place carried over from a guide has no address in
                        // the payload, so the line is left out rather than
                        // rendered blank.
                        if (shownAddress.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(shownAddress, style: t.bodySmall),
                        ],
                      ] else ...[
                        Row(
                          children: [
                            const Icon(
                              Icons.help_outline,
                              size: 16,
                              color: Wren.clay,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                l.notFoundOnMap,
                                style: t.titleMedium?.copyWith(
                                  fontSize: 16,
                                  color: Wren.clay,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(l.tapToSearchForIt, style: t.bodySmall),
                      ],
                      // Shown for anything Wren had to interpret, matched or
                      // not: it is the only way to tell a right match from a
                      // confident wrong one. Omitted for a place carried over
                      // from a guide, where the name came from Apple's own
                      // record and repeating it says nothing -- and omitted
                      // whenever it would repeat the line above it, which is
                      // every row of an imported file, since nothing
                      // interpreted them. Six rows each saying
                      // "read as" and then their own name is noise standing
                      // where a real correction should stand out.
                      if (pending.origin != Origin.guide &&
                          pending.readAs.trim() != shown.trim()) ...[
                        const SizedBox(height: 7),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.text_fields,
                              size: 13,
                              color: Wren.muted,
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                l.readAs(pending.readAs),
                                style: t.bodySmall?.copyWith(fontSize: 12.5),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (!needsAttention)
                  Checkbox(value: pending.keep, onChanged: onChanged)
                else if (canSearch)
                  IconButton(
                    icon: const Icon(Icons.search, color: Wren.clay),
                    tooltip: l.searchAppleMaps,
                    onPressed: onEdit,
                  )
                else
                  // Nothing to search and nothing to send: the file named this
                  // place and gave it no position. A live checkbox here would
                  // tick and then be quietly ignored on the way out.
                  const Checkbox(value: false, onChanged: null),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.makesGuides});

  /// The first screen has to describe the app that is actually installed. On
  /// Android it reads a file and hands the list on: it takes no screenshots,
  /// because there is no text recognition, and it makes no guide, because
  /// there is no Apple Maps. Saying otherwise here would be the first thing
  /// anybody saw, reviewers included.
  final bool makesGuides;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final t = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(36, 0, 36, 60),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const WrenMark(size: 92),
            const SizedBox(height: 26),
            Text(
              l.emptyTitle,
              style: t.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              makesGuides ? l.emptyBody : l.emptyBodyAndroid,
              style: t.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            Text(
              makesGuides ? l.emptyNote : l.emptyNoteAndroid,
              style: t.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            // Named here rather than left to be found inside a menu. A file
            // importer nobody knows the formats of is a file importer nobody
            // tries, and the formats are the whole answer to "will mine work".
            Container(
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
              decoration: BoxDecoration(
                color: Wren.raised,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Wren.line),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.insert_drive_file_outlined,
                    size: 15,
                    color: Wren.muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.acceptedFormats,
                      style: t.bodySmall?.copyWith(fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
