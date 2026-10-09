<?php
// The dashboard's data sources. Each returns plain arrays for api.php and throws
// on failure; api.php turns a throw into an error panel for that source alone,
// so one broken API never blanks the page.
//
// Freshness differs by source, and the page says so rather than implying all of
// it is live:
//   Meta Insights      minutes (cached 5 min)
//   TikTok reporting   minutes (cached 5 min)
//   GA4 realtime       seconds (cached 1 min); GA4 daily: hours
//   /get/ taps         live, read from this server's own tally
//   SKAN postbacks     live once Apple sends them, which it delays 24-48 h+
//   App Store reports  daily, 1-2 days behind, small counts withheld by Apple
//   Play reports       daily, a few days behind

if (!defined('WREN_DASH')) {
    http_response_code(404);
    exit;
}

function days_between(string $since, string $until): array
{
    $out = [];
    for ($d = strtotime($since); $d <= strtotime($until); $d += 86400) {
        $out[] = gmdate('Y-m-d', $d);
    }
    return $out;
}

function num($v): float
{
    return is_numeric($v) ? (float) $v : 0.0;
}

// ---------------------------------------------------------------- Meta

const META_GRAPH = 'https://graph.facebook.com/v25.0';

function meta_get(string $path, array $params): array
{
    $cfg = config()['meta'];
    $params['access_token'] = $cfg['token'];
    $url = META_GRAPH . '/' . ltrim($path, '/') . '?' . http_build_query($params);
    $rows = [];
    while ($url) {
        $page = http_json('GET', $url);
        if (!isset($page['data'])) {
            return $page;
        }
        $rows = array_merge($rows, $page['data']);
        $url = $page['paging']['next'] ?? null;
        if (count($rows) > 5000) {
            break;
        }
    }
    return ['data' => $rows];
}

// Meta reports an install under several names at once (omni_, mobile_, app_);
// summing them would count each install two or three times, so take the first
// one present.
function meta_action(array $row, array $names): float
{
    $by = [];
    foreach ($row['actions'] ?? [] as $a) {
        $by[$a['action_type']] = num($a['value']);
    }
    foreach ($names as $n) {
        if (isset($by[$n])) {
            return $by[$n];
        }
    }
    return 0.0;
}

const META_INSTALL = ['omni_app_install', 'mobile_app_install', 'app_install'];
const META_PURCHASE = ['omni_purchase', 'app_custom_event.fb_mobile_purchase', 'purchase'];

function meta_metrics(array $r): array
{
    $installs = meta_action($r, META_INSTALL);
    $spend = num($r['spend'] ?? 0);
    return [
        'spend' => $spend,
        'impressions' => (int) num($r['impressions'] ?? 0),
        'reach' => (int) num($r['reach'] ?? 0),
        'link_clicks' => (int) num($r['inline_link_clicks'] ?? 0),
        'installs' => $installs,
        'purchases' => meta_action($r, META_PURCHASE),
        'cpi' => $installs > 0 ? round($spend / $installs, 2) : null,
        'ctr' => num($r['impressions'] ?? 0) > 0 ? round(100 * num($r['inline_link_clicks'] ?? 0) / num($r['impressions']), 2) : null,
    ];
}

