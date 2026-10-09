<?php
// JSON for the dashboard. Signed-in callers only; everyone else gets a bare 401.

define('WREN_DASH', true);
require __DIR__ . '/lib.php';
require __DIR__ . '/sources.php';

security_headers();
header('Content-Type: application/json; charset=utf-8');

if (!signed_in()) {
    http_response_code(401);
    echo '{"error":"sign in"}';
    exit;
}
session_write_close(); // the fetches below are slow; don't hold the session lock

set_time_limit(60);
$days = (int) ($_GET['days'] ?? 14);
$days = in_array($days, [1, 7, 14, 30], true) ? $days : 14;
$until = gmdate('Y-m-d');
$since = gmdate('Y-m-d', time() - ($days - 1) * 86400);
$refresh = isset($_GET['refresh']);

// [cache key, seconds to keep, fetch]. Apple and Play publish once a day, so
// asking them more often than hourly only costs time.
$plan = [
    'meta' => [300, fn() => source_meta($since, $until)],
    'tiktok' => [300, fn() => source_tiktok($since, $until)],
    'apple' => [3600, fn() => source_apple($since, $until)],
    'play' => [3600, fn() => source_play($since, $until)],
    'ga4' => [900, fn() => source_ga4($since, $until)],
    'ga4_realtime' => [60, fn() => source_ga4_realtime()],
    'get' => [0, fn() => source_get_taps($since, $until)],
    'postbacks' => [0, fn() => source_postbacks($since, $until)],
];
$only = isset($_GET['source']) ? [(string) $_GET['source']] : array_keys($plan);

$out = ['generated' => gmdate('c'), 'since' => $since, 'until' => $until, 'days' => $days, 'sources' => []];
foreach ($only as $name) {
    if (!isset($plan[$name])) {
        continue;
    }
    [$ttl, $fetch] = $plan[$name];
    try {
        // A partial Apple load is not cached, so the next request carries on.
        $result = cached("src_{$name}_{$days}", $refresh ? 0 : $ttl, function () use ($fetch, $name) {
            $r = $fetch();
            if (!empty($r['partial'])) {
                throw new PartialResult($r);
            }
            return $r;
        });
        $out['sources'][$name] = ['ok' => true] + $result;
    } catch (PartialResult $p) {
        $out['sources'][$name] = ['ok' => true, 'fetched' => gmdate('c')] + $p->result;
    } catch (Throwable $e) {
        $out['sources'][$name] = ['ok' => false, 'error' => substr($e->getMessage(), 0, 300)];
    }
}
echo json_encode($out, JSON_UNESCAPED_SLASHES | JSON_PARTIAL_OUTPUT_ON_ERROR);
