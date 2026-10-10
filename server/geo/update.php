<?php
// Replaces GeoLite2-Country.mmdb with MaxMind's current edition. Run weekly by
// cron (store/geo.py --cron installs it): MaxMind's GeoLite2 licence requires a
// copy no more than 30 days behind their latest, and they publish twice a week.
//
// Downloads with the account id and licence key in maxmind.json beside this
// file (written by store/geo.py --config; a download-only key for a free
// database, so it may sit on the web host). Checks the archive against
// MaxMind's own SHA-256, opens the new database and looks up two known
// addresses before swapping it in by rename, so a bad download can never
// replace a good database. Writes the outcome to status.json for the dashboard.

if (PHP_SAPI !== 'cli' && !defined('WREN_GEO_UPDATE')) {
    http_response_code(404);
    exit;
}

function geo_update(): array
{
    $dir = __DIR__;
    $cfg = json_decode((string) @file_get_contents("$dir/maxmind.json"), true) ?: [];
    if (empty($cfg['account']) || empty($cfg['key'])) {
        return ['ok' => false, 'error' => 'no maxmind.json'];
    }
    $base = 'https://download.maxmind.com/geoip/databases/GeoLite2-Country/download?suffix=';
    $get = function (string $url) use ($cfg): string {
        $ch = curl_init($url);
        curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_FOLLOWLOCATION => true, CURLOPT_MAXREDIRS => 3,
            CURLOPT_USERPWD => $cfg['account'] . ':' . $cfg['key'], CURLOPT_TIMEOUT => 120,
            CURLOPT_USERAGENT => 'wren-geo-update/1', CURLOPT_UNRESTRICTED_AUTH => false]);
        $body = curl_exec($ch);
        $code = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        curl_close($ch);
        if ($body === false || $code !== 200) {
            throw new RuntimeException("download $code");
        }
        return $body;
    };
    $tmp = "$dir/tmp-" . bin2hex(random_bytes(4));
    try {
        $want = strtolower(substr(trim($get($base . 'tar.gz.sha256')), 0, 64));
        $tgz = $get($base . 'tar.gz');
        if (strlen($tgz) > 50_000_000 || hash('sha256', $tgz) !== $want) {
            throw new RuntimeException('checksum mismatch');
        }
        mkdir($tmp, 0700);
        file_put_contents("$tmp/db.tar.gz", $tgz);
        (new PharData("$tmp/db.tar.gz"))->decompress(); // -> db.tar
        $tar = new PharData("$tmp/db.tar");
        $found = null;
        foreach (new RecursiveIteratorIterator($tar) as $f) {
            if (str_ends_with($f->getFilename(), 'GeoLite2-Country.mmdb')) {
                $found = $f;
            }
        }
        if (!$found) {
            throw new RuntimeException('no mmdb in archive');
        }
        copy($found->getPathname(), "$tmp/new.mmdb");

        foreach (['Reader/InvalidDatabaseException', 'Reader/Util', 'Reader/Decoder', 'Reader/Metadata', 'Reader'] as $f) {
            require_once "$dir/MaxMind/Db/$f.php";
        }
        $r = new MaxMind\Db\Reader("$tmp/new.mmdb");
        $meta = $r->metadata();
        $us = $r->get('8.8.8.8')['country']['iso_code'] ?? '';
        $gb = $r->get('81.2.69.142')['country']['iso_code'] ?? ''; // MaxMind's own GB test address
        $r->close();
        if ($meta->databaseType !== 'GeoLite2-Country' || $us !== 'US' || $gb !== 'GB') {
            throw new RuntimeException("sanity check failed: {$meta->databaseType} $us $gb");
        }
        if (!rename("$tmp/new.mmdb", "$dir/GeoLite2-Country.mmdb")) {
            throw new RuntimeException('rename failed');
        }
        $out = ['ok' => true, 'updated' => gmdate('c'), 'built' => gmdate('c', $meta->buildEpoch)];
    } catch (Throwable $e) {
        $out = ['ok' => false, 'error' => substr($e->getMessage(), 0, 200), 'at' => gmdate('c')];
    } finally {
        foreach (glob("$tmp/*") ?: [] as $f) {
            @unlink($f);
        }
        @rmdir($tmp);
    }
    $prev = json_decode((string) @file_get_contents("$dir/status.json"), true) ?: [];
    file_put_contents("$dir/status.json", json_encode($out + ($out['ok'] ? [] : ['last_good' => $prev['built'] ?? $prev['last_good'] ?? null])));
    return $out;
}

if (PHP_SAPI === 'cli') {
    $r = geo_update();
    echo json_encode($r), "\n";
    exit($r['ok'] ? 0 : 1);
}
