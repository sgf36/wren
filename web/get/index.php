<?php
// wren.spencerfields.com/get/?c=<token> — one link for every phone.
//
// Why it exists (6 Oct 2026): TikTok Promote cannot target iPhones only, so an
// App Store link wasted every tap from an Android phone, and paid and organic
// traffic shared one token. This sends an iPhone or iPad to the App Store with
// ct=<token> (App Analytics attribution), an Android phone to Google Play with
// utm_campaign=<token> and utm_source/utm_medium from the registry, and anything
// else to the home page, which links both stores.
//
// Only tokens in tokens.json are accepted, generated from store/campaigns.json
// by store/get_redirect.py, so this can never be used to send someone elsewhere
// and a typo cannot mint an unregistered campaign. An unknown or missing token
// still redirects, untagged, rather than showing an error to a stranger.
//
// No cookie is set. The only thing kept is a daily tally per token and kind of
// device (added 8 Oct 2026), so a platform's click count can be compared with
// what the stores report: no IP address, no user agent, nothing per person.
// See tally() below; read it with `python store/get_redirect.py --counts`.

header('Cache-Control: no-store');
header('Referrer-Policy: no-referrer');

$APP_STORE = 'https://apps.apple.com/app/apple-store/id6802053382';
$PROVIDER = '129201947';
$PLAY = 'https://play.google.com/store/apps/details?id=com.spencerfields.littlebird';
$HOME = 'https://wren.spencerfields.com/';

$tokens = json_decode(@file_get_contents(__DIR__ . '/tokens.json'), true) ?: [];
$c = isset($_GET['c']) ? strtolower(trim((string) $_GET['c'])) : '';
$known = ($c !== '' && isset($tokens[$c])) ? $tokens[$c] : null;

$ua = $_SERVER['HTTP_USER_AGENT'] ?? '';
$isApple = (bool) preg_match('/iPhone|iPad|iPod/i', $ua);
// iPadOS presents itself as a Mac; a Mac with touch is an iPad, but a server
// cannot see touch, so a Mac goes to the home page, which links both stores.
$isAndroid = (bool) preg_match('/Android/i', $ua);

if ($isApple) {
    $to = $APP_STORE . '?pt=' . $PROVIDER . ($known ? '&ct=' . rawurlencode($c) : '') . '&mt=8';
} elseif ($isAndroid) {
    $to = $PLAY . ($known ? '&' . http_build_query([
        'utm_source' => $known['source'],
        'utm_medium' => $known['medium'],
        'utm_campaign' => $c,
    ]) : '');
} else {
    $to = $HOME;
}

tally($known ? $c : '(unknown)', $isApple ? 'iphone' : ($isAndroid ? 'android' : 'other'), $ua);
header('Location: ' . $to, true, 302);

// Adds one to today's tally in <home>/get-counts/YYYY-MM.json, outside the web
// root. Link checkers and ad reviewers (TikTok's included) are tallied as "bot"
// so they do not pass for people. Only registered tokens are stored, so a
// stranger's query string cannot grow the file. Any failure is swallowed: a
// missed count must never cost a redirect.
function tally(string $token, string $device, string $ua): void
{
    try {
        if (isset($_SERVER['HTTP_X_WREN_PROBE'])) {
            return; // get_redirect.py's own checks
        }
        if (preg_match('/bot|crawl|spider|preview|externalhit|curl|python|wget|headless|bytespider|tiktok-ads/i', $ua)) {
            $device = 'bot';
        }
        $dir = dirname($_SERVER['DOCUMENT_ROOT']) . '/get-counts';
        if (!is_dir($dir) && !@mkdir($dir, 0700, true)) {
            return;
        }
        $fh = @fopen($dir . '/' . gmdate('Y-m') . '.json', 'c+');
        if (!$fh || !flock($fh, LOCK_EX)) {
            return;
        }
        $data = json_decode(stream_get_contents($fh), true) ?: [];
        $day = gmdate('Y-m-d');
        $data[$day][$token][$device] = ($data[$day][$token][$device] ?? 0) + 1;
        ftruncate($fh, 0);
        rewind($fh);
        fwrite($fh, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
        fflush($fh);
        flock($fh, LOCK_UN);
        fclose($fh);
    } catch (Throwable $e) {
        // deliberately ignored
    }
}
