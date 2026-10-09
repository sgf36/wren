<?php
// Shared code for wren.spencerfields.com/analytics, the private advert dashboard.
//
// Nothing secret lives in this repository, which is public. Credentials and every
// figure stay on the server, outside the web root, in <home>/wren-analytics/:
//   config.json   written by `python store/analytics_dashboard.py --config`
//   cache/        API responses, so a page load does not hit every API
//   sessions/     PHP sessions for this page only, away from the shared /tmp
//
// The keys in config.json are deliberately READ-ONLY ones made for this page
// (Meta ads_read, App Store Connect "Sales and Reports", a Google service account
// that can only read GA4 and Play's report bucket). The WordPress site at the apex
// runs as the same cPanel user and can read this directory, so nothing here must
// be able to spend money or change an app if it leaks.

if (!defined('WREN_DASH')) {
    http_response_code(404);
    exit;
}

const ORIGIN = 'https://wren.spencerfields.com';
const SESSION_HOURS = 12;
const APPLE_APP_ID = '6802053382';
const PLAY_PACKAGE = 'com.spencerfields.littlebird';

function base_dir(): string
{
    return getenv('WREN_DASH_BASE') ?: dirname($_SERVER['DOCUMENT_ROOT']) . '/wren-analytics';
}

function config(): array
{
    static $config = null;
    if ($config === null) {
        $config = json_decode((string) @file_get_contents(base_dir() . '/config.json'), true) ?: [];
    }
    return $config;
}

function private_dir(string $name): string
{
    $dir = base_dir() . '/' . $name;
    if (!is_dir($dir)) {
        @mkdir($dir, 0700, true);
    }
    return $dir;
}

function security_headers(): void
{
    header('Cache-Control: no-store');
    header('X-Robots-Tag: noindex, nofollow');
    header('X-Content-Type-Options: nosniff');
    header('Referrer-Policy: no-referrer');
    header('X-Frame-Options: DENY');
}

// ---------------------------------------------------------------- sessions

function start_session(): void
{
    if (session_status() === PHP_SESSION_ACTIVE) {
        return;
    }
    ini_set('session.use_strict_mode', '1');
    ini_set('session.use_only_cookies', '1');
    ini_set('session.gc_maxlifetime', (string) (SESSION_HOURS * 3600));
    session_save_path(private_dir('sessions'));
    // __Host- forces Secure, path=/ and no Domain, so no other subdomain of
    // spencerfields.com can set or read it.
    session_name('__Host-wren_dash');
    session_set_cookie_params([
        'lifetime' => 0,
        'path' => '/',
        'secure' => true,
        'httponly' => true,
        'samesite' => 'Strict',
    ]);
    session_start();
}

function signed_in(): ?string
{
    start_session();
    $email = $_SESSION['email'] ?? null;
    if (!$email || ($_SESSION['until'] ?? 0) < time()) {
        return null;
    }
    // Re-checked on every request, so taking an address off the list in
    // config.json ends a session that is already open.
    return in_array($email, allowed_emails(), true) ? $email : null;
}

function allowed_emails(): array
{
    return array_map('strtolower', config()['allowed_emails'] ?? []);
}

function csrf_token(): string
{
    start_session();
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf'];
}

function login_nonce(): string
{
    start_session();
    if (empty($_SESSION['nonce'])) {
        $_SESSION['nonce'] = bin2hex(random_bytes(16));
    }
    return $_SESSION['nonce'];
}

// ---------------------------------------------------------------- HTTP

function http(string $method, string $url, array $headers = [], ?string $body = null, int $timeout = 25): array
{
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_MAXREDIRS => 3,
        CURLOPT_CONNECTTIMEOUT => 10,
        CURLOPT_TIMEOUT => $timeout,
        CURLOPT_HTTPHEADER => array_merge(['User-Agent: wren-analytics/1.0'], $headers),
        CURLOPT_ENCODING => '',
    ]);
    if ($body !== null) {
        curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
    }
    $out = curl_exec($ch);
    $code = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    $err = curl_error($ch);
    curl_close($ch);
    if ($out === false) {
        throw new RuntimeException('network: ' . $err);
    }
    return [$code, $out];
}

