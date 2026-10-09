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

// Purchase VALUE is in action_values (account currency), the count in actions.
function meta_value(array $row, array $names): float
{
    return meta_action(['actions' => $row['action_values'] ?? []], $names);
}

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
        'revenue' => meta_value($r, META_PURCHASE),
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
    $fields = 'spend,impressions,reach,inline_link_clicks,actions,action_values';

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

// TikTok reports days in the ad account's time zone (London), so "today" is
// compared in that zone too.
function tiktok_delivery(?string $lastDay): string
{
    $today = (new DateTime('now', new DateTimeZone('Europe/London')))->format('Y-m-d');
    $yesterday = (new DateTime('yesterday', new DateTimeZone('Europe/London')))->format('Y-m-d');
    return $lastDay === $today ? 'DELIVERING_NOW' : ($lastDay === $yesterday ? 'DELIVERED_YESTERDAY' : 'NO_RECENT_DELIVERY');
}

function source_tiktok(string $since, string $until): array
{
    $cfg = config()['tiktok'] ?? null;
    if (empty($cfg['access_token']) || empty($cfg['advertiser_id'])) {
        return ['configured' => false];
    }
    $adv = $cfg['advertiser_id'];
    // purchase / total_purchase_value / app_install are TikTok's app-event metrics
    // (from its SDK in Wren 2.1.8+); names checked against the API on 9 Oct 2026.
    $metrics = ['spend', 'impressions', 'clicks', 'reach', 'conversion', 'app_install', 'purchase', 'total_purchase_value', 'campaign_name'];
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
        foreach (['spend', 'impressions', 'clicks', 'conversion', 'app_install', 'purchase', 'total_purchase_value'] as $k) {
            $byCampaign[$id][$k] = ($byCampaign[$id][$k] ?? 0) + num($m[$k] ?? 0);
            $days[$day][$k] = ($days[$day][$k] ?? 0) + num($m[$k] ?? 0);
        }
        $byCampaign[$id]['name'] = $m['campaign_name'] ?? $id;
        if (num($m['impressions'] ?? 0) > 0) {
            $byCampaign[$id]['last_delivery'] = max($byCampaign[$id]['last_delivery'] ?? '', $day);
        }
    }
    $status = [];
    foreach ($campaigns as $c) {
        $status[$c['campaign_id']] = $c + ['_name' => $c['campaign_name'] ?? ''];
    }
    $rows = [];
    foreach ($status + array_fill_keys(array_keys($byCampaign), []) as $id => $c) {
        $s = $byCampaign[$id] ?? ['spend' => 0, 'impressions' => 0, 'clicks' => 0, 'conversion' => 0];
        $s += ['app_install' => 0, 'purchase' => 0, 'total_purchase_value' => 0];
        if (!$s['spend'] && ($c['operation_status'] ?? '') !== 'ENABLE') {
            continue;
        }
        $rows[] = ['id' => (string) $id, 'name' => $c['_name'] ?? ($s['name'] ?? $id),
            // The real on/off status needs the Ads management scope, which this
            // read-only token deliberately lacks; delivery is inferred instead.
            'status' => $c['secondary_status'] ?? $c['operation_status'] ?? tiktok_delivery($s['last_delivery'] ?? null),
            'status_inferred' => !isset($c['secondary_status']) && !isset($c['operation_status']),
            'objective' => $c['objective_type'] ?? '', 'budget' => isset($c['budget']) ? num($c['budget']) : null,
            'spend' => $s['spend'], 'impressions' => (int) $s['impressions'], 'clicks' => (int) $s['clicks'],
            'conversions' => $s['conversion'], 'installs' => $s['app_install'] ?? 0,
            'purchases' => $s['purchase'] ?? 0, 'revenue' => $s['total_purchase_value'] ?? 0,
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
    'App Store Purchases Standard', 'App Store Purchases Detailed',
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
    // Same, by campaign token: the only place Apple ties a purchase to a ct=
    // campaign. Counts only people who share analytics with developers.
    $purchaseCampaigns = [];
    foreach ($reports['App Store Purchases Detailed'] ?? [] as $r) {
        foreach ($r as $col => $v) {
            if (is_numeric($v) && preg_match('/purchase|proceeds|sales|units|refund/i', $col)) {
                bump($purchaseCampaigns, ($r['Campaign'] ?? '') ?: '(none)', $col, num($v));
            }
        }
    }
    ksort($daily);
    ksort($purchases);
    return ['configured' => true, 'partial' => $partial, 'latest_date' => $latest, 'processed' => $processed,
        'daily' => $daily, 'sources' => $sources, 'territories' => $territories,
        'campaigns' => $campaigns, 'referrers' => $referrers, 'purchases' => $purchases,
        'purchase_campaigns' => $purchaseCampaigns];
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

// ---------------------------------------------------------------- in-app purchases and revenue

// Rough pounds for amounts Apple and Google report in many currencies. Labelled
// "≈" on the page: the stores pay out at their own rates, later.
function fx_to_gbp(float $amount, string $currency): ?float
{
    if ($amount == 0.0 || strtoupper($currency) === 'GBP') {
        return $amount;
    }
    $rates = cached('fx_gbp', 43200, fn() => ['rates' => http_json('GET', 'https://open.er-api.com/v6/latest/GBP')['rates'] ?? []])['rates'];
    $r = $rates[strtoupper($currency)] ?? null;
    return $r ? $amount / $r : null;
}

// Apple product type ids: what a sales-report line is.
function apple_line_kind(string $type): string
{
    if (preg_match('/^(IA|FI)/', $type)) {
        return 'iap';
    }
    if (preg_match('/^(1|F1)/', $type)) {
        return 'download';
    }
    if (preg_match('/^(3|F3)/', $type)) {
        return 'redownload';
    }
    return preg_match('/^(7|F7)/', $type) ? 'update' : 'other';
}

// Apple's daily Sales report: every unit and every in-app purchase, including the
// people Apple Analytics leaves out because they do not share analytics. Covers
// all the account's apps; Wren's own lines carry its Apple id, its in-app
// purchases carry its SKU as Parent Identifier. No campaign column exists here.
function source_sales(string $since, string $until): array
{
    $c = config()['asc'] ?? null;
    if (empty($c['p8']) || empty($c['vendor_number'])) {
        return ['configured' => false];
    }
    $sku = cached('asc_wren_sku', 86400 * 7, fn() => ['sku' => asc_get('/v1/apps/' . APPLE_APP_ID . '?fields[apps]=sku')['data']['attributes']['sku']])['sku'];
    $started = microtime(true);
    $partial = false;
    $daily = [];
    $products = [];
    $countries = [];
    $latest = null;
    $unconverted = [];
    $yesterday = gmdate('Y-m-d', time() - 86400);
    foreach (array_reverse(days_between($since, min($until, $yesterday))) as $day) {
        $rows = cache_get('asc_sales_' . $day);
        if ($rows === null) {
            if (microtime(true) - $started > 15) {
                $partial = true;
                continue;
            }
            [$code, $body] = http('GET', 'https://api.appstoreconnect.apple.com/v1/salesReports?' . http_build_query([
                'filter[frequency]' => 'DAILY', 'filter[reportType]' => 'SALES', 'filter[reportSubType]' => 'SUMMARY',
                'filter[vendorNumber]' => $c['vendor_number'], 'filter[reportDate]' => $day, 'filter[version]' => '1_1',
            ]), ['Authorization: Bearer ' . asc_token(), 'Accept: application/a-gzip'], null, 40);
            if ($code === 404) {
                // "no sales for the date" and "not published yet" both answer 404.
                // Only a day well past is safe to record as empty.
                if ($day < gmdate('Y-m-d', time() - 3 * 86400)) {
                    cache_put('asc_sales_' . $day, []);
                }
                continue;
            }
            if ($code !== 200) {
                throw new RuntimeException("sales report $day: HTTP $code " . api_message(json_decode($body, true), ''));
            }
            $tsv = @gzdecode($body);
            $lines = explode("\n", trim($tsv === false ? $body : $tsv));
            $head = str_getcsv(array_shift($lines), "\t", '"', '');
            $rows = [];
            foreach ($lines as $line) {
                if ($line === '') {
                    continue;
                }
                $r = array_combine($head, array_pad(str_getcsv($line, "\t", '"', ''), count($head), ''));
                if (($r['Apple Identifier'] ?? '') !== APPLE_APP_ID && ($r['Parent Identifier'] ?? '') !== $sku) {
                    continue; // another of the account's apps
                }
                // Keep only what the page needs; never buyer-level detail.
                $rows[] = ['type' => $r['Product Type Identifier'], 'sku' => $r['SKU'], 'title' => $r['Title'],
                    'units' => num($r['Units']), 'proceeds' => num($r['Developer Proceeds']),
                    'currency' => $r['Currency of Proceeds'], 'country' => $r['Country Code']];
            }
            cache_put('asc_sales_' . $day, $rows);
        }
        if ($rows) {
            $latest = max($latest ?? '', $day);
        }
        $daily[$day] = $daily[$day] ?? [];
        foreach ($rows as $r) {
            $kind = apple_line_kind($r['type']);
            if ($kind === 'iap') {
                $gbp = fx_to_gbp($r['proceeds'] * $r['units'], $r['currency']);
                if ($gbp === null) {
                    $unconverted[$r['currency']] = true;
                    $gbp = 0.0;
                }
                $field = $r['units'] < 0 ? 'refunds' : 'purchases';
                $key = $r['sku'] . ' · ' . $r['title'];
                bump($daily, $day, $field, abs($r['units']));
                bump($daily, $day, 'proceeds', $gbp);
                bump($products, $key, $field, abs($r['units']));
                bump($products, $key, 'proceeds', $gbp);
                bump($countries, $r['country'], $field, abs($r['units']));
                bump($countries, $r['country'], 'proceeds', $gbp);
            } elseif ($kind !== 'other') {
                bump($daily, $day, $kind . 's', $r['units']);
                if ($kind === 'download') {
                    bump($countries, $r['country'], 'downloads', $r['units']);
                }
            }
        }
    }
    ksort($daily);
    return ['configured' => true, 'partial' => $partial, 'latest_date' => $latest, 'daily' => $daily,
        'products' => $products, 'countries' => $countries, 'unconverted' => array_keys($unconverted)];
}

// Google Play's monthly sales report (a zip in the same bucket, refreshed daily):
// one line per order. Needs the "View financial data" permission in Play Console,
// which the bulk-reports permission alone does not give. Aggregated here; the
// buyer-level lines (city, postcode) are never stored.
function source_play_sales(string $since, string $until): array
{
    $g = config()['google'] ?? null;
    if (empty($g['service_account']['private_key']) || empty($g['play_bucket'])) {
        return ['configured' => false];
    }
    if (!class_exists('ZipArchive')) {
        throw new RuntimeException('PHP on this host has no ZipArchive');
    }
    $bucket = $g['play_bucket'];
    $daily = [];
    $products = [];
    $countries = [];
    $latest = null;
    foreach (array_unique(array_map(fn($d) => str_replace('-', '', substr($d, 0, 7)), days_between($since, $until))) as $month) {
        $agg = cached("play_sales_$month", 3600, function () use ($bucket, $month) {
            $list = http_json('GET', 'https://storage.googleapis.com/storage/v1/b/' . rawurlencode($bucket) . '/o?'
                . http_build_query(['prefix' => "sales/salesreport_$month"]), ['Authorization: Bearer ' . google_token()]);
            $out = ['rows' => []];
            foreach ($list['items'] ?? [] as $o) {
                [$code, $zip] = http('GET', 'https://storage.googleapis.com/storage/v1/b/' . rawurlencode($bucket) . '/o/'
                    . rawurlencode($o['name']) . '?alt=media', ['Authorization: Bearer ' . google_token()], null, 60);
                if ($code !== 200) {
                    throw new RuntimeException("Play sales report: HTTP $code");
                }
                $tmp = tempnam(private_dir('cache'), 'zip');
                file_put_contents($tmp, $zip);
                $z = new ZipArchive();
                if ($z->open($tmp) === true) {
                    $csv = (string) $z->getFromIndex(0);
                    $z->close();
                    $lines = preg_split('/\r?\n/', trim($csv));
                    $head = str_getcsv(array_shift($lines), ',', '"', '');
                    foreach ($lines as $l) {
                        $r = array_combine($head, array_pad(str_getcsv($l, ',', '"', ''), count($head), ''));
                        if (($r['Product ID'] ?? '') !== PLAY_PACKAGE) {
                            continue;
                        }
                        $out['rows'][] = ['day' => $r['Order Charged Date'] ?? '', 'status' => $r['Financial Status'] ?? '',
                            'product' => ($r['SKU ID'] ?? '') . ' · ' . ($r['Product Title'] ?? ''),
                            'amount' => num(str_replace(',', '', $r['Charged Amount'] ?? '0')),
                            'currency' => $r['Currency of Sale'] ?? '', 'country' => $r['Country of Buyer'] ?? ''];
                    }
                }
                @unlink($tmp);
            }
            return $out;
        });
        foreach ($agg['rows'] as $r) {
            if ($r['day'] < $since || $r['day'] > $until) {
                continue;
            }
            $latest = max($latest ?? '', $r['day']);
            $refund = stripos($r['status'], 'refund') !== false;
            $gbp = fx_to_gbp($r['amount'], $r['currency']) ?? 0.0;
            $field = $refund ? 'refunds' : 'purchases';
            bump($daily, $r['day'], $field, 1);
            bump($daily, $r['day'], 'gross', $refund ? -abs($gbp) : $gbp);
            bump($products, $r['product'], $field, 1);
            bump($products, $r['product'], 'gross', $refund ? -abs($gbp) : $gbp);
            bump($countries, $r['country'], $field, 1);
        }
    }
    ksort($daily);
    return ['configured' => true, 'latest_date' => $latest, 'daily' => $daily, 'products' => $products, 'countries' => $countries];
}

// The purchase funnel the app reports through /f/ (lib/src/funnel.dart): a
// daily count per step, detail, platform, version and language, from this
// server's own files. Counts are of events, not people.
function source_funnel(string $since, string $until): array
{
    $dir = dirname(base_dir()) . '/funnel-counts';
    $steps = [];
    $daily = [];
    $versions = [];
    foreach (array_unique(array_map(fn($d) => substr($d, 0, 7), days_between($since, $until))) as $month) {
        $data = json_decode((string) @file_get_contents("$dir/$month.json"), true) ?: [];
        foreach ($data as $day => $rows) {
            if ($day < $since || $day > $until) {
                continue;
            }
            foreach ($rows as $key => $n) {
                [$step, $detail, $platform, $version] = array_pad(explode('|', $key), 5, '');
                $label = $detail === '' ? $step : "$step:$detail";
                bump($steps, $label, $platform, $n);
                bump($steps, $label, 'all', $n);
                bump($daily, $day, $step, $n);
                bump($versions, $version, 'events', $n);
            }
        }
    }
    ksort($daily);
    return ['configured' => true, 'steps' => $steps, 'daily' => $daily, 'versions' => $versions];
}
