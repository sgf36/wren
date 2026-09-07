"""Take Apple's product name back out of the promotional text and release notes.

    python store/unname_maps.py            # show what would change
    python store/unname_maps.py --write    # rewrite the metadata files

Wren was rejected under guideline 5.2.5 once already, over an Apple product name
in the subtitle. The copy that came back from that has a shape, and every
approved release since has kept it:

    subtitle          never names Apple Maps
    keywords          never
    promotional text  never — "one guide on your map"
    release notes     never
    description       yes, five times, and approved

The 2.0 rewrite broke the middle two, in forty-three and forty-six locales. The
description is body copy, below the fold, and referential use there has been
accepted repeatedly. Promotional text sits at the very top of the product page
and is the nearest thing to a second subtitle, which is exactly where the
rejection came from.

The name is only obvious in English. Elsewhere Apple calls the app by the local
word for maps — Plans, Karten, Mapas, マップ, 지도 — so the same mistake reads as
an ordinary noun and would have gone unnoticed. The replacements below make it
an ordinary noun in fact, by making it possessive: your map, rather than Maps.
"""
import argparse
import collections
import glob
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# Apple's own name for the Maps app in each App Store locale, used only to
# assert afterwards that none is left.
NAME = {
    'ar_SA': 'الخرائط', 'bn_BD': 'ম্যাপ', 'ca': 'Mapes', 'da': 'Kort',
    'de_DE': 'Karten', 'el': 'Χάρτες', 'en_AU': 'Apple Maps',
    'en_CA': 'Apple Maps', 'en_GB': 'Apple Maps', 'es_ES': 'Mapas',
    'es_MX': 'Mapas', 'fi': 'Kartat', 'fr_CA': 'Plans', 'fr_FR': 'Plans',
    'gu_IN': 'નકશા', 'he': 'מפות', 'hi': 'मैप्स', 'hr': 'Karte',
    'hu': 'Térkép', 'id': 'Peta', 'it': 'Mappe', 'ja': 'マップ',
    'kn_IN': 'ನಕ್ಷೆ', 'ko': '지도', 'ml_IN': 'മാപ്സ്', 'mr_IN': 'नकाशा',
    'ms': 'Peta', 'nl_NL': 'Kaarten', 'no': 'Kart', 'or_IN': 'ମାନଚିତ୍ର',
    'pa_IN': 'ਨਕਸ਼ਿਆਂ', 'pl': 'Map', 'pt_BR': 'Mapas', 'pt_PT': 'Mapas',
    'ro': 'Hărți', 'ru': 'Карты', 'sk': 'Mapách', 'sl_SI': 'Zemljevid',
    'sv': 'Kartor', 'ta_IN': 'வரைபட', 'te_IN': 'మ్యాప్స్', 'th': 'แผนที่',
    'tr': 'Harita', 'uk': 'Карти', 'ur_PK': 'نقشو', 'vi': 'Bản đồ',
    'zh_Hans': '地图', 'zh_Hant': '地圖',
}