function http_json(string $method, string $url, array $headers = [], ?string $body = null): array
{
    [$code, $out] = http($method, $url, $headers, $body);
    $data = json_decode($out, true);
    if ($code >= 400 || !is_array($data)) {
        throw new RuntimeException("HTTP $code: " . api_message($data, $out));
    }
    return $data;
}

// Pulls the human-readable part out of the error shapes these APIs use, and
// never more than 200 characters of it.
function api_message($data, string $raw): string
{
    $m = $data['error']['message'] ?? $data['errors'][0]['detail'] ?? $data['message']
        ?? $data['error_description'] ?? $data['error'] ?? $raw;
    return substr(is_string($m) ? $m : json_encode($m), 0, 200);
}

// ---------------------------------------------------------------- cache

// Returns the cached value when it is younger than $ttl seconds, otherwise calls
// $fetch and stores the result. A failed fetch falls back to the last good copy
// and says so, because a stale figure with its age shown is more use than none.
function cached(string $key, int $ttl, callable $fetch): array
{
    $file = private_dir('cache') . '/' . preg_replace('/[^a-z0-9_.-]/i', '_', $key) . '.json';
    $old = json_decode((string) @file_get_contents($file), true);
    // Anything cached before config.json last changed may be a "not configured"
    // answer, so a new key shows up on the next load rather than minutes later.
    $fresh = $old && $old['t'] >= (int) @filemtime(base_dir() . '/config.json');
    if ($fresh && $ttl > 0 && time() - $old['t'] < $ttl) {
        return $old['v'] + ['fetched' => gmdate('c', $old['t'])];
    }
    try {
        $value = $fetch();
        @file_put_contents($file, json_encode(['t' => time(), 'v' => $value]), LOCK_EX);
        return $value + ['fetched' => gmdate('c')];
    } catch (Throwable $e) {
        if ($old && !($e instanceof PartialResult)) {
            return $old['v'] + ['fetched' => gmdate('c', $old['t']), 'stale' => $e->getMessage()];
        }
        throw $e;
    }
}

// Thrown by a fetch that got only part of its data in the time allowed. It
// carries what was fetched and is never cached, so the next request continues.
class PartialResult extends Exception
{
    public array $result;

    public function __construct(array $result)
    {
        parent::__construct('partial');
        $this->result = $result;
    }
}

function cache_get(string $key)
{
    $v = json_decode((string) @file_get_contents(private_dir('cache') . '/' . $key . '.json'), true);
    return $v['v'] ?? null;
}

function cache_put(string $key, $value): void
{
    @file_put_contents(private_dir('cache') . '/' . $key . '.json', json_encode(['t' => time(), 'v' => $value]), LOCK_EX);
}

// ---------------------------------------------------------------- crypto

function b64url_encode(string $s): string
{
    return rtrim(strtr(base64_encode($s), '+/', '-_'), '=');
}

function b64url_decode(string $s): string
{
    return (string) base64_decode(strtr($s, '-_', '+/') . str_repeat('=', (4 - strlen($s) % 4) % 4));
}

function der_length(int $n): string
{
    if ($n < 128) {
        return chr($n);
    }
    $s = ltrim(pack('N', $n), "\0");
    return chr(0x80 | strlen($s)) . $s;
}

function der_int(string $bytes): string
{
    $bytes = ltrim($bytes, "\0");
    if ($bytes === '' || ord($bytes[0]) > 0x7f) {
        $bytes = "\0" . $bytes;
    }
    return "\x02" . der_length(strlen($bytes)) . $bytes;
}

function der_seq(string $body): string
{
    return "\x30" . der_length(strlen($body)) . $body;
}

// Google publishes its signing keys as JWKs (modulus and exponent); OpenSSL wants
// a PEM SubjectPublicKeyInfo, so this assembles one.
function jwk_to_pem(array $jwk): string
{
    $rsa = der_seq(der_int(b64url_decode($jwk['n'])) . der_int(b64url_decode($jwk['e'])));
    $alg = der_seq("\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01\x05\x00");
    $spki = der_seq($alg . "\x03" . der_length(strlen($rsa) + 1) . "\0" . $rsa);
    return "-----BEGIN PUBLIC KEY-----\n" . chunk_split(base64_encode($spki), 64, "\n") . "-----END PUBLIC KEY-----\n";
}

