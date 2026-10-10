<?php
// wren.spencerfields.com/analytics: the private advert dashboard.
// Signed out, it shows Sign in with Google; signed in with an allowed account,
// it serves the dashboard shell and app.js fetches the figures from api.php.
// Not linked from anywhere, not in the sitemap, and noindex on every response,
// but none of that is the protection: the sign-in check is.

define('WREN_DASH', true);
require __DIR__ . '/lib.php';

security_headers();
header('Content-Type: text/html; charset=utf-8');
$email = signed_in();
$csrf = htmlspecialchars(csrf_token());
$v = '2026101014'; // bump when app.js / app.css change, to beat browser caches

if ($email) {
    header("Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        . "connect-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'");
    ?>
<!doctype html>
<html lang="en-GB">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="csrf" content="<?= $csrf ?>">
<title>Wren adverts</title>
<link rel="icon" href="/icon.svg">
<link rel="stylesheet" href="app.css?v=<?= $v ?>">
</head>
<body>
<header class="top">
  <div class="brand"><img src="/icon.svg" alt="" width="28" height="28"><h1>Wren adverts</h1></div>
  <div class="controls">
    <div class="range" role="group" aria-label="Date range">
      <button data-days="0">Real time</button><button data-days="1">Today</button><button data-days="7">7 days</button><button data-days="14">14 days</button><button data-days="30">30 days</button>
    </div>
    <button id="refresh" title="Fetch fresh figures, bypassing the cache">Refresh</button>
    <span id="updated" class="muted"></span>
    <span class="who muted"><?= htmlspecialchars($email) ?></span>
    <button id="logout">Sign out</button>
  </div>
</header>
<main id="app"><p class="muted">Loading…</p></main>
<div id="tip" role="tooltip" hidden></div>
<script src="app.js?v=<?= $v ?>"></script>
</body>
</html>
<?php
    exit;
}

$client = htmlspecialchars(config()['google_client_id'] ?? '');
$nonce = htmlspecialchars(login_nonce());
header("Content-Security-Policy: default-src 'none'; script-src 'self' https://accounts.google.com/gsi/client; "
    . "style-src 'self' https://accounts.google.com/gsi/style; frame-src https://accounts.google.com/gsi/; "
    . "connect-src 'self' https://accounts.google.com/gsi/; img-src 'self'; form-action 'none'; "
    . "frame-ancestors 'none'; base-uri 'none'");
// Sign in with Google's popup needs to talk back to this window.
header('Cross-Origin-Opener-Policy: same-origin-allow-popups');
?>
<!doctype html>
<html lang="en-GB">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="csrf" content="<?= $csrf ?>">
<title>Sign in</title>
<link rel="icon" href="/icon.svg">
<link rel="stylesheet" href="app.css?v=<?= $v ?>">
</head>
<body class="login">
<main class="card">
  <img src="/icon.svg" alt="" width="48" height="48">
  <h1>Private page</h1>
<?php if ($client === ''): ?>
  <p class="muted">Sign-in is not set up yet.</p>
<?php else: ?>
  <p class="muted">Sign in with an authorised Google account.</p>
  <div id="g_id_onload" data-client_id="<?= $client ?>" data-callback="wrenSignedIn" data-nonce="<?= $nonce ?>"
       data-auto_prompt="false" data-use_fedcm_for_button="true" data-itp_support="true"></div>
  <div class="g_id_signin" data-type="standard" data-theme="outline" data-size="large" data-text="signin_with" data-shape="pill"></div>
  <p id="error" class="error" role="alert"></p>
  <script src="login.js?v=<?= $v ?>"></script>
  <script src="https://accounts.google.com/gsi/client" async></script>
<?php endif; ?>
</main>
</body>
</html>
