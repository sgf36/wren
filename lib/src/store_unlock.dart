import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'entitlement.dart';

/// StoreKit- and Play-backed implementation of [UnlockStore].
///
/// Three rules shape this file.
///
/// It **fails closed**. Every path that cannot prove a purchase returns false.
/// A bug here that grants the unlock is worse than a bug that refuses it, since
/// the second produces a complaint and the first produces silent lost revenue.
///
/// The store is the authority, not the cache. [SharedPreferences] only keeps a
/// copy so the app knows the answer while offline; a purchase is confirmed by
/// the store and re-confirmed by [restore]. The cache is never written except
/// after the store has said yes.
///
/// It remembers *which* products, not merely that something was bought. There
/// are three and they grant different things, so the old boolean could not
/// tell an unlocked guide from a readable post. The boolean is still read on
/// the way in — everybody who paid before there was more than one thing to buy
/// has that key and nothing else, and dropping it would re-lock a customer.
class StoreUnlockStore implements UnlockStore {
  /// The original single-purchase flag. Read for ever, written alongside the
  /// set, because a build that predates this file may still be installed on a
  /// device that syncs preferences.
  static const _legacyKey = 'unlimited_unlocked';

  /// Product ids the store has confirmed.
  static const _ownedKey = 'owned_products';

  /// The store's own receipt for a purchase that grants reading posts.
  ///
  /// Kept because the Worker will not take the app's word for it — it verifies
  /// an App Store transaction against Apple's certificate chain, or a Play
  /// token against Google — and this is the only moment the receipt exists.
  /// There is no call that asks the store for it again later, so a purchase
  /// whose proof was not saved here is one the server can never be shown.
  static const _proofKey = 'reel_purchase_proof';

  final InAppPurchase _iap;

  /// How long to wait on the payment sheet before giving up. Public because a
  /// named parameter cannot be private, and tests want to shorten it.
  final Duration timeout;

  StoreUnlockStore({
    InAppPurchase? iap,
    this.timeout = const Duration(seconds: 60),
  }) : _iap = iap ?? InAppPurchase.instance;

  final Map<String, ProductDetails> _products = {};
  bool _queried = false;

  /// What the last confirmed answer was, for deciding what to show before the
  /// store replies — which on a cold launch is most of the first second.
  static Future<Set<String>> cachedProducts() async {
    final prefs = await SharedPreferences.getInstance();
    final owned = (prefs.getStringList(_ownedKey) ?? const <String>[]).toSet();
    if (prefs.getBool(_legacyKey) ?? false) owned.add(unlimitedProductId);
    // An id the app no longer sells is dropped rather than carried: it could
    // only have arrived by a downgrade or a hand-edited file, and an unknown
    // string must never compose into an entitlement.
    return owned.intersection(allProductIds);
  }

  static Future<void> _remember(PurchaseDetails p) async {
    final prefs = await SharedPreferences.getInstance();
    final owned = (prefs.getStringList(_ownedKey) ?? const <String>[]).toSet()
      ..add(p.productID);
    await prefs.setStringList(_ownedKey, owned.toList()..sort());
    // Every product grants the uncapped list, so the old flag stays true.
    await prefs.setBool(_legacyKey, true);

    // Only the reel products need proving to anybody. The uncapped list is
    // decided on the phone and no server is ever asked about it, so keeping a
    // receipt for it would be storing a credential with no use.
    final proof = p.verificationData.serverVerificationData;
    if (reelProductIds.contains(p.productID) && proof.isNotEmpty) {
      await prefs.setString(
        _proofKey,
        jsonEncode({
          'productId': p.productID,
          'proof': proof,
          // Which store issued it, recorded here rather than asked of the
          // platform later. The two proofs are different objects — a signed
          // transaction from Apple, a purchase token from Google — and the
          // Worker verifies them against different authorities. The device
          // that took the payment is the one that knows.
          'store': Platform.isAndroid ? 'play' : 'appstore',
        }),
      );
    }
  }

