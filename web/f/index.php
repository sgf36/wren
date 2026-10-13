<?php
// wren.spencerfields.com/f/ — anonymous counts of the steps between installing
// Wren and buying an unlock (lib/src/funnel.dart sends them).
//
// Why (9 Oct 2026): Wren had downloads and no purchases, and nothing said where
// people stopped. Each POST adds one to a daily tally per step, detail,
// platform, version and language. That tally is all that is kept: not the
// request, not the IP address, not the user agent, nothing per person. The
// private dashboard at /analytics reads it.
//
// Anything not on the lists below is dropped, so a stranger posting rubbish
// cannot add rows; at worst they can inflate a count, which a daily cap per
// row bounds. Always answers 204 and never says why a post was dropped: there
// is nothing here worth probing.

header('Cache-Control: no-store');
header('X-Robots-Tag: noindex, nofollow');

const STEPS = [
    'first_open' => [],
    'import_started' => ['screenshots', 'file', 'guide', 'reel'],
    'reel_read' => ['free', 'paid'],
    'paywall_shown' => ['places', 'combine', 'reels'],
    'buy_tapped' => ['unlimited', 'everything', 'reels_upgrade'],
    'purchased' => ['unlimited', 'everything', 'reels_upgrade'],
    'purchase_failed' => ['unlimited', 'everything', 'reels_upgrade'],
    'restore_tapped' => [],
    'saved_free_instead' => [],
    'paywall_dismissed' => [],
    'guide_saved' => [],
];
const PLATFORMS = ['ios', 'android'];
const DAILY_CAP = 5000; // per row per day; far above real use, far below abuse

http_response_code(204);
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    exit;
}
$in = json_decode((string) file_get_contents('php://input', false, null, 0, 2048), true);
if (!is_array($in)) {
    exit;
}
$step = (string) ($in['e'] ?? '');
$detail = (string) ($in['d'] ?? '');
$platform = (string) ($in['p'] ?? '');
$version = (string) ($in['v'] ?? '');
$lang = strtolower((string) ($in['l'] ?? ''));

if (!array_key_exists($step, STEPS) || !in_array($platform, PLATFORMS, true)) {
    exit;
}
$allowed = STEPS[$step];
if ($allowed ? !in_array($detail, $allowed, true) : $detail !== '') {
    exit;
}
if (!preg_match('/^\d{1,2}\.\d{1,2}\.\d{1,3}$/', $version)) {
    exit;
}
if (!preg_match('/^[a-z]{2,3}$/', $lang)) {
    $lang = 'other';
}

try {
    $dir = dirname($_SERVER['DOCUMENT_ROOT']) . '/funnel-counts';
    if (!is_dir($dir) && !@mkdir($dir, 0700, true)) {
        exit;
    }
    $fh = @fopen($dir . '/' . gmdate('Y-m') . '.json', 'c+');
    if (!$fh || !flock($fh, LOCK_EX)) {
        exit;
    }
    $data = json_decode(stream_get_contents($fh), true) ?: [];
    $key = implode('|', [$step, $detail, $platform, $version, $lang]);
    $day = gmdate('Y-m-d');
    $n = $data[$day][$key] ?? 0;
    if ($n < DAILY_CAP) {
        $data[$day][$key] = $n + 1;
        ftruncate($fh, 0);
        rewind($fh);
        fwrite($fh, json_encode($data));
        fflush($fh);
    }
    flock($fh, LOCK_UN);
    fclose($fh);
} catch (Throwable $e) {
    // A lost count must never turn into an error the app sees.
}
