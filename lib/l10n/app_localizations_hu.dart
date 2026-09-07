// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Hungarian (`hu`).
class LHu extends L {
  LHu([String locale = 'hu']) : super(locale);

  @override
  String get tagline => 'Egy kismadár csiripelte.';

  @override
  String get emptyTitle => 'Helyek, eltéve.';

  @override
  String get emptyBody =>
      'Készíts képernyőképet arról, amit ajánlanak neked — egy reelről, egy posztról, egy üzenetről, egy útikönyv oldaláról. A Wren kiolvassa a neveket, és beteszi őket az Apple Térképekbe.';

  @override
  String get emptyNote =>
      'Egyetlen hely bekerül egy már meglévő útikalauzba. Több helyből új készül — az Apple Térképek nem tud útikalauzokat összevonni.';

  @override
  String get emptyBodyAndroid =>
      'Készíts képernyőképet arról, amit ajánlanak neked — egy reelről, egy posztról, egy üzenetről, egy útikönyv oldaláról. A Wren kiolvassa a neveket, és elküldi őket a telefonod térkép-alkalmazásába.';

  @override
  String get emptyNoteAndroid =>
      'Beolvassa a már meglévő listádat is, és minden helyet megmutat, mielőtt bármi elhagyná a készüléket.';

  @override
  String get addScreenshots => 'Képernyőképek hozzáadása';

  @override
  String get readingShort => 'Olvasás…';

  @override
  String readingProgress(int done, int total) {
    return '$done / $total olvasása…';
  }

  @override
  String get addToGuide => 'Hozzáadás egy útikalauzhoz';

  @override
  String makeGuide(int count) {
    return 'Útikalauz készítése ($count)';
  }

  @override
  String get notFoundOnMap => 'Nem található a térképen';

  @override
  String get tapToSearchForIt => 'Koppints rá a kereséshez';

  @override
  String readAs(String text) {
    return 'így olvasva: „$text”';
  }