# The destination clause, and the same clause made possessive. Applied to both
# fields, because both were written from one English sentence and both say it
# the same way.
FIX = {
    'en_GB': [('save to Apple Maps', 'save to your map')],
    'en_AU': [('save to Apple Maps', 'save to your map')],
    'en_CA': [('save to Apple Maps', 'save to your map')],
    'ar_SA': [('والحفظ في الخرائط', 'والحفظ في خريطتك')],
    'bn_BD': [('ম্যাপ-এ সেভ', 'আপনার ম্যাপে সেভ')],
    'ca': [('desar a Mapes', 'desar al teu mapa')],
    'da': [('gemme i Kort', 'gemme på dit kort')],
    'cs': [('uložení do Map', 'uložení na tvou mapu')],
    'de_DE': [('Speichern in Karten', 'Speichern auf deiner Karte')],
    'el': [('αποθήκευση στους Χάρτες', 'αποθήκευση στον χάρτη σου')],
    'es_ES': [('guardar en Mapas', 'guardar en tu mapa')],
    'es_MX': [('guardar en Mapas', 'guardar en tu mapa')],
    # Three inflections between the two fields, which is Finnish.
    'fi': [('tallennettaviksi Kartat-sovellukseen',
            'tallennettaviksi omaan karttaasi'),
           ('tallennettaviksi Kartoissa', 'tallennettaviksi omaan karttaasi'),
           ('päätyvät Kartat-sovellukseen', 'päätyvät omaan karttaasi')],
    # The French listing is vous throughout, unlike the app's copy.
    'fr_CA': [('enregistrer dans Plans', 'enregistrer sur votre carte')],
    # The French listing is vous throughout, unlike the app's copy.
    'fr_FR': [('enregistrer dans Plans', 'enregistrer sur votre carte')],
    'gu_IN': [('નકશામાં સાચવવા', 'તમારા નકશામાં સાચવવા')],
    'he': [('ולשמירה במפות', 'ולשמירה במפה שלכם')],
    'hi': [('मैप्स में सहेजने', 'अपने मैप में सहेजने')],
    'hr': [('spremanje u Karte', 'spremanje na tvoju kartu')],
    'hu': [('a Térképekbe mentésre', 'a térképedre mentésre')],
    'id': [('disimpan ke Peta', 'disimpan ke petamu')],
    'it': [('salvare in Mappe', 'salvare sulla tua mappa')],
    'ja': [('マップに保存', 'お使いの地図に保存')],
    'kn_IN': [('ನಕ್ಷೆಗೆ ಉಳಿಸ', 'ನಿಮ್ಮ ನಕ್ಷೆಗೆ ಉಳಿಸ')],
    # The promo says "저장하세요" and the release note "저장할 수", so the
    # shared prefix is what is replaced.
    'ko': [('지도에 저장', '쓰던 앱에 저장')],
    'ml_IN': [('മാപ്സിൽ സേവ്', 'നിങ്ങളുടെ മാപ്പിൽ സേവ്')],
    'mr_IN': [('नकाशांमध्ये जतन', 'तुमच्या नकाशात जतन')],
    'ms': [('disimpan ke Peta', 'disimpan ke peta kamu')],
    'nl_NL': [('in Kaarten te bewaren', 'op je kaart te bewaren')],
    'no': [('lagre i Kart', 'lagre på kartet ditt')],
    'or_IN': [('ମାନଚିତ୍ରରେ ସାଇତିବା', 'ଆପଣଙ୍କ ମାନଚିତ୍ରରେ ସାଇତିବା')],
    'pa_IN': [('ਨਕਸ਼ਿਆਂ ਵਿੱਚ ਸੰਭਾਲਣ', 'ਆਪਣੇ ਨਕਸ਼ੇ ਵਿੱਚ ਸੰਭਾਲਣ')],
    'pl': [('zapisania w Mapach', 'zapisania na twojej mapie')],
    'pt_BR': [('salvar no Mapas', 'salvar no seu mapa')],
    'pt_PT': [('guardar no Mapas', 'guardar no teu mapa')],
    'ro': [('salvat în Hărți', 'salvat pe harta ta')],
    'ru': [('сохранению в Карты', 'сохранению на своей карте'),
           ('сохранению в Картах', 'сохранению на своей карте')],
    'sk': [('uloženie do Máp', 'uloženie na tvoju mapu'),
           ('uloženiu do Máp', 'uloženiu na tvoju mapu')],
    'sl_SI': [('shranjevanje v Zemljevide', 'shranjevanje na svoj zemljevid'),
              ('shranjevanju v Zemljevide', 'shranjevanju na svoj zemljevid')],
    'sv': [('sparas i Kartor', 'sparas på din karta')],
    'ta_IN': [('வரைபடத்தில் சேமிக்க', 'உங்கள் வரைபடத்தில் சேமிக்க')],
    'te_IN': [('మ్యాప్స్‌లో భద్రపరచ', 'మీ మ్యాప్‌లో భద్రపరచ')],
    'th': [('บันทึกลงแผนที่', 'บันทึกลงแผนที่ของคุณ')],
    # The promo is active and the release note passive: kaydet- and kaydedil-.
    'tr': [("Harita'ya kaydet", 'haritana kaydet'),
           ("Harita'ya kaydedil", 'haritana kaydedil')],
    'uk': [('збереження в Карти', 'збереження на своїй карті'),
           ('збереження в Картах', 'збереження на своїй карті')],
    'ur_PK': [('نقشوں میں محفوظ', 'اپنے نقشے میں محفوظ')],
    'vi': [('lưu vào Bản đồ', 'lưu vào bản đồ của bạn')],
    'zh_Hans': [('保存到地图', '保存到你的地图')],
    'zh_Hant': [('儲存到地圖', '儲存到你的地圖')],
}

FIELDS = ('promotionalText', 'whatsNew')
CAPS = {'promotionalText': 170, 'whatsNew': 4000}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--write', action='store_true')
    args = ap.parse_args()
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except (AttributeError, OSError):
        pass

    left, over, touched = [], [], 0
    for path in sorted(glob.glob(os.path.join(HERE, 'metadata_*.json'))):
        loc = os.path.basename(path)[len('metadata_'):-len('.json')]
        d = json.load(io.open(path, encoding='utf-8'),
                      object_pairs_hook=collections.OrderedDict)
        hits = 0
        for field in FIELDS:
            v = d.get(field, '')
            for old, new in FIX.get(loc, []):
                if old in v:
                    hits += v.count(old)
                    v = v.replace(old, new)
            d[field] = v
            if len(v) > CAPS[field]:
                over.append(f'{loc} {field} {len(v)}/{CAPS[field]}')

        # Looking for the product name in the RESULT cannot work: the fix
        # makes it possessive, so "your map" still contains "map". What is
        # provable is that no clause this file set out to replace survives,
        # and that a locale with a rule actually matched something.
        # Several rules only prepend a possessive, so the old clause is
        # necessarily still inside the new one. Those are proved by the new
        # clause being present instead.
        survived = []
        for was, now in FIX.get(loc, []):
            done = any(now in d.get(f, '') for f in FIELDS)
            if was in now:
                if not done:
                    survived.append(was)
            elif any(was in d.get(f, '') for f in FIELDS):
                survived.append(was)
        if survived:
            left.append(f'{loc}: clause not replaced: {survived}')
        elif loc in FIX and not hits:
            left.append(f'{loc}: rule matched nothing at all')

        print(f'{loc:8} {hits} replaced, '
              f'promo {len(d["promotionalText"])}/{CAPS["promotionalText"]}'
              + ('  <-- MISSED' if survived or (loc in FIX and not hits)
                 else ''))
        if hits:
            touched += 1
        if args.write and not over:
            io.open(path, 'w', encoding='utf-8', newline='\n').write(
                json.dumps(d, ensure_ascii=False, indent=2) + '\n')

    print(f'\n{touched} locales changed')
    if over:
        print('OVER APPLE\'S CAP — nothing written:\n  ' + '\n  '.join(over))
    if left:
        print('NOT FULLY REPLACED:\n  ' + '\n  '.join(left))
    if not args.write:
        print('\nnothing written — run with --write')
    return 1 if (over or left) else 0


if __name__ == '__main__':
    sys.exit(main())
