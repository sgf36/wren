// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Polish (`pl`).
class LPl extends L {
  LPl([String locale = 'pl']) : super(locale);

  @override
  String get tagline => 'Ptaszek mi wyćwierkał.';

  @override
  String get emptyTitle => 'Miejsca, zachowane.';

  @override
  String get emptyBody =>
      'Udostępnij Wrenowi rolkę albo posta, a wyczyta z nich miejsca. Albo zrób zrzut ekranu czegokolwiek — wiadomości, strony z przewodnika — a Wren go odczyta. Nazwy trafią do Map.';

  @override
  String get emptyNote =>
      'Pojedyncze miejsce trafia do przewodnika, który już masz. Kilka tworzy nowy — Mapy Apple nie potrafią łączyć przewodników.';

  @override
  String get emptyBodyAndroid =>
      'Udostępnij Wrenowi rolkę albo posta, a wyczyta z nich miejsca. Albo zrób zrzut ekranu czegokolwiek — wiadomości, strony z przewodnika — a Wren go odczyta. Nazwy trafią do aplikacji map w twoim telefonie.';

  @override
  String get emptyNoteAndroid =>
      'Odczyta też listę, którą już masz, i pokaże każde miejsce, zanim cokolwiek wyjdzie.';

  @override
  String get addScreenshots => 'Dodaj zrzuty ekranu';

  @override
  String get readingShort => 'Odczytywanie…';

  @override
  String readingProgress(int done, int total) {
    return 'Odczytywanie $done z $total…';
  }

  @override
  String get addToGuide => 'Dodaj do przewodnika';

  @override
  String makeGuide(int count) {
    return 'Utwórz przewodnik ($count)';
  }

  @override
  String get notFoundOnMap => 'Nie znaleziono na mapie';

  @override
  String get tapToSearchForIt => 'Dotknij, aby wyszukać';

  @override
  String readAs(String text) {
    return 'odczytano jako „$text”';
  }