function source_meta(string $since, string $until): array
{
    $cfg = config()['meta'] ?? null;
    if (empty($cfg['token']) || empty($cfg['ad_account'])) {
        return ['configured' => false];
    }
    $act = $cfg['ad_account'];
    $range = json_encode(['since' => $since, 'until' => $until]);
    $fields = 'spend,impressions,reach,inline_link_clicks,actions';

    $campaigns = meta_get("$act/campaigns", [
        'fields' => 'id,name,effective_status,objective,daily_budget,lifetime_budget,start_time,stop_time',
        'limit' => 200,
    ])['data'];
    $byCampaign = meta_get("$act/insights", [
        'level' => 'campaign', 'time_range' => $range, 'limit' => 500,
        'fields' => "campaign_id,campaign_name,$fields",
    ])['data'];
    $byAdset = meta_get("$act/insights", [
        'level' => 'adset', 'time_range' => $range, 'limit' => 500,
        'fields' => "adset_id,adset_name,campaign_id,campaign_name,$fields",
    ])['data'];
    $daily = meta_get("$act/insights", [
        'level' => 'account', 'time_range' => $range, 'time_increment' => 1, 'limit' => 500,
        'fields' => $fields,
    ])['data'];
    $countries = meta_get("$act/insights", [
        'level' => 'account', 'time_range' => $range, 'breakdowns' => 'country', 'limit' => 500,
        'fields' => $fields,
    ])['data'];
    $account = meta_get($act, ['fields' => 'currency,amount_spent,spend_cap,account_status,disable_reason']);
    // Campaigns that budget per ad set (Asia: one budget per market) carry no
    // campaign budget, so add up their running ad sets' budgets instead.
    $adsetBudgets = [];
    foreach (meta_get("$act/adsets", ['fields' => 'campaign_id,daily_budget,lifetime_budget,effective_status', 'limit' => 500])['data'] as $s) {
        if (in_array($s['effective_status'], ['ACTIVE', 'IN_PROCESS', 'WITH_ISSUES', 'PAUSED'], true)) {
            $type = num($s['lifetime_budget'] ?? 0) > 0 ? 'lifetime' : (num($s['daily_budget'] ?? 0) > 0 ? 'daily' : null);
            if ($type) {
                $adsetBudgets[$s['campaign_id']][$type] = ($adsetBudgets[$s['campaign_id']][$type] ?? 0)
                    + num($s[$type . '_budget']) / 100;
            }
        }
    }

    $stats = [];
    foreach ($byCampaign as $r) {
        $stats[$r['campaign_id']] = meta_metrics($r);
    }
    $rows = [];
    foreach ($campaigns as $c) {
        $budget = isset($c['lifetime_budget']) && $c['lifetime_budget'] > 0
            ? ['lifetime', num($c['lifetime_budget']) / 100]
            : (isset($c['daily_budget']) && $c['daily_budget'] > 0 ? ['daily', num($c['daily_budget']) / 100] : [null, null]);
        if ($budget[0] === null && isset($adsetBudgets[$c['id']])) {
            $t = isset($adsetBudgets[$c['id']]['lifetime']) ? 'lifetime' : 'daily';
            $budget = [$t . ' (ad sets)', $adsetBudgets[$c['id']][$t]];
        }
        $s = $stats[$c['id']] ?? null;
        if (!$s && !in_array($c['effective_status'], ['ACTIVE', 'IN_PROCESS', 'WITH_ISSUES'], true)) {
            continue; // nothing in range and not running: noise
        }
        $rows[] = ['id' => $c['id'], 'name' => $c['name'], 'status' => $c['effective_status'],
            'objective' => $c['objective'] ?? '', 'budget_type' => $budget[0], 'budget' => $budget[1],
            'start' => substr($c['start_time'] ?? '', 0, 10), 'stop' => substr($c['stop_time'] ?? '', 0, 10)]
            + ($s ?? meta_metrics([]));
    }
    usort($rows, fn($a, $b) => $b['spend'] <=> $a['spend']);

    $adsets = array_map(fn($r) => ['id' => $r['adset_id'], 'name' => $r['adset_name'],
        'campaign' => $r['campaign_name']] + meta_metrics($r), $byAdset);
    usort($adsets, fn($a, $b) => $b['spend'] <=> $a['spend']);

    $days = [];
    foreach ($daily as $r) {
        $days[$r['date_start']] = meta_metrics($r);
    }
    $country = array_map(fn($r) => ['country' => $r['country']] + meta_metrics($r), $countries);
    usort($country, fn($a, $b) => $b['spend'] <=> $a['spend']);

    return [
        'configured' => true,
        'currency' => $account['currency'] ?? 'GBP',
        'account_status' => $account['account_status'] ?? null,
        'campaigns' => $rows,
        'adsets' => $adsets,
        'daily' => $days,
        'countries' => $country,
    ];
}