  /// The receipt for a reel purchase, or null if there is none to show.
  ///
  /// On iOS the proof is a signed transaction; on Android it is the purchase
  /// token. Both go to the Worker, which decides whether they are real — so a
  /// value read back from here is a claim, never an entitlement.
  static Future<({String productId, String proof, String store})?>
  reelProof() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_proofKey);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, Object?>;
      final productId = map['productId']?.toString() ?? '';
      final proof = map['proof']?.toString() ?? '';
      final store = map['store']?.toString() ?? '';
      if (!reelProductIds.contains(productId) || proof.isEmpty) return null;
      if (store != 'play' && store != 'appstore') return null;
      return (productId: productId, proof: proof, store: store);
    } on Object {
      return null;
    }
  }

  /// Asks the store about everything it sells, once.
  ///
  /// One call rather than one per product: each is a round trip the user waits
  /// through, and the sheet shows two prices side by side.
  Future<void> _load() async {
    if (_queried) return;
    if (!await _iap.isAvailable()) return;
    final response = await _iap.queryProductDetails(allProductIds);
    if (response.error != null) return;
    for (final p in response.productDetails) {
      _products[p.id] = p;
    }
    // Only latched on a reply, so a store that was unreachable at launch is
    // asked again rather than answering "no price" for the session.
    _queried = true;
  }

  /// The localised price exactly as the store gives it. Never assembled here:
  /// price points are set per market and are not conversions of the dollar
  /// figure, so a hand-formatted price would be wrong somewhere.
  @override
  Future<String?> price(String productId) async {
    await _load();
    return _products[productId]?.price;
  }

  @override
  Future<bool> buy(String productId) async {
    await _load();
    final product = _products[productId];
    if (product == null) return false;

    // Watch the stream before asking, or a fast purchase can complete before
    // there is anything listening for it.
    final settled = Completer<bool>();
    late final StreamSubscription<List<PurchaseDetails>> sub;
    sub = _iap.purchaseStream.listen(
      (purchases) async {
        for (final p in purchases) {
          // Another product completing mid-flow is recorded and ignored: a
          // restore can land here, and losing it would ask for money twice.
          if (allProductIds.contains(p.productID) &&
              (p.status == PurchaseStatus.purchased ||
                  p.status == PurchaseStatus.restored)) {
            // Non-consumable, so it must be completed or the store will keep
            // handing it back on every launch.
            if (p.pendingCompletePurchase) await _iap.completePurchase(p);
            await _remember(p);
          }
          if (p.productID != productId) continue;
          switch (p.status) {
            case PurchaseStatus.purchased:
            case PurchaseStatus.restored:
              if (!settled.isCompleted) settled.complete(true);
            case PurchaseStatus.error:
            case PurchaseStatus.canceled:
              if (!settled.isCompleted) settled.complete(false);
            case PurchaseStatus.pending:
              break; // Ask to Buy, or a slow payment sheet. Keep waiting.
          }
        }
      },
      onError: (_) {
        if (!settled.isCompleted) settled.complete(false);
      },
    );

    try {
      final started = await _iap.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: product),
      );
      if (!started) return false;
      return await settled.future.timeout(timeout, onTimeout: () => false);
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<Set<String>> restore() async {
    if (!await _iap.isAvailable()) return const {};

    // Not a Completer holding the first answer: an account can own two of
    // these, they arrive as separate events, and stopping at the first would
    // restore the cheaper one and lose the other. So the stream is collected
    // for a fixed window instead.
    final found = <String>{};
    final complete = Completer<void>();
    final sub = _iap.purchaseStream.listen((purchases) async {
      for (final p in purchases) {
        if (!allProductIds.contains(p.productID)) continue;
        if (p.status != PurchaseStatus.restored &&
            p.status != PurchaseStatus.purchased) {
          continue;
        }
        if (p.pendingCompletePurchase) await _iap.completePurchase(p);
        await _remember(p);
        found.add(p.productID);
      }
      // There is nothing further worth waiting for once everything the app
      // sells has been granted, so the common success does not sit through the
      // whole window.
      if (_grantsEverything(found) && !complete.isCompleted) {
        complete.complete();
      }
    }, onError: (_) {});

    try {
      await _iap.restorePurchases();
      // Nothing to restore produces no event at all, and an account holding
      // only the base unlock produces one and then silence — neither is
      // distinguishable from a slow reply, so the window has to elapse. That
      // is why this cannot simply return on the first hit: an account can own
      // two of these, they arrive separately, and stopping early would restore
      // the cheaper one and lose the other.
      await Future.any([
        complete.future,
        Future<void>.delayed(const Duration(seconds: 8)),
      ]);
      return found;
    } catch (_) {
      return found;
    } finally {
      await sub.cancel();
    }
  }
}

/// Whether this set leaves nothing else to grant.
///
/// Not "holds every id": `everything` on its own grants what the other two do
/// together, so waiting for the pair would sit out the timeout for a customer
/// who has already been fully restored.
bool _grantsEverything(Set<String> owned) {
  final held = Entitlement.from(
    boughtUnlimited: owned.contains(unlimitedProductId),
    boughtReels: owned.any(reelProductIds.contains),
    compUnlock: false,
    compReels: false,
  );
  return held.unlimited && held.reels;
}