  @override
  String notFoundBanner(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Nie znaleziono $count miejsca. Dotknij, aby je wyszukać.',
      many: 'Nie znaleziono $count miejsc. Dotknij, aby je wyszukać.',
      few: 'Nie znaleziono $count miejsc. Dotknij, aby je wyszukać.',
      one: 'Nie znaleziono 1 miejsca. Dotknij, aby je wyszukać.',
    );
    return '$_temp0';
  }

  @override
  String get whereAreThesePlaces => 'Gdzie są te miejsca?';

  @override
  String get regionDetected => 'Odczytano z podpisów. Zmień, jeśli to nie tak.';

  @override
  String get regionNotDetected =>
      'Nigdzie nie było napisane, gdzie są te miejsca. Miasto sprawia, że wyszukiwanie jest o wiele dokładniejsze.';

  @override
  String get cityOrRegion => 'Miasto lub region';

  @override
  String get cityExample => 'np. Warszawa';

  @override
  String get searchAnywhere => 'Szukaj wszędzie';

  @override
  String get findPlaces => 'Znajdź miejsca';

  @override
  String searchedIn(String region) {
    return 'Wyszukano w: $region';
  }

  @override
  String get nameThisGuide => 'Nazwij ten przewodnik';

  @override
  String nameThisGuideBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Pod tą nazwą pojawi się w Mapach Apple, z $count miejsca.',
      many: 'Pod tą nazwą pojawi się w Mapach Apple, z $count miejscami.',
      few: 'Pod tą nazwą pojawi się w Mapach Apple, z $count miejscami.',
      one: 'Pod tą nazwą pojawi się w Mapach Apple, z 1 miejscem.',
    );
    return '$_temp0';
  }

  @override
  String get guideName => 'Nazwa przewodnika';

  @override
  String get guideNameExample => 'np. Rzym, październik';

  @override
  String get createGuide => 'Utwórz przewodnik';

  @override
  String get cancel => 'Anuluj';

  @override
  String get guidesOfAnySize => 'Przewodniki bez ograniczeń';

  @override
  String get anyNumberOfPlaces => 'Dowolna liczba miejsc';

  @override
  String unlockExplain(int limit, int selected, int over) {
    return 'Wren zapisuje w przewodniku do $limit miejsc za darmo. Masz zaznaczone $selected — o $over za dużo.';
  }

  @override
  String unlockExplainAndroid(int limit, int selected, int over) {
    return 'Wren wysyła za darmo do $limit miejsc naraz. Masz zaznaczone $selected — o $over za dużo.';
  }

  @override
  String get onePaymentKept => 'Jedna płatność, na zawsze. Bez abonamentu.';

  @override
  String unlockFor(String price) {
    return 'Odblokuj za $price';
  }

  @override
  String saveFirstInstead(int limit) {
    return 'Zapisz zamiast tego pierwsze $limit';
  }

  @override
  String get restorePrevious => 'Przywróć wcześniejszy zakup';

  @override
  String get restorePurchase => 'Przywróć zakup';

  @override
  String overFreeLimit(int over, int limit) {
    return '$over ponad darmowy limit $limit. Możesz odblokować albo zapisać pierwsze $limit.';
  }

  @override
  String get findThisPlace => 'Znajdź to miejsce';

  @override
  String get searchAppleMaps => 'Szukaj w Mapach Apple';

  @override
  String searchInRegion(String region) {
    return 'Szukaj w: $region';
  }

  @override
  String get searching => 'Szukanie…';

  @override
  String get typeTwoCharacters => 'Wpisz co najmniej dwa znaki.';

  @override
  String get nothingFound =>
      'Nic nie znaleziono. Spróbuj podać ulicę albo krótszą nazwę.';

  @override
  String get rateLimited =>
      'Mapy Apple ograniczają liczbę zapytań. Odczekaj chwilę i spróbuj ponownie.';

  @override
  String rateLimitedDuringImport(int added) {
    return 'Mapy Apple ograniczają liczbę zapytań — dodano na razie $added, spróbuj resztę za chwilę.';
  }

  @override
  String importSummary(int found) {
    return 'znaleziono $found';
  }

  @override
  String importSummaryIn(String region) {
    return 'w: $region';
  }

  @override
  String importSummaryNeedLook(int count) {
    return '$count do sprawdzenia';
  }

  @override
  String importSummaryUnreadable(int count) {
    return '$count nieczytelnych';
  }

  @override
  String nothingReadable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Nic czytelnego w $count zrzutach ekranu',
      many: 'Nic czytelnego w $count zrzutach ekranu',
      few: 'Nic czytelnego w $count zrzutach ekranu',
      one: 'Nic czytelnego w tym zrzucie ekranu',
    );
    return '$_temp0';
  }

  @override
  String get couldNotOpenMaps => 'Nie udało się otworzyć Map';

  @override
  String get checkingAppleAccount => 'Sprawdzanie twojego konta…';

  @override
  String get restoredUnlocked =>
      'Przywrócono. Przewodniki bez ograniczeń są odblokowane.';

  @override
  String get noPreviousPurchase =>
      'Nie znaleziono wcześniejszego zakupu na tym koncie.';

  @override
  String get purchaseDidNotComplete =>
      'Zakup nie doszedł do skutku, więc nic nie zostało pobrane.';

  @override
  String alreadyInTheList(String name) {
    return '$name już było na liście.';
  }

  @override
  String get ocrUnavailable =>
      'Odczytywanie zrzutów ekranu wymaga iPhone\'a — na tej platformie nie ma rozpoznawania tekstu.';

  @override
  String get lookupUnavailable =>
      'Wyszukiwanie miejsc wymaga iPhone\'a — na tej platformie nie ma wyszukiwania na mapie.';

  @override
  String get compAccess => 'Bezpłatny dostęp';

  @override
  String get code => 'Kod';

  @override
  String get unlock => 'Odblokuj';

  @override
  String get compChecking => 'Sprawdzanie kodu…';

  @override
  String get compEnabled => 'Bezpłatny dostęp włączony.';

  @override
  String get compRefused =>
      'Nie rozpoznano tego kodu albo został już wykorzystany.';

  @override
  String get compTooOften =>
      'Zbyt wiele prób. Odczekaj kilka minut i spróbuj ponownie.';

  @override
  String get compUnreachable =>
      'Nie udało się połączyć z serwerem. Sprawdź połączenie i spróbuj ponownie.';

  @override
  String get compUntrusted =>
      'Nie udało się zweryfikować odpowiedzi, więc nic nie zostało odblokowane.';

  @override
  String get addPlaces => 'Dodaj';

  @override
  String get fromFile => 'Z pliku';

  @override
  String get importGuideBody =>
      'W Mapach Apple otwórz przewodnik, udostępnij go i wybierz Kopiuj łącze. Wklej je poniżej, a Wren odczyta miejsca, które już w nim są. Link do rolki albo posta też tu zadziała.';

  @override
  String get importGuideNotALink =>
      'To nie jest łącze do przewodnika Map Apple. Otwórz przewodnik w Mapach, udostępnij go i wybierz Kopiuj łącze.';

  @override
  String get importGuideSocialPost =>
      'Postów stamtąd Wren nie odczyta. Zrób zrzuty ekranu posta i udostępnij je — to działa zawsze.';

  @override
  String get importGuideNothing =>
      'W tym przewodniku nie ma nic, co Wren mógłby przenieść.';

  @override
  String importedGuideSummary(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Odczytano $count miejsca z tego przewodnika',
      many: 'Odczytano $count miejsc z tego przewodnika',
      few: 'Odczytano $count miejsca z tego przewodnika',
      one: 'Odczytano 1 miejsce z tego przewodnika',
    );
    return '$_temp0';
  }

  @override
  String importedGuideUnusable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count miejsca nie trafi do nowego przewodnika',
      many: '$count miejsc nie trafi do nowego przewodnika',
      few: '$count miejsca nie trafią do nowego przewodnika',
      one: '1 miejsce nie trafi do nowego przewodnika',
    );
    return '$_temp0';
  }

  @override
  String alreadyInGuide(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count miejsca już w tym przewodniku',
      many: '$count miejsc już w tym przewodniku',
      few: '$count miejsca już w tym przewodniku',
      one: '1 miejsce już w tym przewodniku',
    );
    return '$_temp0';
  }

  @override
  String fromGuideNamed(String name) {
    return 'Z „$name”';
  }

  @override
  String get republishTitle => 'Mapy tworzą nowy przewodnik';

  @override
  String republishBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Apple nie pozwala dodawać miejsc do przewodnika, który już istnieje, więc Wren utworzy nowy — z $count miejsca.',
      many:
          'Apple nie pozwala dodawać miejsc do przewodnika, który już istnieje, więc Wren utworzy nowy — ze wszystkimi $count miejscami.',
      few:
          'Apple nie pozwala dodawać miejsc do przewodnika, który już istnieje, więc Wren utworzy nowy — ze wszystkimi $count miejscami.',
      one:
          'Apple nie pozwala dodawać miejsc do przewodnika, który już istnieje, więc Wren utworzy nowy — z tym 1 miejscem.',
    );
    return '$_temp0';
  }

  @override
  String get republishThenDelete => 'Zachowaj nowy przewodnik i usuń stary.';

  @override
  String get republishKeepsPlaces =>
      'Wren zachowuje te miejsca, więc jeśli coś pójdzie nie tak, możesz utworzyć przewodnik ponownie.';

  @override
  String get makeCombinedGuide => 'Utwórz połączony przewodnik';

  @override
  String fileImportSummary(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Odczytano $count miejsca z tego pliku',
      many: 'Odczytano $count miejsc z tego pliku',
      few: 'Odczytano $count miejsca z tego pliku',
      one: 'Odczytano 1 miejsce z tego pliku',
    );
    return '$_temp0';
  }

  @override
  String fileImportSkipped(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count wiersza nie miało nazwy',
      many: '$count wierszy nie miało nazwy',
      few: '$count wiersze nie miały nazwy',
      one: '1 wiersz nie miał nazwy',
    );
    return '$_temp0';
  }

  @override
  String get fileNoPlaces => 'Brak miejsc w tym pliku.';

  @override
  String get fileUnreadable =>
      'Wren nie mógł odczytać tego pliku. Odczytuje eksporty CSV, KML, KMZ, GPX, GeoJSON i Google Takeout.';

  @override
  String lookingUpProgress(int done, int total) {
    return 'Wyszukiwanie $done z $total…';
  }

  @override
  String get combineNeedsUnlock => 'Połączony przewodnik wymaga odblokowania.';

  @override
  String get unlockCombineTitle => 'Dodaj do przewodnika, który już masz';

  @override
  String unlockCombineBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Wren utworzy jeden przewodnik, w którym będzie $count miejsca z twojego i te nowe.',
      many:
          'Wren utworzy jeden przewodnik, w którym będzie $count miejsc z twojego i te nowe.',
      few:
          'Wren utworzy jeden przewodnik, w którym będą $count miejsca z twojego i te nowe.',
      one:
          'Wren utworzy jeden przewodnik, w którym będzie 1 miejsce z twojego i te nowe.',
    );
    return '$_temp0';
  }

  @override
  String get acceptedFormats =>
      'Odczytuje też listę wyeksportowaną z innej aplikacji: CSV, KML, KMZ, GPX, GeoJSON lub Google Takeout.';

  @override
  String get clearList => 'Wyczyść listę';

  @override
  String get clearListTitle => 'Wyczyść listę';

  @override
  String clearListBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Usunąć wszystkie $count miejsca z Wrena? Przewodniki już utworzone w Mapach Apple pozostaną bez zmian.',
      many:
          'Usunąć wszystkie $count miejsc z Wrena? Przewodniki już utworzone w Mapach Apple pozostaną bez zmian.',
      few:
          'Usunąć wszystkie $count miejsca z Wrena? Przewodniki już utworzone w Mapach Apple pozostaną bez zmian.',
      one:
          'Usunąć to jedno miejsce z Wrena? Przewodniki już utworzone w Mapach Apple pozostaną bez zmian.',
    );
    return '$_temp0';
  }

  @override
  String get clearListConfirm => 'Usuń';

  @override
  String get listCleared => 'Lista wyczyszczona.';

  @override
  String get expandingLink => 'Odczytywanie łącza…';

  @override
  String get linkUnreachable =>
      'Nie udało się połączyć z Apple, aby odczytać to łącze. Sprawdź połączenie i spróbuj ponownie.';

  @override
  String get splitTitle => 'Powstanie więcej niż jeden przewodnik';

  @override
  String splitBody(int guides, int count) {
    return 'Apple ogranicza, ile miejsc może pomieścić jedno łącze do przewodnika. Wren utworzy więc kilka przewodników ($guides), ponumerowanych tak, by kolejność się zachowała, i rozłoży w nich wszystkie miejsca ($count).';
  }

  @override
  String splitConfirm(int guides) {
    return 'Utwórz przewodniki ($guides)';
  }

  @override
  String splitProgress(int done, int total) {
    return 'Przewodnik $done z $total otwarty. Dotknij, aby utworzyć następny.';
  }

  @override
  String get sendPlacesTo => 'Wyślij miejsca do';

  @override
  String sendPlacesReady(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count miejsca gotowe do wysłania',
      many: '$count miejsc gotowych do wysłania',
      few: '$count miejsca gotowe do wysłania',
      one: '1 miejsce gotowe do wysłania',
    );
    return '$_temp0';
  }

  @override
  String sendPlacesNoLocation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count miejsca nie mają lokalizacji i nie da się ich wysłać',
      many: '$count miejsc nie ma lokalizacji i nie da się ich wysłać',
      few: '$count miejsca nie mają lokalizacji i nie da się ich wysłać',
      one: '1 miejsce nie ma lokalizacji i nie da się go wysłać',
    );
    return '$_temp0';
  }

  @override
  String get sendPlacesOtherApp => 'Dowolna inna aplikacja';

  @override
  String get sendPlacesFailed => 'Ta aplikacja nie przyjęła pliku';

  @override
  String fileImportPositioned(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count miejsca z pliku gotowe do wysłania do innej aplikacji map',
      many: '$count miejsc z pliku gotowych do wysłania do innej aplikacji map',
      few: '$count miejsca z pliku gotowe do wysłania do innej aplikacji map',
      one: '1 miejsce z pliku gotowe do wysłania do innej aplikacji map',
    );
    return '$_temp0';
  }

  @override
  String get compExpiring =>
      'Wren nie mógł potwierdzić Twojego bezpłatnego dostępu. Połącz się z internetem w ciągu najbliższych kilku dni, aby go zachować.';

  @override
  String get reelsTitle => 'Miejsca z posta';

  @override
  String get reelsExplain =>
      'Udostępnij Wrenowi rolkę lub posta, a wyczyta z niego miejsca – gotowe do sprawdzenia i zapisania. Wren nigdy nie zatrzymuje filmu.';

  @override
  String everythingFor(String price) {
    return 'Wszystko za $price';
  }

  @override
  String addPostsFor(String price) {
    return 'Dodaj posty za $price';
  }

  @override
  String get everythingAlsoReadsPosts =>
      'Wyczytuje też miejsca z udostępnionego posta.';

  @override
  String get readingPost => 'Czytam posta…';

  @override
  String reelsLeftThisMonth(int count) {
    return 'postów w tym miesiącu zostało: $count';
  }

  @override
  String reelQuotaUsedUp(String date) {
    return 'To wszystkie posty w tym miesiącu. Limit wróci $date.';
  }

  @override
  String get reelQuotaSoon => 'kilka tygodni';

  @override
  String get reelBusy =>
      'Wren wciąż czyta poprzedniego posta. Spróbuj za chwilę.';

  @override
  String get reelUnavailable =>
      'Nie udało się otworzyć tego posta. Może być prywatny, usunięty albo niedostępny tutaj.';

  @override
  String get reelCouldNotRead =>
      'Wren nie zdołał odczytać tego posta. Zrób zrzuty ekranu i udostępnij je – to działa zawsze.';

  @override
  String get reelNoPlaces =>
      'Nic w tym poście nie wyglądało na miejsce, do którego można pójść.';

  @override
  String get reelUnreachable =>
      'Wren nie połączył się z serwerem, żeby odczytać tego posta. Z limitu nic nie ubyło.';

  @override
  String get reelNeedsRestore =>
      'Najpierw dotknij Przywróć zakup, żeby Wren mógł pokazać sklepowi twój paragon.';

  @override
  String get compEnabledEverything =>
      'Dostęp bezpłatny włączony, razem z miejscami z posta.';

  @override
  String get restoredEverything =>
      'Przywrócono. Przewodniki dowolnej wielkości i miejsca z posta.';

  @override
  String get fromGuideOrPost => 'Z linku';

  @override
  String get fromPost => 'Z posta';

  @override
  String get importLinkTitle => 'Dodaj z linku';

  @override
  String get importPostBody =>
      'Wklej link do rolki lub posta, a Wren wyczyta z niego miejsca. Wren nigdy nie zatrzymuje filmu.';

  @override
  String get linkLabel => 'Link';

  @override
  String get readLink => 'Odczytaj';
}
