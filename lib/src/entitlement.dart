/// What the free app does, and what the one-time purchase unlocks.
///
/// A guide may hold up to [freePlaceLimit] places without paying. The unlock is
/// a single non-consumable purchase that removes the cap for good — no
/// subscription, nothing recurring, nothing expiring.
///
/// The limit is deliberately per guide rather than per lifetime. Someone should
/// be able to keep using the free app for the small guides it handles well, and
/// pay when they want the thing it is actually for. A lifetime cap of three
/// would make the free tier a demo rather than a product.
library;

/// Places allowed in one guide before the unlock is required.
const int freePlaceLimit = 3;

/// Non-consumable product, configured in App Store Connect against the Wren
/// app record. $8.99 USD, one time.
const String unlimitedProductId = 'com.spencerfields.littlebird.unlimited';

/// Everything: uncapped guides and places read out of a shared post. Shown to
/// somebody who owns nothing. £14.99.
const String everythingProductId = 'com.spencerfields.littlebird.everything';

/// Posts added to an unlock already held. Shown only to somebody who owns
/// [unlimitedProductId]; holding both is the same as holding
/// [everythingProductId]. £9.99.
const String reelsUpgradeProductId =
    'com.spencerfields.littlebird.reels.upgrade';

/// Every product that grants reading posts. An id in this set unlocks a
/// feature that costs money on each use, so it is written out rather than
/// inferred from a name.
const Set<String> reelProductIds = {everythingProductId, reelsUpgradeProductId};

/// Every product either store carries.
///
/// Both carry the same three. Android was going to sell a reels-only product
/// instead, and that was dropped: it already sells `unlimited`, so a separate
/// ladder would have meant two different answers to "what have I bought" in one
/// app. Queried in a single call because each round trip to the store costs a
/// visible pause, and the sheet needs two prices at once.
const Set<String> allProductIds = {
  unlimitedProductId,
  everythingProductId,
  reelsUpgradeProductId,
};

/// Why the purchase sheet is open.
///
/// It decides which product is offered first, and that is not a marketing
/// question. Somebody stopped by the three-place cap is served by the cheaper
/// unlock, and putting the bundle in front of them as the only way past would
/// be selling them something they did not need. Somebody who shared a post has
/// no cheaper option, because nothing else grants it.
enum PaywallReason {
  /// A list is over the free cap.
  places,

  /// A post was shared and cannot be read.
  reels,
}

/// What is worth offering, best answer first, or empty when nothing is left.
///
/// A pure function of the reason and what is held, so the matrix can be tested
/// without a store, a widget or a phone. Empty is a real answer and the caller
/// must handle it: a person who owns everything and shares a post has hit the
/// monthly allowance, not a paywall, and showing them a sheet with nothing to
/// buy would be the app failing to explain itself.
List<String> offersFor(PaywallReason reason, Entitlement held) {
  switch (reason) {
    case PaywallReason.places:
      if (held.unlimited) return const [];
      // The cheaper one first: it is the whole of what was asked for. The
      // bundle follows as the larger option rather than replacing it.
      return const [unlimitedProductId, everythingProductId];
    case PaywallReason.reels:
      if (held.reels) return const [];
      // Non-consumables have no upgrade mechanism, so somebody who already
      // holds the unlock is sold the difference rather than the whole thing
      // again.
      return held.unlimited
          ? const [reelsUpgradeProductId]
          : const [everythingProductId];
  }
}

/// Advertised prices. Only ever used as a fallback in copy — the real figure
/// shown to the user must come from the store, because Apple sets the local
/// price and it is not a currency conversion of the dollar one. Each is the
/// USD customer price of the product's schedule in App Store Connect, and each
/// is wrong on every other storefront, which is why it is reached for only when
/// the store will not answer at all.
const String unlimitedFallbackPrice = r'$8.99';
const String everythingFallbackPrice = r'$14.99';
const String reelsUpgradeFallbackPrice = r'$9.99';

/// The advertised price of one product, for when the store is silent.
String fallbackPriceOf(String productId) => switch (productId) {
  everythingProductId => everythingFallbackPrice,
  reelsUpgradeProductId => reelsUpgradeFallbackPrice,
  _ => unlimitedFallbackPrice,
};

