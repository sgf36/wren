<?php
// Country of an IP address, for /get/'s anonymous tally. Lives outside the web
// root in <home>/wren-geo/, beside the database store/geo.py keeps there.
//
// Only a two-letter country code ever leaves this function, and the caller
// adds it to a count; the address itself is never written anywhere. The data
// is MaxMind's GeoLite2 Country, under MaxMind's GeoLite2 licence (attribution
// on the privacy page); update.php replaces it weekly, inside the licence's
// 30-day limit. Any failure answers '' so a lookup can never cost a redirect.

function geo_country(string $ip): string
{
    static $reader = false;
    try {
        if ($reader === false) {
            $reader = null;
            $db = __DIR__ . '/GeoLite2-Country.mmdb';
            if (is_file($db)) {
                foreach (['Reader/InvalidDatabaseException', 'Reader/Util', 'Reader/Decoder', 'Reader/Metadata', 'Reader'] as $f) {
                    require_once __DIR__ . "/MaxMind/Db/$f.php";
                }
                $reader = new MaxMind\Db\Reader($db);
            }
        }
        if (!$reader || !filter_var($ip, FILTER_VALIDATE_IP)) {
            return '';
        }
        $r = $reader->get($ip);
        $cc = (string) ($r['country']['iso_code'] ?? $r['registered_country']['iso_code'] ?? '');
        return preg_match('/^[A-Z]{2}$/', $cc) ? $cc : '';
    } catch (Throwable $e) {
        return '';
    }
}
