<?php
// Copies of winning install-validation postbacks, sent by Apple's devices
// because Wren's Info.plist names https://spencerfields.com as its
// NSAdvertisingAttributionReportEndpoint (SKAdNetwork) and
// AdAttributionKit/AttributionCopyEndpoint. Apple uses the registrable domain
// only, so these live in the apex site, at:
//   /.well-known/skadnetwork/report-attribution/
//   /.well-known/appattribution/report-attribution/
// (one copy of this file in each). Deployed by deploy.py beside this file.
//
// Why keep them: they are Apple-signed proof that ad attribution works,
// independent of Meta's reporting (decided 4 Oct 2026).
//
// Postbacks carry no user or device data (Apple's design), and this stores no
// IP address or header: only the time, which endpoint, and the JSON body.
// Files go OUTSIDE the web root, one per month, capped at 50 MB each.

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    header('Allow: POST');
    exit;
}

$body = file_get_contents('php://input', false, null, 0, 65536);
$postback = json_decode($body === false ? '' : $body, true);
if (!is_array($postback)) {
    http_response_code(400);
    exit;
}

$dir = dirname($_SERVER['DOCUMENT_ROOT']) . '/attribution-postbacks';
if (!is_dir($dir) && !@mkdir($dir, 0700, true)) {
    http_response_code(500);
    exit;
}
$file = $dir . '/' . gmdate('Y-m') . '.jsonl';
if (is_file($file) && filesize($file) > 50 * 1024 * 1024) {
    http_response_code(507);
    exit;
}

$kind = strpos($_SERVER['REQUEST_URI'], '/appattribution/') !== false ? 'adattributionkit' : 'skadnetwork';
$line = json_encode(
    ['received' => gmdate('c'), 'kind' => $kind, 'postback' => $postback],
    JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE
) . "\n";
if (file_put_contents($file, $line, FILE_APPEND | LOCK_EX) === false) {
    http_response_code(500);
    exit;
}

header('Content-Type: text/plain');
echo 'ok';