// ---------------------------------------------------------------- TikTok

function tiktok_get(string $path, array $params): array
{
    $cfg = config()['tiktok'];
    foreach ($params as $k => $v) {
        if (is_array($v)) {
            $params[$k] = json_encode($v);
        }
    }
    $d = http_json('GET', 'https://business-api.tiktok.com/open_api/v1.3/' . $path . '?' . http_build_query($params),
        ['Access-Token: ' . $cfg['access_token']]);
    if (($d['code'] ?? -1) !== 0) {
        throw new RuntimeException('TikTok ' . ($d['code'] ?? '?') . ': ' . substr((string) ($d['message'] ?? ''), 0, 200));
    }
    return $d['data'] ?? [];
}

function source_tiktok(string $since, string $until): array
{
    $cfg = config()['tiktok'] ?? null;
    if (empty($cfg['access_token']) || empty($cfg['advertiser_id'])) {
        return ['configured' => false];
    }
    $adv = $cfg['advertiser_id'];
    $metrics = ['spend', 'impressions', 'clicks', 'reach', 'conversion', 'campaign_name'];
    $daily = tiktok_get('report/integrated/get/', [
        'advertiser_id' => $adv, 'report_type' => 'BASIC', 'data_level' => 'AUCTION_CAMPAIGN',
        'dimensions' => ['campaign_id', 'stat_time_day'], 'metrics' => $metrics,
        'start_date' => $since, 'end_date' => $until, 'page_size' => 1000,
    ])['list'] ?? [];
    // campaign/get/ belongs to the "Ads management" scope, which the reporting
    // app deliberately does not hold; without it the table has no status column
    // but every figure is still there.
    try {
        $campaigns = tiktok_get('campaign/get/', ['advertiser_id' => $adv, 'page_size' => 100])['list'] ?? [];
    } catch (Throwable $e) {
        $campaigns = [];
    }

    $byCampaign = [];
    $days = [];
    foreach ($daily as $r) {
        $id = $r['dimensions']['campaign_id'];
        $day = substr($r['dimensions']['stat_time_day'], 0, 10);
        $m = $r['metrics'];
        foreach (['spend', 'impressions', 'clicks', 'conversion'] as $k) {
            $byCampaign[$id][$k] = ($byCampaign[$id][$k] ?? 0) + num($m[$k] ?? 0);
            $days[$day][$k] = ($days[$day][$k] ?? 0) + num($m[$k] ?? 0);
        }
        $byCampaign[$id]['name'] = $m['campaign_name'] ?? $id;
    }
    $status = [];
    foreach ($campaigns as $c) {
        $status[$c['campaign_id']] = $c + ['_name' => $c['campaign_name'] ?? ''];
    }
    $rows = [];
    foreach ($status + array_fill_keys(array_keys($byCampaign), []) as $id => $c) {
        $s = $byCampaign[$id] ?? ['spend' => 0, 'impressions' => 0, 'clicks' => 0, 'conversion' => 0];
        if (!$s['spend'] && ($c['operation_status'] ?? '') !== 'ENABLE') {
            continue;
        }
        $rows[] = ['id' => (string) $id, 'name' => $c['_name'] ?? ($s['name'] ?? $id),
            'status' => $c['secondary_status'] ?? $c['operation_status'] ?? '',
            'objective' => $c['objective_type'] ?? '', 'budget' => isset($c['budget']) ? num($c['budget']) : null,
            'spend' => $s['spend'], 'impressions' => (int) $s['impressions'], 'clicks' => (int) $s['clicks'],
            'conversions' => $s['conversion'],
            'cpc' => $s['clicks'] > 0 ? round($s['spend'] / $s['clicks'], 3) : null];
    }
    usort($rows, fn($a, $b) => $b['spend'] <=> $a['spend']);
    ksort($days);
    return ['configured' => true, 'campaigns' => $rows, 'daily' => $days];
}