  @override
  String notFoundBanner(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hely nem található. Koppints rájuk a kereséshez.',
      one: '1 hely nem található. Koppints rá a kereséshez.',
    );
    return '$_temp0';
  }

  @override
  String get whereAreThesePlaces => 'Hol vannak ezek a helyek?';

  @override
  String get regionDetected =>
      'A képaláírásokból olvasva. Írd át, ha nem stimmel.';

  @override
  String get regionNotDetected =>
      'A képernyőképeken nem szerepelt, hol vannak. Egy várossal a keresés sokkal pontosabb lesz.';

  @override
  String get cityOrRegion => 'Város vagy régió';

  @override
  String get cityExample => 'pl. Budapest';

  @override
  String get searchAnywhere => 'Keresés mindenhol';

  @override
  String get findPlaces => 'Helyek keresése';

  @override
  String searchedIn(String region) {
    return 'Keresés itt: $region';
  }

  @override
  String get nameThisGuide => 'Nevezd el ezt az útikalauzt';

  @override
  String nameThisGuideBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Ezen a néven jelenik meg az Apple Térképekben, $count hellyel.',
      one: 'Ezen a néven jelenik meg az Apple Térképekben, 1 hellyel.',
    );
    return '$_temp0';
  }

  @override
  String get guideName => 'Az útikalauz neve';

  @override
  String get guideNameExample => 'pl. Róma, október';

  @override
  String get createGuide => 'Útikalauz létrehozása';

  @override
  String get cancel => 'Mégse';

  @override
  String get guidesOfAnySize => 'Bármekkora útikalauz';

  @override
  String get anyNumberOfPlaces => 'Bármennyi hely';

  @override
  String unlockExplain(int limit, int selected, int over) {
    return 'A Wren ingyen legfeljebb $limit helyet ment egy útikalauzba. $selected van kijelölve — $over darabbal több.';
  }

  @override
  String unlockExplainAndroid(int limit, int selected, int over) {
    return 'A Wren ingyen legfeljebb $limit helyet küld egyszerre. $selected van kijelölve — $over darabbal több.';
  }

  @override
  String get onePaymentKept =>
      'Egyszeri fizetés, örökre a tiéd. Nincs előfizetés.';

  @override
  String unlockFor(String price) {
    return 'Feloldás $price összegért';
  }

  @override
  String saveFirstInstead(int limit) {
    return 'Inkább az első $limit mentése';
  }

  @override
  String get restorePrevious => 'Korábbi vásárlás visszaállítása';

  @override
  String get restorePurchase => 'Vásárlás visszaállítása';

  @override
  String overFreeLimit(int over, int limit) {
    return '$over darabbal az ingyenes $limit fölött. Feloldhatod, vagy elmentheted az első $limit helyet.';
  }

  @override
  String get findThisPlace => 'Ennek a helynek a megkeresése';

  @override
  String get searchAppleMaps => 'Keresés az Apple Térképekben';

  @override
  String searchInRegion(String region) {
    return 'Keresés itt: $region';
  }

  @override
  String get searching => 'Keresés…';

  @override
  String get typeTwoCharacters => 'Írj be legalább két karaktert.';

  @override
  String get nothingFound =>
      'Nincs találat. Próbáld az utcával vagy egy rövidebb névvel.';

  @override
  String get rateLimited =>
      'Az Apple Térképek korlátozza a lekérdezéseket. Várj egy kicsit, és próbáld újra.';

  @override
  String rateLimitedDuringImport(int added) {
    return 'Az Apple Térképek korlátozza a lekérdezéseket — eddig $added került be, a többit próbáld meg kicsit később.';
  }

  @override
  String importSummary(int found) {
    return '$found találat';
  }

  @override
  String importSummaryIn(String region) {
    return 'itt: $region';
  }

  @override
  String importSummaryNeedLook(int count) {
    return '$count átnézendő';
  }

  @override
  String importSummaryUnreadable(int count) {
    return '$count olvashatatlan';
  }

  @override
  String nothingReadable(int count) {
    return 'Semmi olvasható $count képernyőképen';
  }

  @override
  String get couldNotOpenMaps => 'A Térképek nem nyitható meg';

  @override
  String get checkingAppleAccount => 'Fiókod ellenőrzése…';

  @override
  String get restoredUnlocked =>
      'Visszaállítva. A bármekkora útikalauz fel van oldva.';

  @override
  String get noPreviousPurchase =>
      'Ezen a fiókon nem található korábbi vásárlás.';

  @override
  String get purchaseDidNotComplete =>
      'A vásárlás nem fejeződött be, így semmit nem számoltunk fel.';

  @override
  String alreadyInTheList(String name) {
    return '$name már szerepelt a listán.';
  }

  @override
  String get ocrUnavailable =>
      'A képernyőképek olvasásához iPhone kell — ezen a platformon nincs szövegfelismerés.';

  @override
  String get lookupUnavailable =>
      'A helykereséshez iPhone kell — ezen a platformon nincs térképes keresés.';

  @override
  String get compAccess => 'Ingyenes hozzáférés';

  @override
  String get code => 'Kód';

  @override
  String get unlock => 'Feloldás';

  @override
  String get compChecking => 'A kód ellenőrzése…';

  @override
  String get compEnabled => 'Ingyenes hozzáférés bekapcsolva.';

  @override
  String get compRefused =>
      'Ez a kód nem ismerhető fel, vagy már felhasználták.';

  @override
  String get compTooOften =>
      'Túl sok próbálkozás. Várj néhány percet, és próbáld újra.';

  @override
  String get compUnreachable =>
      'A kiszolgáló nem érhető el. Ellenőrizd a kapcsolatot, és próbáld újra.';

  @override
  String get compUntrusted =>
      'A válasz nem volt ellenőrizhető, ezért semmi nem oldódott fel.';

  @override
  String get addPlaces => 'Hozzáadás';

  @override
  String get fromFile => 'Fájlból';

  @override
  String get importGuideBody =>
      'Az Apple Térképekben nyisd meg az útikalauzt és oszd meg, majd válaszd a Hivatkozás másolása lehetőséget. Illeszd be alább, és a Wren kiolvassa a benne lévő helyeket. Reelre vagy bejegyzésre mutató hivatkozás is működik itt.';

  @override
  String get importGuideNotALink =>
      'Ez nem Apple Térképek útikalauz-hivatkozás. Nyisd meg az útikalauzt a Térképekben, oszd meg, majd válaszd a Hivatkozás másolása lehetőséget.';

  @override
  String get importGuideSocialPost =>
      'A Wren képernyőképeket olvas, nem bejegyzésekre mutató hivatkozásokat. Készíts képernyőképet a bejegyzésről, és azt oszd meg.';

  @override
  String get importGuideNothing =>
      'Abban az útikalauzban nincs semmi, amit a Wren hozzá tudna adni.';

  @override
  String importedGuideSummary(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hely beolvasva abból az útikalauzból',
      one: '1 hely beolvasva abból az útikalauzból',
    );
    return '$_temp0';
  }

  @override
  String importedGuideUnusable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hely nem vihető át belőle',
      one: '1 hely nem vihető át belőle',
    );
    return '$_temp0';
  }

  @override
  String alreadyInGuide(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hely már szerepel ebben az útikalauzban',
      one: '1 hely már szerepel ebben az útikalauzban',
    );
    return '$_temp0';
  }

  @override
  String fromGuideNamed(String name) {
    return '„$name” útikalauzból';
  }

  @override
  String get republishTitle => 'A Térképek új útikalauzt készít';

  @override
  String republishBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Az Apple nem ad módot arra, hogy egy meglévő útikalauzhoz helyeket adjunk, ezért a Wren új útikalauzt készít, amelyben mindegyik hely szerepel, összesen $count.',
      one:
          'Az Apple nem ad módot arra, hogy egy meglévő útikalauzhoz helyet adjunk, ezért a Wren új útikalauzt készít, amelyben az az 1 hely szerepel.',
    );
    return '$_temp0';
  }

  @override
  String get republishThenDelete =>
      'Tartsd meg az új útikalauzt, a régit pedig töröld.';

  @override
  String get republishKeepsPlaces =>
      'A Wren megőrzi ezeket a helyeket, így ha valami félresikerül, újra elkészítheted az útikalauzt.';

  @override
  String get makeCombinedGuide => 'Az összevont útikalauz elkészítése';

  @override
  String fileImportSummary(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hely beolvasva abból a fájlból',
      one: '1 hely beolvasva abból a fájlból',
    );
    return '$_temp0';
  }

  @override
  String fileImportSkipped(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count sorban nem volt név',
      one: '1 sorban nem volt név',
    );
    return '$_temp0';
  }

  @override
  String get fileNoPlaces => 'Nincs hely abban a fájlban.';

  @override
  String get fileUnreadable =>
      'A Wren nem tudta beolvasni azt a fájlt. CSV-, KML-, KMZ-, GPX-, GeoJSON- és Google Takeout-fájlokat olvas.';

  @override
  String lookingUpProgress(int done, int total) {
    return '$done / $total keresése…';
  }

  @override
  String get combineNeedsUnlock =>
      'Az összevont útikalauz elkészítéséhez feloldás kell.';

  @override
  String get unlockCombineTitle => 'Hozzáadás a saját útikalauzodhoz';

  @override
  String unlockCombineBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'A Wren egyetlen útikalauzt készít, amelyben a sajátodban már meglévő $count hely és az új helyek együtt szerepelnek.',
      one:
          'A Wren egyetlen útikalauzt készít, amelyben a sajátodban már meglévő 1 hely és az új hely együtt szerepel.',
    );
    return '$_temp0';
  }

  @override
  String get acceptedFormats =>
      'Más appból exportált listát is beolvas: CSV, KML, KMZ, GPX, GeoJSON vagy Google Takeout.';

  @override
  String get clearList => 'Lista kiürítése';

  @override
  String get clearListTitle => 'Lista kiürítése';

  @override
  String clearListBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Eltávolítod mind a $count helyet a Wrenből? Az Apple Térképekben már elkészült útikalauzokat ez nem érinti.',
      one:
          'Eltávolítod azt az 1 helyet a Wrenből? Az Apple Térképekben már elkészült útikalauzokat ez nem érinti.',
    );
    return '$_temp0';
  }

  @override
  String get clearListConfirm => 'Eltávolítás';

  @override
  String get listCleared => 'A lista kiürítve.';

  @override
  String get expandingLink => 'A hivatkozás beolvasása…';

  @override
  String get linkUnreachable =>
      'Nem sikerült elérni az Apple-t a hivatkozás beolvasásához. Ellenőrizd a kapcsolatot, és próbáld újra.';

  @override
  String get splitTitle => 'Ez több útikalauzt készít';

  @override
  String splitBody(int guides, int count) {
    return 'Az Apple korlátozza, hogy egy útikalauz-hivatkozás hány helyet vihet. A Wren $guides útikalauzt készít, megszámozva, hogy sorrendben maradjanak, és ezek együtt $count helyet tartalmaznak.';
  }

  @override
  String splitConfirm(int guides) {
    return '$guides útikalauz készítése';
  }

  @override
  String splitProgress(int done, int total) {
    return '$done / $total útikalauz megnyitva. Koppints a következő elkészítéséhez.';
  }

  @override
  String get sendPlacesTo => 'Helyek küldése';

  @override
  String sendPlacesReady(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hely készen áll a küldésre',
      one: '1 hely készen áll a küldésre',
    );
    return '$_temp0';
  }

  @override
  String sendPlacesNoLocation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count helynek nincs pozíciója, így nem küldhetők',
      one: '1 helynek nincs pozíciója, így nem küldhető',
    );
    return '$_temp0';
  }

  @override
  String get sendPlacesOtherApp => 'Bármely más alkalmazás';

  @override
  String get sendPlacesFailed => 'Az alkalmazás nem fogadta el a fájlt';

  @override
  String fileImportPositioned(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count hely megmaradt a fájlból, készen egy másik térképalkalmazáshoz',
      one: '1 hely megmaradt a fájlból, készen egy másik térképalkalmazáshoz',
    );
    return '$_temp0';
  }

  @override
  String get compExpiring =>
      'A Wren nem tudta megerősíteni az ingyenes hozzáférésedet. Csatlakozz az internethez a következő napokban, hogy megtartsd.';

  @override
  String get reelsTitle => 'Helyek egy bejegyzésből';

  @override
  String get reelsExplain =>
      'Oszd meg a Wrennel a reelt vagy a bejegyzést, és kiolvassa belőle a helyeket, készen az ellenőrzésre és a mentésre. A Wren soha nem tartja meg a videót.';

  @override
  String everythingFor(String price) {
    return 'Minden $price áron';
  }

  @override
  String addPostsFor(String price) {
    return 'Bejegyzések hozzáadása $price áron';
  }

  @override
  String get everythingAlsoReadsPosts =>
      'Megosztott bejegyzésből is kiolvassa a helyeket.';

  @override
  String get readingPost => 'Bejegyzés olvasása…';

  @override
  String reelsLeftThisMonth(int count) {
    return 'hátralévő bejegyzés ebben a hónapban: $count';
  }

  @override
  String reelQuotaUsedUp(String date) {
    return 'Ennyi bejegyzés jutott erre a hónapra. A kereted $date napján tér vissza.';
  }

  @override
  String get reelQuotaSoon => 'néhány hét';

  @override
  String get reelBusy =>
      'A Wren még az előző bejegyzést olvassa. Próbáld újra egy pillanat múlva.';

  @override
  String get reelUnavailable =>
      'Ezt a bejegyzést nem sikerült megnyitni. Lehet, hogy privát, törölték, vagy itt nem érhető el.';

  @override
  String get reelCouldNotRead =>
      'A Wren nem tudta elolvasni ezt a bejegyzést. Készíts róla képernyőképeket, és azokat oszd meg – az mindig működik.';

  @override
  String get reelNoPlaces =>
      'Semmi sem tűnt olyan helynek a bejegyzésben, ahová el lehet menni.';

  @override
  String get reelUnreachable =>
      'A Wren nem érte el a kiszolgálót, hogy elolvassa a bejegyzést. A keretedből semmi nem fogyott.';

  @override
  String get reelNeedsRestore =>
      'Előbb koppints a Vásárlás visszaállítása gombra, hogy a Wren megmutathassa a nyugtádat az áruháznak.';

  @override
  String get compEnabledEverything =>
      'Ingyenes hozzáférés bekapcsolva, a bejegyzésekből olvasott helyekkel együtt.';

  @override
  String get restoredEverything =>
      'Visszaállítva. Bármekkora útikalauz, és helyek egy bejegyzésből.';

  @override
  String get fromGuideOrPost => 'Hivatkozásból';

  @override
  String get fromPost => 'Bejegyzésből';

  @override
  String get importLinkTitle => 'Hozzáadás hivatkozásból';

  @override
  String get importPostBody =>
      'Illeszd be egy reel vagy egy bejegyzés hivatkozását, és a Wren kiolvassa belőle a helyeket. A Wren soha nem tartja meg a videót.';

  @override
  String get linkLabel => 'Hivatkozás';

  @override
  String get readLink => 'Olvasd be';
}
