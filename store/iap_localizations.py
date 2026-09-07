"""Localised names and descriptions for the two reel in-app purchases.

    python store/iap_localizations.py            # show what would change
    python store/iap_localizations.py --write    # send it

Apple shows these two strings on the purchase sheet, in the App Store listing
and to the reviewer, and it checks the description against what the purchase
actually does. They are also the only place a person sees the product named
outside the app, so they say what it does rather than what tier it is.

Caps are Apple's: 30 characters for a name, 45 for a description, counted in
characters and not bytes. They are asserted here rather than discovered at
upload, because a 400 from ASC names the field and not the locale.

The vocabulary is deliberately the app's own. "Places from a post" is
`reelsTitle` in lib/l10n, and each translation below is the same phrase in the
same language, so that somebody who reads the sheet and then opens the app is
reading one product and not two.

Fifty locales, matching the existing `unlimited` product. Regenerate by editing
the tables and running with --write; existing localisations are PATCHed and
missing ones POSTed, so this is safe to re-run.
"""
import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from submit import call, errs  # noqa: E402

APP = "6802053382"
NAME_CAP, DESC_CAP = 30, 45

# Everything: uncapped guides and reading posts, for somebody who owns nothing.
EVERYTHING = {
    "ar-SA": ("كل ما يفعله Wren", "أماكن من منشور، وأدلة بأي حجم."),
    "bn-BD": ("Wren-এর সবকিছু", "পোস্ট থেকে জায়গা, আর যেকোনো আকারের গাইড।"),
    "ca": ("Tot el que fa el Wren", "Llocs d'una publicació i guies sense límit."),
    "cs": ("Vše, co Wren umí", "Místa z příspěvku a průvodci bez omezení."),
    "da": ("Alt hvad Wren kan", "Steder fra opslag og guider uden grænser."),
    "de-DE": ("Alles, was Wren kann", "Orte aus einem Beitrag und Guides ohne Limit."),
    "el": ("Όλα όσα κάνει το Wren", "Μέρη από ανάρτηση και οδηγοί κάθε μεγέθους."),
    "en-AU": ("Everything Wren does", "Places from a post, and guides of any size."),
    "en-CA": ("Everything Wren does", "Places from a post, and guides of any size."),
    "en-GB": ("Everything Wren does", "Places from a post, and guides of any size."),
    "en-US": ("Everything Wren does", "Places from a post, and guides of any size."),
    "es-ES": ("Todo lo que hace Wren", "Lugares de una publicación y guías sin tope."),
    "es-MX": ("Todo lo que hace Wren", "Lugares de una publicación y guías sin tope."),
    "fi": ("Kaikki mitä Wren osaa", "Paikat julkaisusta ja oppaat ilman rajoja."),
    "fr-CA": ("Tout ce que fait Wren", "Lieux d'une publication et guides illimités."),
    "fr-FR": ("Tout ce que fait Wren", "Lieux d'une publication et guides illimités."),
    "gu-IN": ("Wren જે કરે છે તે બધું", "પોસ્ટમાંથી જગ્યાઓ અને કોઈ પણ કદની ગાઇડ."),
    "he": ("כל מה ש‑Wren עושה", "מקומות מפוסט ומדריכים בכל גודל."),
    "hi": ("Wren जो कुछ करता है", "पोस्ट से जगहें और किसी भी आकार की गाइड।"),
    "hr": ("Sve što Wren radi", "Mjesta iz objave i vodiči bez ograničenja."),
    "hu": ("Minden, amit a Wren tud", "Helyek bejegyzésből és bármekkora útikalauz."),
    "id": ("Semua yang bisa Wren", "Tempat dari unggahan dan panduan tanpa batas."),
    "it": ("Tutto quello che fa Wren", "I luoghi di un post e guide senza limiti."),
    "ja": ("Wrenのすべての機能", "投稿から場所を読み取り、件数無制限のガイド。"),
    "kn-IN": ("Wren ಮಾಡುವ ಎಲ್ಲವೂ", "ಪೋಸ್ಟ್‌ನಿಂದ ಸ್ಥಳಗಳು, ಯಾವುದೇ ಗಾತ್ರದ ಗೈಡ್."),
    "ko": ("Wren의 모든 기능", "게시물에서 장소 찾기와 크기 제한 없는 가이드."),
    "ml-IN": ("Wren ചെയ്യുന്നതെല്ലാം", "പോസ്റ്റിൽ നിന്ന് സ്ഥലങ്ങളും ഏത് വലുപ്പ ഗൈഡും."),
    "mr-IN": ("Wren जे करतो ते सर्व", "पोस्टमधली ठिकाणं आणि कितीही मोठ्या गाईड."),
    "ms": ("Semua yang Wren buat", "Tempat daripada siaran dan panduan tanpa had."),
    "nl-NL": ("Alles wat Wren kan", "Plekken uit een post en gidsen zonder limiet."),
    "no": ("Alt Wren kan", "Steder fra et innlegg og guider uten grenser."),
    "or-IN": ("Wren କରୁଥିବା ସବୁକିଛି", "ପୋଷ୍ଟରୁ ସ୍ଥାନ ଓ ଯେକୌଣସି ଆକାରର ଗାଇଡ୍।"),
    "pa-IN": ("Wren ਜੋ ਕਰਦਾ ਹੈ ਸਭ", "ਪੋਸਟ ਵਿੱਚੋਂ ਥਾਵਾਂ ਅਤੇ ਹਰ ਆਕਾਰ ਦੀਆਂ ਗਾਈਡਾਂ।"),
    "pl": ("Wszystko, co Wren umie", "Miejsca z posta i przewodniki bez limitu."),
    "pt-BR": ("Tudo o que o Wren faz", "Lugares de uma publicação e guias sem limite."),
    "pt-PT": ("Tudo o que o Wren faz", "Lugares de uma publicação e guias sem limite."),
    "ro": ("Tot ce face Wren", "Locuri dintr-o postare și ghiduri nelimitate."),
    "ru": ("Всё, что умеет Wren", "Места из публикации и любые путеводители."),
    "sk": ("Všetko, čo Wren vie", "Miesta z príspevku a sprievodca bez limitu."),
    "sl-SI": ("Vse, kar Wren zmore", "Kraji iz objave in vodniki brez omejitev."),
    "sv": ("Allt Wren kan", "Platser från inlägg och guider utan gräns."),
    "ta-IN": ("Wren செய்யும் அனைத்தும்", "இடுகையிலிருந்து இடங்கள், வரம்பற்ற வழிகாட்டி."),
    "te-IN": ("Wren చేసేదంతా", "పోస్ట్ నుంచి ప్రదేశాలు, ఎంత పెద్ద గైడ్‌లైనా."),
    "th": ("ทุกอย่างที่ Wren ทำได้", "สถานที่จากโพสต์ และไกด์ไม่จำกัดจำนวน"),
    "tr": ("Wren'in yaptığı her şey", "Gönderiden yerler ve sınırsız boyutta rehber."),
    "uk": ("Усе, що вміє Wren", "Місця з допису і путівники без обмежень."),
    "ur-PK": ("Wren جو کچھ کرتا ہے", "پوسٹ سے مقامات اور کسی بھی حجم کی گائیڈز۔"),
    "vi": ("Mọi thứ Wren làm được", "Địa điểm từ bài đăng và hướng dẫn mọi cỡ."),
    "zh-Hans": ("Wren 的全部功能", "从帖子里找地点，指南不限数量。"),
    "zh-Hant": ("Wren 的全部功能", "從貼文裡找地點，指南不限數量。"),
}