// ---------------------------------------------------------------- App Store Connect

function asc_token(): string
{
    $c = config()['asc'];
    $now = time();
    return jwt_sign(['alg' => 'ES256', 'kid' => $c['key_id'], 'typ' => 'JWT'],
        ['iss' => $c['issuer'], 'iat' => $now - 60, 'exp' => $now + 1140, 'aud' => 'appstoreconnect-v1'],
        $c['p8']);
}

function asc_get(string $url): array
{
    if (!str_starts_with($url, 'http')) {
        $url = 'https://api.appstoreconnect.apple.com' . $url;
    }
    return http_json('GET', $url, ['Authorization: Bearer ' . asc_token()]);
}

const ASC_REPORTS = [
    'App Downloads Standard', 'App Downloads Detailed',
    'App Store Discovery and Engagement Standard', 'App Store Discovery and Engagement Detailed',
    'App Store Purchases Standard',
];

// Downloads the daily report files Apple has produced since $since. A file never
// changes once published, so each one is cached for good under its instance id
// and only new ones are fetched. A first load can mean dozens of downloads, so it
// stops after a time budget and reports itself partial; the page asks again.
function asc_rows(string $since): array
{
    $c = config()['asc'];
    $reports = cached('asc_reports', 86400, function () use ($c) {
        $all = [];
        $url = '/v1/analyticsReportRequests/' . $c['request_id'] . '/reports?limit=200';
        while ($url) {
            $d = asc_get($url);
            foreach ($d['data'] as $r) {
                $all[$r['attributes']['name']] = $r['id'];
            }
            $url = $d['links']['next'] ?? null;
        }
        return ['ids' => $all];
    })['ids'];

    $started = microtime(true);
    $partial = false;
    $out = [];
    $latest = null;
    foreach (ASC_REPORTS as $name) {
        if (!isset($reports[$name])) {
            continue;
        }
        $instances = cached('asc_instances_' . $reports[$name], 3600, function () use ($reports, $name) {
            $list = [];
            $url = '/v1/analyticsReports/' . $reports[$name] . '/instances?filter[granularity]=DAILY&limit=200';
            while ($url) {
                $d = asc_get($url);
                foreach ($d['data'] as $i) {
                    $list[] = ['id' => $i['id'], 'date' => $i['attributes']['processingDate']];
                }
                $url = $d['links']['next'] ?? null;
            }
            return ['list' => $list];
        })['list'];

        $seen = [];
        $out[$name] = [];
        foreach ($instances as $inst) {
            // Rows dated in range can arrive in a file processed a few days later.
            if ($inst['date'] < gmdate('Y-m-d', strtotime($since) - 3 * 86400)) {
                continue;
            }
            $latest = max($latest ?? '', $inst['date']);
            $rows = cache_get('asc_rows_' . $inst['id']);
            if ($rows === null) {
                if (microtime(true) - $started > 18) {
                    $partial = true;
                    continue;
                }
                $rows = [];
                foreach (asc_get('/v1/analyticsReportInstances/' . $inst['id'] . '/segments')['data'] as $seg) {
                    [$code, $gz] = http('GET', $seg['attributes']['url'], [], null, 60);
                    if ($code !== 200) {
                        throw new RuntimeException("report segment HTTP $code");
                    }
                    $tsv = @gzdecode($gz);
                    $lines = explode("\n", trim($tsv === false ? $gz : $tsv));
                    $head = str_getcsv(array_shift($lines), "\t", '"', '');
                    foreach ($lines as $line) {
                        if ($line !== '') {
                            $rows[] = array_combine($head, array_pad(str_getcsv($line, "\t", '"', ''), count($head), ''));
                        }
                    }
                }
                cache_put('asc_rows_' . $inst['id'], $rows);
            }
            // Apple repeats identical rows within and across files.
            foreach ($rows as $r) {
                $k = md5(json_encode($r));
                if (!isset($seen[$k]) && ($r['Date'] ?? '') >= $since
                    && ($r['App Apple Identifier'] ?? APPLE_APP_ID) === APPLE_APP_ID) {
                    $seen[$k] = true;
                    $out[$name][] = $r;
                }
            }
        }
    }
    return [$out, $partial, $latest];
}

