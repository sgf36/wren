<?php
// Sign-in and sign-out for the dashboard.
//
// POST action=login: credential is the ID token Sign in with Google hands the
//   page. It is verified here, on the server, against Google's published keys;
//   the browser's word for who signed in is never taken.
// POST action=logout: ends the session.
//
// Both need the per-session CSRF token and a same-origin request.

define('WREN_DASH', true);
require __DIR__ . '/lib.php';

security_headers();
header('Content-Type: application/json; charset=utf-8');

function reply(int $code, array $body): void
{
    http_response_code($code);
    echo json_encode($body);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    reply(405, ['error' => 'POST only']);
}
if (($_SERVER['HTTP_ORIGIN'] ?? '') !== ORIGIN) {
    reply(403, ['error' => 'cross-origin request refused']);
}
start_session();
if (empty($_SESSION['csrf']) || !hash_equals($_SESSION['csrf'], (string) ($_POST['csrf'] ?? ''))) {
    reply(403, ['error' => 'page expired, reload it']);
}

$action = $_POST['action'] ?? '';
if ($action === 'logout') {
    $_SESSION = [];
    session_destroy();
    reply(200, ['ok' => true]);
}
if ($action !== 'login') {
    reply(400, ['error' => 'unknown action']);
}

// A handful of tries per session is plenty for a person; this is not a lock
// against forgery (the signature check is), only against a stuck loop.
$_SESSION['tries'] = ($_SESSION['tries'] ?? 0) + 1;
if ($_SESSION['tries'] > 10) {
    reply(429, ['error' => 'too many attempts, close the tab and try later']);
}

try {
    $email = verify_google_id_token((string) ($_POST['credential'] ?? ''), (string) ($_SESSION['nonce'] ?? ''));
} catch (Throwable $e) {
    log_event('refused ' . $e->getMessage());
    reply(403, ['error' => 'This Google account cannot open this page.']);
}

session_regenerate_id(true);
$_SESSION = ['email' => $email, 'until' => time() + SESSION_HOURS * 3600, 'csrf' => bin2hex(random_bytes(32))];
log_event('signed in ' . $email);
reply(200, ['ok' => true]);