# The upgrade, shown only to somebody who already owns the base unlock. Its
# description says "adds", because that is the whole difference between the two
# products and the only thing a buyer here needs to know.
UPGRADE = {
    "ar-SA": ("أماكن من منشور", "يضيف قراءة ريل أو منشور تشاركه."),
    "bn-BD": ("পোস্ট থেকে জায়গা", "শেয়ার করা রিল বা পোস্ট পড়া যোগ করে।"),
    "ca": ("Llocs d'una publicació", "Afegeix llegir un reel o una publicació."),
    "cs": ("Místa z příspěvku", "Přidá čtení sdíleného reelu či příspěvku."),
    "da": ("Steder fra et opslag", "Tilføjer læsning af et delt reel/opslag."),
    "de-DE": ("Orte aus einem Beitrag", "Ergänzt das Lesen geteilter Beiträge."),
    "el": ("Μέρη από μια ανάρτηση", "Προσθέτει την ανάγνωση κοινής ανάρτησης."),
    "en-AU": ("Places from a post", "Adds reading a shared reel or post."),
    "en-CA": ("Places from a post", "Adds reading a shared reel or post."),
    "en-GB": ("Places from a post", "Adds reading a shared reel or post."),
    "en-US": ("Places from a post", "Adds reading a shared reel or post."),
    "es-ES": ("Lugares de una publicación", "Añade leer un reel o publicación compartida."),
    "es-MX": ("Lugares de una publicación", "Agrega leer un reel o publicación compartida."),
    "fi": ("Paikat julkaisusta", "Lisää jaetun reelin tai julkaisun lukemisen."),
    "fr-CA": ("Les lieux d'une publication", "Ajoute la lecture d'un reel ou publication."),
    "fr-FR": ("Les lieux d'une publication", "Ajoute la lecture d'un reel ou publication."),
    "gu-IN": ("પોસ્ટમાંથી જગ્યાઓ", "શેર કરેલી રીલ કે પોસ્ટ વાંચવાનું ઉમેરે છે."),
    "he": ("מקומות מתוך פוסט", "מוסיף קריאת ריל או פוסט משותף."),
    "hi": ("पोस्ट से जगहें", "शेयर की गई रील या पोस्ट पढ़ना जोड़ता है।"),
    "hr": ("Mjesta iz objave", "Dodaje čitanje podijeljenog reela ili objave."),
    "hu": ("Helyek egy bejegyzésből", "Hozzáadja a megosztott bejegyzés olvasását."),
    "id": ("Tempat dari unggahan", "Menambah pembacaan reel atau unggahan."),
    "it": ("I luoghi di un post", "Aggiunge la lettura di un reel o di un post."),
    "ja": ("投稿から場所を読む", "共有されたリールや投稿の読み取りを追加。"),
    "kn-IN": ("ಪೋಸ್ಟ್‌ನಿಂದ ಸ್ಥಳಗಳು", "ಹಂಚಿದ ರೀಲ್/ಪೋಸ್ಟ್ ಓದುವಿಕೆ ಸೇರಿಸುತ್ತದೆ."),
    "ko": ("게시물에서 장소 찾기", "공유된 릴스나 게시물 읽기를 추가합니다."),
    "ml-IN": ("പോസ്റ്റിൽ നിന്ന് സ്ഥലങ്ങൾ", "പങ്കിട്ട റീൽ/പോസ്റ്റ് വായന ചേർക്കുന്നു."),
    "mr-IN": ("पोस्टमधली ठिकाणं", "शेअर केलेली रील किंवा पोस्ट वाचणं जोडतं."),
    "ms": ("Tempat daripada siaran", "Menambah pembacaan reel atau siaran."),
    "nl-NL": ("Plekken uit een post", "Voegt het lezen van een gedeelde post toe."),
    "no": ("Steder fra et innlegg", "Legger til lesing av delt reel/innlegg."),
    "or-IN": ("ପୋଷ୍ଟରୁ ସ୍ଥାନ", "ଶେୟାର୍ ହୋଇଥିବା ପୋଷ୍ଟ ପଢ଼ିବା ଯୋଡ଼େ।"),
    "pa-IN": ("ਪੋਸਟ ਵਿੱਚੋਂ ਥਾਵਾਂ", "ਸਾਂਝੀ ਰੀਲ ਜਾਂ ਪੋਸਟ ਪੜ੍ਹਨਾ ਜੋੜਦਾ ਹੈ।"),
    "pl": ("Miejsca z posta", "Dodaje odczyt udostępnionej rolki lub posta."),
    "pt-BR": ("Lugares de uma publicação", "Adiciona a leitura de um reel ou publicação."),
    "pt-PT": ("Lugares de uma publicação", "Adiciona a leitura de um reel ou publicação."),
    "ro": ("Locuri dintr-o postare", "Adaugă citirea unui reel sau a unei postări."),
    "ru": ("Места из публикации", "Добавляет чтение рилса или публикации."),
    "sk": ("Miesta z príspevku", "Pridá čítanie zdieľaného reelu či príspevku."),
    "sl-SI": ("Kraji iz objave", "Doda branje deljenega reela ali objave."),
    "sv": ("Platser från ett inlägg", "Lägger till läsning av ett delat inlägg."),
    "ta-IN": ("இடுகையிலிருந்து இடங்கள்", "பகிர்ந்த ரீல்/இடுகை வாசிப்பைச் சேர்க்கும்."),
    "te-IN": ("పోస్ట్ నుంచి ప్రదేశాలు", "పంచుకున్న రీల్/పోస్ట్ చదవడాన్ని జోడిస్తుంది."),
    "th": ("สถานที่จากโพสต์", "เพิ่มการอ่านรีลหรือโพสต์ที่แชร์มา"),
    "tr": ("Bir gönderideki yerler", "Paylaşılan gönderiyi okumayı ekler."),
    "uk": ("Місця з допису", "Додає читання рілса або допису."),
    "ur-PK": ("پوسٹ سے مقامات", "شیئر کی گئی ریل یا پوسٹ پڑھنا شامل کرتا ہے۔"),
    "vi": ("Địa điểm từ bài đăng", "Thêm việc đọc reel hay bài đăng chia sẻ."),
    "zh-Hans": ("从帖子里找地点", "增加读取分享来的 Reels 或帖子。"),
    "zh-Hant": ("從貼文裡找地點", "增加讀取分享來的 Reels 或貼文。"),
}