function bump(array &$a, string $key, string $field, float $n): void
{
    $a[$key][$field] = ($a[$key][$field] ?? 0) + $n;
}

function source_apple(string $since, string $until): array
{
    $c = config()['asc'] ?? null;
    if (empty($c['p8']) || empty($c['request_id'])) {
        return ['configured' => false];
    }
    [$reports, $partial, $processed] = asc_rows($since);

    $daily = [];
    $sources = [];
    $territories = [];
    $latest = null;
    foreach ($reports['App Downloads Standard'] ?? [] as $r) {
        $n = num($r['Counts']);
        $type = $r['Download Type'];
        $field = $type === 'First-time download' ? 'first' : ($type === 'Redownload' ? 'redownload' : 'updates');
        bump($daily, $r['Date'], $field, $n);
        $latest = max($latest ?? '', $r['Date']);
        if ($field !== 'updates') {
            bump($sources, $r['Source Type'], $field, $n);
            bump($territories, $r['Territory'], $field, $n);
        }
    }
    foreach ($reports['App Store Discovery and Engagement Standard'] ?? [] as $r) {
        $n = num($r['Unique Counts'] ?? $r['Counts']);
        if ($r['Event'] === 'Impression') {
            bump($daily, $r['Date'], 'impressions', $n);
            bump($territories, $r['Territory'], 'impressions', $n);
        } elseif ($r['Event'] === 'Page view') {
            bump($daily, $r['Date'], 'page_views', $n);
            bump($territories, $r['Territory'], 'page_views', $n);
            bump($sources, $r['Source Type'], 'page_views', $n);
        }
    }
    // Campaign tokens (ct=) and referring apps are only in the Detailed reports,
    // which Apple thins harder for privacy: their totals run below Standard's.
    $campaigns = [];
    $referrers = [];
    foreach ($reports['App Downloads Detailed'] ?? [] as $r) {
        $field = $r['Download Type'] === 'First-time download' ? 'first' : ($r['Download Type'] === 'Redownload' ? 'redownload' : null);
        if ($field) {
            bump($campaigns, $r['Campaign'] ?: '(none)', $field, num($r['Counts']));
            if ($r['Source Info'] !== '') {
                bump($referrers, $r['Source Info'], $field, num($r['Counts']));
            }
        }
    }
    foreach ($reports['App Store Discovery and Engagement Detailed'] ?? [] as $r) {
        if ($r['Event'] === 'Page view') {
            $n = num($r['Unique Counts'] ?? $r['Counts']);
            bump($campaigns, $r['Campaign'] ?: '(none)', 'page_views', $n);
            if ($r['Source Info'] !== '') {
                bump($referrers, $r['Source Info'], 'page_views', $n);
            }
        }
    }
    // The purchases report's columns are read by name pattern rather than a fixed
    // list, so a renamed column shows up as a new figure instead of a silent zero.
    $purchases = [];
    foreach ($reports['App Store Purchases Standard'] ?? [] as $r) {
        foreach ($r as $col => $v) {
            if (is_numeric($v) && preg_match('/purchase|proceeds|sales|units|refund/i', $col)) {
                bump($purchases, $r['Date'], $col, num($v));
            }
        }
    }
    ksort($daily);
    ksort($purchases);
    return ['configured' => true, 'partial' => $partial, 'latest_date' => $latest, 'processed' => $processed,
        'daily' => $daily, 'sources' => $sources, 'territories' => $territories,
        'campaigns' => $campaigns, 'referrers' => $referrers, 'purchases' => $purchases];
}

