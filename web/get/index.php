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
// Nothing is stored or logged here and no cookie is set.

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

header('Location: ' . $to, true, 302);