enum PublishBlock {
  /// Nothing selected.
  nothingSelected,

  /// Over the free limit and not unlocked.
  needsUnlock,

  /// Good to go.
  none,
}

/// What a person may do, which is now two questions rather than one.
///
/// They are separate because they are bought separately and cost differently.
/// Uncapped guides cost nothing to serve — the check happens on the phone and
/// no server is involved. Reading a post costs money every single time, because
/// somebody has to fetch the media and a model has to read it. So one is a
/// permission and the other is a meter, and collapsing them into a single
/// boolean would mean either giving the expensive one away or charging for the
/// free one.
class Entitlement {
  /// Whether the unlock has been purchased, or restored on a new device.
  final bool unlimited;

  /// Whether places may be read out of a shared reel or post.
  final bool reels;

  const Entitlement({required this.unlimited, this.reels = false});

  const Entitlement.free() : unlimited = false, reels = false;

  /// The original unlock: guides and exports uncapped, and nothing else.
  const Entitlement.unlocked() : unlimited = true, reels = false;

  /// That, plus reading posts. What `everything` grants, and what holding the
  /// base unlock together with the reels upgrade adds up to.
  const Entitlement.everything() : unlimited = true, reels = true;

  /// Rebuilt from what is owned, rather than remembered.
  ///
  /// Called on launch, on resume and after any purchase, so it has to be a
  /// pure function of the four things that can grant something. Anything it
  /// forgot would be a feature that silently switched off, and anything it
  /// assumed would be one somebody got for free.
  ///
  /// A comp code carries a role and the roles are a ladder: `unlock` is guides,
  /// `everything` adds posts, `admin` adds the console on top. Reels are
  /// deliberately not granted by an ordinary unlock code — they cost money on
  /// every use, and a code handed to a friend for guides should not quietly
  /// carry that.
  factory Entitlement.from({
    required bool boughtUnlimited,
    required bool boughtReels,
    required bool compUnlock,
    required bool compReels,
  }) => Entitlement(
    unlimited: boughtUnlimited || boughtReels || compUnlock || compReels,
    reels: boughtReels || compReels,
  );

  /// How many of [selected] places can be published right now.
  int allowance(int selected) => unlimited
      ? selected
      : (selected < freePlaceLimit ? selected : freePlaceLimit);

  /// Whether publishing [selected] places is permitted as things stand.
  PublishBlock check(int selected) {
    if (selected <= 0) return PublishBlock.nothingSelected;
    if (!unlimited && selected > freePlaceLimit) {
      return PublishBlock.needsUnlock;
    }
    return PublishBlock.none;
  }

  /// How many places over the line the user currently is. Zero when fine.
  int overBy(int selected) => unlimited
      ? 0
      : (selected > freePlaceLimit ? selected - freePlaceLimit : 0);
}

/// The purchase itself. Kept behind an interface so the app can be built and
/// tested without StoreKit, and so the UI never talks to the store directly.
abstract class UnlockStore {
  /// Localised price string from the store, or null if it could not be read.
  /// Never format this yourself — Apple's price points are not conversions.
  Future<String?> price(String productId);

  /// Runs the purchase flow for one product. True if it is now owned.
  ///
  /// The product is named rather than implied. There are three, two of them
  /// differ by five pounds, and a default would let a mistaken call charge the
  /// wrong one without anything looking wrong at the call site.
  Future<bool> buy(String productId);

  /// Everything the store says this account owns.
  ///
  /// A set rather than a yes: restoring on a new phone has to say *which*
  /// purchases came back, because two of them grant different things. Apple
  /// requires a restore path, and a user on a new phone must not be asked to
  /// pay twice.
  Future<Set<String>> restore();
}

/// Stands in until `in_app_purchase` is wired to the real product. Always
/// reports failure rather than silently granting the unlock, so a missing
/// implementation cannot become a free upgrade.
class UnavailableUnlockStore implements UnlockStore {
  @override
  Future<String?> price(String productId) async => null;

  @override
  Future<bool> buy(String productId) async => false;

  @override
  Future<Set<String>> restore() async => const {};
}