// ---------------------------------------------------------------- Google (GA4, Play)

function google_token(): string
{
    $sa = config()['google']['service_account'];
    $tok = cache_get('google_sa_token');
    if ($tok && $tok['until'] > time() + 60) {
        return $tok['token'];
    }
    $now = time();
    $jwt = jwt_sign(['alg' => 'RS256', 'typ' => 'JWT'], [
        'iss' => $sa['client_email'],
        'scope' => 'https://www.googleapis.com/auth/analytics.readonly https://www.googleapis.com/auth/devstorage.read_only',
        'aud' => 'https://oauth2.googleapis.com/token', 'iat' => $now, 'exp' => $now + 3600,
    ], $sa['private_key']);
    $d = http_json('POST', 'https://oauth2.googleapis.com/token', ['Content-Type: application/x-www-form-urlencoded'],
        http_build_query(['grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer', 'assertion' => $jwt]));
    cache_put('google_sa_token', ['token' => $d['access_token'], 'until' => $now + (int) $d['expires_in']]);
    return $d['access_token'];
}

function ga4(string $method, array $body): array
{
    $p = config()['google']['ga4_property'];
    return http_json('POST', "https://analyticsdata.googleapis.com/v1beta/properties/$p:$method",
        ['Authorization: Bearer ' . google_token(), 'Content-Type: application/json'], json_encode($body));
}

function ga4_rows(array $d): array
{
    $out = [];
    foreach ($d['rows'] ?? [] as $r) {
        $out[] = [array_map(fn($v) => $v['value'], $r['dimensionValues'] ?? []),
            array_map(fn($v) => num($v['value']), $r['metricValues'] ?? [])];
    }
    return $out;
}

function source_ga4(string $since, string $until): array
{
    $g = config()['google'] ?? null;
    if (empty($g['service_account']['private_key']) || empty($g['ga4_property'])) {
        return ['configured' => false];
    }
    $range = [['startDate' => $since, 'endDate' => $until]];
    $daily = [];
    foreach (ga4_rows(ga4('runReport', ['dateRanges' => $range, 'dimensions' => [['name' => 'date']],
        'metrics' => [['name' => 'sessions'], ['name' => 'activeUsers'], ['name' => 'screenPageViews']]])) as [$d, $m]) {
        $daily[substr($d[0], 0, 4) . '-' . substr($d[0], 4, 2) . '-' . substr($d[0], 6, 2)] =
            ['sessions' => $m[0], 'users' => $m[1], 'views' => $m[2]];
    }
    ksort($daily);
    $sources = array_map(fn($r) => ['source' => $r[0][0], 'medium' => $r[0][1], 'campaign' => $r[0][2],
        'sessions' => $r[1][0], 'users' => $r[1][1]],
        ga4_rows(ga4('runReport', ['dateRanges' => $range, 'limit' => 30,
            'dimensions' => [['name' => 'sessionSource'], ['name' => 'sessionMedium'], ['name' => 'sessionCampaignName']],
            'metrics' => [['name' => 'sessions'], ['name' => 'activeUsers']],
            'orderBys' => [['metric' => ['metricName' => 'sessions'], 'desc' => true]]])));
    $pages = array_map(fn($r) => ['page' => $r[0][0], 'views' => $r[1][0]],
        ga4_rows(ga4('runReport', ['dateRanges' => $range, 'limit' => 15,
            'dimensions' => [['name' => 'pagePath']], 'metrics' => [['name' => 'screenPageViews']],
            'orderBys' => [['metric' => ['metricName' => 'screenPageViews'], 'desc' => true]]])));
    return ['configured' => true, 'daily' => $daily, 'sources' => $sources, 'pages' => $pages];
}