// OpenSSL signs ECDSA as DER; a JWT's ES256 signature is r and s, 32 bytes each.
function ecdsa_der_to_raw(string $der): string
{
    $pos = 2;
    if (ord($der[1]) & 0x80) {
        $pos += ord($der[1]) & 0x7f;
    }
    $out = '';
    for ($i = 0; $i < 2; $i++) {
        $len = ord($der[$pos + 1]);
        $int = ltrim(substr($der, $pos + 2, $len), "\0");
        $out .= str_pad($int, 32, "\0", STR_PAD_LEFT);
        $pos += 2 + $len;
    }
    return $out;
}

function jwt_sign(array $header, array $claims, string $pem): string
{
    $input = b64url_encode(json_encode($header)) . '.' . b64url_encode(json_encode($claims));
    $key = openssl_pkey_get_private($pem);
    if (!$key || !openssl_sign($input, $sig, $key, OPENSSL_ALGO_SHA256)) {
        throw new RuntimeException('could not sign with the configured key');
    }
    if ($header['alg'] === 'ES256') {
        $sig = ecdsa_der_to_raw($sig);
    }
    return $input . '.' . b64url_encode($sig);
}

// ---------------------------------------------------------------- Google sign-in

function google_keys(bool $refresh = false): array
{
    $keys = $refresh ? null : cache_get('google_jwks');
    if (!$keys) {
        $keys = http_json('GET', 'https://www.googleapis.com/oauth2/v3/certs')['keys'] ?? [];
        cache_put('google_jwks', $keys);
    }
    return $keys;
}

// Verifies a Google ID token from Sign in with Google. Returns the e-mail address
// when the token is genuine, meant for this page's client id, current, carries the
// nonce this browser was given, and belongs to an allowed, verified address.
// Otherwise throws with the reason (logged, never shown in detail).
function verify_google_id_token(string $jwt, string $nonce): string
{
    $parts = explode('.', $jwt);
    if (count($parts) !== 3) {
        throw new RuntimeException('malformed token');
    }
    $header = json_decode(b64url_decode($parts[0]), true);
    $claims = json_decode(b64url_decode($parts[1]), true);
    if (($header['alg'] ?? '') !== 'RS256' || empty($header['kid']) || !is_array($claims)) {
        throw new RuntimeException('unexpected token header');
    }
    $find = function (array $keys) use ($header) {
        foreach ($keys as $k) {
            if (($k['kid'] ?? '') === $header['kid']) {
                return $k;
            }
        }
        return null;
    };
    // Google rotates keys; an unknown kid means our cached copy is old.
    $jwk = $find(google_keys()) ?? $find(google_keys(true));
    if (!$jwk) {
        throw new RuntimeException('unknown signing key');
    }
    $ok = openssl_verify($parts[0] . '.' . $parts[1], b64url_decode($parts[2]), jwk_to_pem($jwk), OPENSSL_ALGO_SHA256);
    if ($ok !== 1) {
        throw new RuntimeException('bad signature');
    }
    $now = time();
    $client = config()['google_client_id'] ?? '';
    if ($client === '' || ($claims['aud'] ?? '') !== $client) {
        throw new RuntimeException('token is for another client');
    }
    if (!in_array($claims['iss'] ?? '', ['accounts.google.com', 'https://accounts.google.com'], true)) {
        throw new RuntimeException('wrong issuer');
    }
    if (($claims['exp'] ?? 0) < $now - 60 || ($claims['iat'] ?? 0) > $now + 300) {
        throw new RuntimeException('token expired');
    }
    if (!hash_equals($nonce, (string) ($claims['nonce'] ?? ''))) {
        throw new RuntimeException('nonce mismatch');
    }
    $email = strtolower((string) ($claims['email'] ?? ''));
    if (($claims['email_verified'] ?? false) !== true || !in_array($email, allowed_emails(), true)) {
        throw new RuntimeException('account not allowed: ' . $email);
    }
    return $email;
}

function log_event(string $line): void
{
    @file_put_contents(private_dir('logs') . '/auth-' . gmdate('Y-m') . '.log', gmdate('c') . ' ' . $line . "\n", FILE_APPEND | LOCK_EX);
}