PRODUCTS = {
    "com.spencerfields.littlebird.everything": EVERYTHING,
    "com.spencerfields.littlebird.reels.upgrade": UPGRADE,
}


def over_cap():
    """Every string that Apple would refuse, named before anything is sent."""
    bad = []
    for product, table in PRODUCTS.items():
        for locale, (name, desc) in table.items():
            if len(name) > NAME_CAP:
                bad.append(f"{product} {locale} name {len(name)}/{NAME_CAP}: {name}")
            if len(desc) > DESC_CAP:
                bad.append(f"{product} {locale} desc {len(desc)}/{DESC_CAP}: {desc}")
    return bad


def iap_ids():
    st, d = call("GET", f"apps/{APP}/inAppPurchasesV2?limit=50", version="v1")
    if st != 200:
        sys.exit(f"inAppPurchasesV2 -> {st}: {errs(d)}")
    return {i["attributes"]["productId"]: i["id"] for i in d.get("data", [])}


def existing(iap):
    st, d = call("GET",
                 f"inAppPurchases/{iap}/inAppPurchaseLocalizations?limit=200",
                 version="v2")
    if st != 200:
        sys.exit(f"localizations for {iap} -> {st}: {errs(d)}")
    return {r["attributes"]["locale"]: r for r in d.get("data", [])}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

    bad = over_cap()
    if bad:
        print("\n".join(bad))
        sys.exit(f"{len(bad)} strings over Apple's cap — nothing sent")

    ids = iap_ids()
    failures = 0
    for product, table in PRODUCTS.items():
        iap = ids.get(product)
        if not iap:
            sys.exit(f"no in-app purchase with productId {product}")
        have = existing(iap)
        print(f"\n{product} ({iap}): {len(have)} present, {len(table)} wanted")
        for locale in sorted(table):
            name, desc = table[locale]
            row = have.get(locale)
            same = row and row["attributes"]["name"] == name \
                and row["attributes"]["description"] == desc
            verb = "same" if same else ("patch" if row else "create")
            print(f"  {verb:6} {locale:8} {name}  |  {desc}")
            if same or not args.write:
                continue
            if row:
                st, d = call("PATCH",
                             f"inAppPurchaseLocalizations/{row['id']}",
                             {"data": {"type": "inAppPurchaseLocalizations",
                                       "id": row["id"],
                                       "attributes": {"name": name,
                                                      "description": desc}}},
                             version="v2")
                ok = st == 200
            else:
                st, d = call("POST", "inAppPurchaseLocalizations",
                             {"data": {"type": "inAppPurchaseLocalizations",
                                       "attributes": {"locale": locale,
                                                      "name": name,
                                                      "description": desc},
                                       "relationships": {"inAppPurchaseV2": {
                                           "data": {"type": "inAppPurchases",
                                                    "id": iap}}}}},
                             version="v2")
                ok = st in (200, 201)
            if not ok:
                failures += 1
                print(f"    ! {st}: {errs(d)}")

    if not args.write:
        print("\nnothing sent — run with --write")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