function source_ga4_realtime(): array
{
    $g = config()['google'] ?? null;
    if (empty($g['service_account']['private_key']) || empty($g['ga4_property'])) {
        return ['configured' => false];
    }
    $rows = ga4_rows(ga4('runRealtimeReport', ['dimensions' => [['name' => 'country']],
        'metrics' => [['name' => 'activeUsers']]]));
    return ['configured' => true, 'active' => array_sum(array_map(fn($r) => $r[1][0], $rows)),
        'countries' => array_map(fn($r) => ['country' => $r[0][0], 'users' => $r[1][0]], $rows)];
}

// Play's reports are CSV files in a Cloud Storage bucket, UTF-16 encoded, one file
// per month per report. They are listed rather than named, so a report Google
// adds or renames shows up instead of 404ing.
function play_csv(string $bucket, string $name): array
{
    [$code, $raw] = http('GET', 'https://storage.googleapis.com/storage/v1/b/' . rawurlencode($bucket) . '/o/'
        . rawurlencode($name) . '?alt=media', ['Authorization: Bearer ' . google_token()], null, 40);
    if ($code !== 200) {
        throw new RuntimeException("Play report $name: HTTP $code");
    }
    if (str_starts_with($raw, "\xFF\xFE") || str_starts_with($raw, "\xFE\xFF")) {
        $raw = mb_convert_encoding($raw, 'UTF-8', 'UTF-16');
    }
    $raw = preg_replace('/^\xEF\xBB\xBF/', '', $raw);
    $lines = preg_split('/\r?\n/', trim($raw));
    $head = str_getcsv(array_shift($lines), ',', '"', '');
    $rows = [];
    foreach ($lines as $l) {
        if ($l !== '') {
            $rows[] = array_combine($head, array_pad(str_getcsv($l, ',', '"', ''), count($head), ''));
        }
    }
    return $rows;
}

function source_play(string $since, string $until): array
{
    $g = config()['google'] ?? null;
    if (empty($g['service_account']['private_key']) || empty($g['play_bucket'])) {
        return ['configured' => false];
    }
    $bucket = $g['play_bucket'];
    $months = array_unique(array_map(fn($d) => str_replace('-', '', substr($d, 0, 7)), days_between($since, $until)));
    $names = [];
    // stats/store_performance/ holds store-listing visitors and acquisitions by
    // traffic source with UTM tags: the only place Play attributes the /get/
    // links. It is published later than the install counts. (acquisition/ is
    // empty on this account; checked 9 Oct 2026.)
    foreach (['stats/installs/', 'stats/store_performance/'] as $prefix) {
        $d = http_json('GET', 'https://storage.googleapis.com/storage/v1/b/' . rawurlencode($bucket) . '/o?'
            . http_build_query(['prefix' => $prefix, 'maxResults' => 1000]), ['Authorization: Bearer ' . google_token()]);
        foreach ($d['items'] ?? [] as $o) {
            foreach ($months as $m) {
                if (str_contains($o['name'], PLAY_PACKAGE) && str_contains($o['name'], "_$m")) {
                    $names[] = $o['name'];
                }
            }
        }
    }
    $daily = [];
    $countries = [];
    $acquisition = [];
    $latest = null;
    foreach ($names as $name) {
        $rows = play_csv($bucket, $name);
        foreach ($rows as $r) {
            $date = $r['Date'] ?? '';
            if ($date < $since || $date > $until) {
                continue;
            }
            if (str_ends_with($name, '_overview.csv') && str_contains($name, 'installs_')) {
                $latest = max($latest ?? '', $date);
                $daily[$date] = ['installs' => num($r['Daily User Installs'] ?? $r['Install events'] ?? 0),
                    'uninstalls' => num($r['Daily User Uninstalls'] ?? $r['Uninstall events'] ?? 0),
                    'active' => num($r['Active Device Installs'] ?? 0)];
            } elseif (str_ends_with($name, '_country.csv') && str_contains($name, 'installs_')) {
                bump($countries, $r['Country'] ?? '?', 'installs', num($r['Daily User Installs'] ?? $r['Install events'] ?? 0));
            } elseif (str_ends_with($name, '_traffic_source.csv') && str_contains($name, 'store_performance_')) {
                $key = ($r['Traffic source'] ?? '?') . ' · ' . (($r['UTM source'] ?? '') ?: '–') . ' / ' . (($r['UTM campaign'] ?? '') ?: '–');
                bump($acquisition, $key, 'visitors', num($r['Store listing visitors'] ?? 0));
                bump($acquisition, $key, 'acquisitions', num($r['Store listing acquisitions'] ?? 0));
                $latestSource = max($latestSource ?? '', $date);
            }
        }
    }
    ksort($daily);
    return ['configured' => true, 'latest_date' => $latest, 'daily' => $daily, 'countries' => $countries,
        'sources' => $acquisition, 'sources_latest' => $latestSource ?? null, 'files' => count($names)];
}

// ---------------------------------------------------------------- this server's own files

function source_get_taps(string $since, string $until): array
{
    $dir = dirname(base_dir()) . '/get-counts';
    $daily = [];
    $tokens = [];
    foreach (array_unique(array_map(fn($d) => substr($d, 0, 7), days_between($since, $until))) as $month) {
        $data = json_decode((string) @file_get_contents("$dir/$month.json"), true) ?: [];
        foreach ($data as $day => $byToken) {
            if ($day < $since || $day > $until) {
                continue;
            }
            foreach ($byToken as $token => $byDevice) {
                foreach ($byDevice as $device => $n) {
                    bump($daily, $day, $device, $n);
                    bump($tokens, $token, $device, $n);
                }
            }
        }
    }
    ksort($daily);
    return ['configured' => true, 'daily' => $daily, 'tokens' => $tokens];
}

// Ad network ids Apple puts in SKAdNetwork postbacks. Meta's n38lu8286q is the
// one seen in a real postback (8 Oct 2026); the others are from the networks'
// published SKAdNetworkItems lists.
const SKAN_NETWORKS = [
    'n38lu8286q.skadnetwork' => 'Meta', 'v9wttpbfk9.skadnetwork' => 'Meta',
    '22mmun2rn5.skadnetwork' => 'TikTok', '238da6jt44.skadnetwork' => 'TikTok (Pangle)',
];

function source_postbacks(string $since, string $until): array
{
    $dir = dirname(base_dir()) . '/attribution-postbacks';
    $all = [];
    foreach (array_unique(array_map(fn($d) => substr($d, 0, 7), days_between($since, $until))) as $month) {
        foreach (@file("$dir/$month.jsonl", FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
            $row = json_decode($line, true);
            $day = substr($row['received'] ?? '', 0, 10);
            if ($row && $day >= $since && $day <= $until) {
                $p = $row['postback'] ?? [];
                if (empty($p['ad-network-id'])) {
                    continue; // not from Apple: the deploy script's own test posts
                }
                $net = strtolower((string) $p['ad-network-id']);
                $all[] = ['received' => $row['received'], 'kind' => $row['kind'] ?? '',
                    'network' => SKAN_NETWORKS[$net] ?? SKAN_NETWORKS[$net . '.skadnetwork'] ?? $net,
                    'won' => ($p['did-win'] ?? null), 'version' => $p['version'] ?? '',
                    'source' => (string) ($p['source-identifier'] ?? $p['campaign-id'] ?? ''),
                    'conversion' => $p['conversion-value'] ?? $p['coarse-conversion-value'] ?? null,
                    'sequence' => $p['postback-sequence-index'] ?? null, 'redownload' => $p['redownload'] ?? null,
                    'fidelity' => $p['fidelity-type'] ?? null];
            }
        }
    }
    usort($all, fn($a, $b) => strcmp($b['received'], $a['received']));
    $daily = [];
    foreach ($all as $p) {
        if ($p['won'] !== false) {
            bump($daily, substr($p['received'], 0, 10), $p['network'], 1);
        }
    }
    ksort($daily);
    return ['configured' => true, 'postbacks' => array_slice($all, 0, 100), 'count' => count($all), 'daily' => $daily];
}
