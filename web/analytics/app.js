// The dashboard: fetches api.php and draws it. No libraries; the charts are SVG.
(function () {
  "use strict";

  var app = document.getElementById("app");
  var tip = document.getElementById("tip");
  var days = 14;
  try { days = +localStorage.getItem("wren-dash-days") || 14; } catch (e) { /* storage blocked */ }
  var timer = null;
  var regionName = (function () {
    try { var d = new Intl.DisplayNames(["en-GB"], { type: "region" }); return function (c) { try { return d.of(c) || c; } catch (e) { return c; } }; }
    catch (e) { return function (c) { return c; }; }
  })();

  // ------------------------------------------------------------ helpers

  function h(tag, attrs, kids) {
    var el = document.createElement(tag);
    for (var k in attrs || {}) {
      if (k === "class") el.className = attrs[k];
      else if (k === "text") el.textContent = attrs[k];
      else el.setAttribute(k, attrs[k]);
    }
    (kids || []).forEach(function (c) { if (c != null) el.appendChild(typeof c === "string" ? document.createTextNode(c) : c); });
    return el;
  }
  function n(v, dp) {
    if (v == null || v === "" || isNaN(v)) return "–";
    return (+v).toLocaleString("en-GB", { minimumFractionDigits: dp || 0, maximumFractionDigits: dp || 0 });
  }
  function gbp(v) { return v == null ? "–" : "£" + n(v, 2); }
  function sum(obj, f) { var t = 0; Object.keys(obj || {}).forEach(function (k) { t += +(obj[k][f] || 0); }); return t; }
  function ago(iso) {
    if (!iso) return "";
    var s = (Date.now() - Date.parse(iso)) / 1000;
    return s < 90 ? "just now" : s < 5400 ? Math.round(s / 60) + " min ago" : s < 172800 ? Math.round(s / 3600) + " h ago" : Math.round(s / 86400) + " days ago";
  }
  function shortDate(d) { return new Date(d + "T00:00:00Z").toLocaleDateString("en-GB", { day: "numeric", month: "short", timeZone: "UTC" }); }
  function dateList(since, until) {
    var out = [];
    for (var t = Date.parse(since + "T00:00:00Z"); t <= Date.parse(until + "T00:00:00Z"); t += 86400000) out.push(new Date(t).toISOString().slice(0, 10));
    return out;
  }

  // ------------------------------------------------------------ building blocks

  function section(title, note, kids) {
    return h("section", { class: "panel" }, [h("div", { class: "panel-head" }, [h("h2", { text: title }), note ? h("p", { class: "muted note", text: note }) : null])].concat(kids));
  }

  function sourceState(s, label) {
    if (!s) return h("p", { class: "muted", text: label + ": not requested." });
    if (s.configured === false) return h("p", { class: "notice", text: label + " is not connected yet. Its credentials are not in the server's config." });
    if (!s.ok) return h("p", { class: "notice error", text: label + " could not be read: " + s.error });
    return null;
  }

  function freshness(s, extra) {
    if (!s || !s.ok || s.configured === false) return "";
    return "Fetched " + ago(s.fetched) + (extra ? " · " + extra : "") + (s.stale ? " · showing the last good copy (" + s.stale + ")" : "");
  }

  function table(cols, rows, opts) {
    opts = opts || {};
    if (!rows.length) return h("p", { class: "muted", text: opts.empty || "Nothing in this range." });
    var head = h("tr", {}, cols.map(function (c) { return h("th", { class: c.num ? "num" : "", text: c.label }); }));
    var body = rows.map(function (r) {
      return h("tr", {}, cols.map(function (c) {
        var v = c.get(r);
        var cell = h("td", { class: c.num ? "num" : "" });
        if (v instanceof Node) cell.appendChild(v); else cell.textContent = v == null ? "–" : v;
        return cell;
      }));
    });
    if (opts.total) body.push(h("tr", { class: "total" }, cols.map(function (c, i) {
      return h("td", { class: c.num ? "num" : "", text: i === 0 ? "Total" : (c.total ? c.total(rows) : "") });
    })));
    return h("div", { class: "table-wrap" }, [h("table", {}, [h("thead", {}, [head]), h("tbody", {}, body)])]);
  }
  function totalOf(f, fmt) { return function (rows) { var t = 0; rows.forEach(function (r) { t += +(r[f] || 0); }); return (fmt || n)(t); }; }

  function pill(status) {
    var s = String(status || "").toUpperCase();
    var kind = /ACTIVE|ENABLE|DELIVERY_OK/.test(s) ? "good" : /PAUSE|DISABLE|NOT_DELIVER|ARCHIVED/.test(s) ? "off" : /REVIEW|PROCESS|LEARN/.test(s) ? "wait" : /ISSUE|REJECT|DISAPPROVED|ERROR/.test(s) ? "bad" : "off";
    var icon = { good: "●", off: "○", wait: "◐", bad: "▲" }[kind];
    return h("span", { class: "pill " + kind, text: icon + " " + s.replace(/^CAMPAIGN_STATUS_|_/g, " ").trim().toLowerCase() });
  }

  function tile(label, value, sub, source) {
    return h("div", { class: "tile" }, [h("div", { class: "tile-label", text: label }), h("div", { class: "tile-value", text: value }), h("div", { class: "tile-sub muted", text: sub || "" }), source ? h("div", { class: "tile-src", text: source }) : null]);
  }

  // A stacked daily bar chart. series: [{name, cls, values: {date: number}}].
  function barChart(dates, series, fmt, title) {
    fmt = fmt || n;
    // Drawn at the panel's real width, so text stays 11px rather than scaling.
    var W = Math.max(300, Math.min(1240, (app.clientWidth || 752) - 66)), H = 200, L = 52, R = 8, T = 10, B = 26;
    var totals = dates.map(function (d) { return series.reduce(function (t, s) { return t + (+(s.values[d] || 0)); }, 0); });
    var max = Math.max.apply(null, totals.concat([0]));
    if (max === 0) return h("p", { class: "muted", text: "Nothing recorded in this range." });
    var step = Math.pow(10, Math.floor(Math.log10(max))), nice = Math.ceil(max / step) * step;
    if (nice / step <= 2) nice = Math.ceil(max / (step / 5)) * (step / 5);
    var ns = "http://www.w3.org/2000/svg";
    function s(tag, a) { var e = document.createElementNS(ns, tag); for (var k in a) e.setAttribute(k, a[k]); return e; }
    var svg = s("svg", { viewBox: "0 0 " + W + " " + H, class: "chart", role: "img", "aria-label": title });
    var plotW = W - L - R, plotH = H - T - B, bw = plotW / dates.length;
    [0, 0.5, 1].forEach(function (f) {
      var y = T + plotH * (1 - f);
      svg.appendChild(s("line", { x1: L, x2: W - R, y1: y, y2: y, class: f === 0 ? "axis" : "grid" }));
      var t = s("text", { x: L - 6, y: y + 4, class: "tick", "text-anchor": "end" }); t.textContent = fmt(nice * f); svg.appendChild(t);
    });
    var every = Math.ceil(dates.length / Math.max(2, Math.floor(plotW / 64))); // ~64px per date label
    dates.forEach(function (d, i) {
      var x = L + i * bw, base = T + plotH, w = Math.max(2, Math.min(28, bw - 4)), cx = x + (bw - w) / 2;
      var stack = series.filter(function (se) { return +(se.values[d] || 0) > 0; });
      stack.forEach(function (se, j) {
        var hgt = plotH * (+se.values[d]) / nice, top = j === stack.length - 1;
        var y = base - hgt, gap = j > 0 ? 2 : 0;
        var r = top ? Math.min(4, hgt - gap, w / 2) : 0;
        var hh = Math.max(0, hgt - gap);
        var p = r > 0
          ? "M" + cx + "," + (y + hh) + "V" + (y + r) + "Q" + cx + "," + y + " " + (cx + r) + "," + y + "H" + (cx + w - r) + "Q" + (cx + w) + "," + y + " " + (cx + w) + "," + (y + r) + "V" + (y + hh) + "Z"
          : "M" + cx + "," + (y + hh) + "V" + y + "H" + (cx + w) + "V" + (y + hh) + "Z";
        svg.appendChild(s("path", { d: p, class: "mark " + se.cls }));
        base = y;
      });
      if ((dates.length - 1 - i) % every === 0) { // counted back from today, so today is always labelled
        var t = s("text", { x: x + bw / 2, y: H - 8, class: "tick", "text-anchor": "middle" }); t.textContent = shortDate(d); svg.appendChild(t);
      }
      var hit = s("rect", { x: x, y: T, width: bw, height: plotH, class: "hit" });
      hit.addEventListener("mousemove", function (ev) {
        tip.replaceChildren(h("strong", { text: shortDate(d) }));
        series.slice().reverse().forEach(function (se) {
          tip.appendChild(h("div", {}, [h("span", { class: "key " + se.cls }), se.name + ": " + fmt(+(se.values[d] || 0))]));
        });
        if (series.length > 1) tip.appendChild(h("div", { class: "muted", text: "Total: " + fmt(totals[i]) }));
        tip.hidden = false;
        var px = Math.min(ev.clientX + 14, window.innerWidth - tip.offsetWidth - 8);
        tip.style.left = px + "px"; tip.style.top = (ev.clientY + 14) + "px";
      });
      hit.addEventListener("mouseleave", function () { tip.hidden = true; });
      svg.appendChild(hit);
    });
    var legend = series.length > 1 ? h("div", { class: "legend" }, series.map(function (se) { return h("span", {}, [h("span", { class: "key " + se.cls }), se.name]); })) : null;
    return h("figure", { class: "figure" }, [h("figcaption", { text: title }), legend, svg]);
  }

  // ------------------------------------------------------------ the page

  function render(d) {
    var S = d.sources, dates = dateList(d.since, d.until);
    var meta = S.meta || {}, tt = S.tiktok || {}, apple = S.apple || {}, play = S.play || {};
    var gt = S.get || {}, pb = S.postbacks || {}, ga = S.ga4 || {}, rt = S.ga4_realtime || {};
    var live = function (s) { return s && s.ok && s.configured !== false; };

    var metaSpend = live(meta) ? sum(meta.daily, "spend") : null;
    var ttSpend = live(tt) ? sum(tt.daily, "spend") : null;
    var spend = (metaSpend || 0) + (ttSpend || 0);
    var appleFirst = live(apple) ? sum(apple.daily, "first") : null;
    var playInst = live(play) ? sum(play.daily, "installs") : null;
    var people = live(gt) ? sum(gt.daily, "iphone") + sum(gt.daily, "android") + sum(gt.daily, "other") : null;
    var won = live(pb) ? pb.postbacks.filter(function (p) { return p.won !== false; }).length : null;
    var measured = (appleFirst || 0) + (playInst || 0);

    var tiles = h("div", { class: "tiles" }, [
      tile("Ad spend", gbp(spend), (live(meta) ? "Meta " + gbp(metaSpend) : "Meta not connected") + " · " + (live(tt) ? "TikTok " + gbp(ttSpend) : "TikTok not connected"), "Meta + TikTok, live"),
      tile("App Store first-time downloads", n(appleFirst), live(apple) ? "Apple data to " + (apple.latest_date ? shortDate(apple.latest_date) : "–") : "Apple not connected", "All sources, not only ads"),
      tile("Google Play installs", n(playInst), live(play) ? "Play data to " + (play.latest_date ? shortDate(play.latest_date) : "–") : "Play not connected", "Daily user installs"),
      tile("Cost per download", measured > 0 && spend > 0 ? gbp(spend / measured) : "–", "Spend ÷ (App Store + Play), blended", "Lags: stores report days late"),
      tile("Meta-reported installs", n(live(meta) ? sum(meta.daily, "installs") : null), "iOS 14+ campaigns, modelled by Meta", "Meta Insights"),
      tile("Install reports from Apple", n(won), "SKAdNetwork postbacks, winning only", "Arrive 24–48 h+ late"),
      tile("/get/ visitors", n(people), live(gt) ? n(sum(gt.daily, "iphone")) + " iPhone · " + n(sum(gt.daily, "android")) + " Android" : "", "Includes in-app browser prefetch"),
      tile("On the website now", n(live(rt) ? rt.active : null), live(rt) ? "GA4 realtime, last 30 min" : "GA4 not connected", "Consented visitors only"),
    ]);

    var parts = [tiles];

    // Spend
    if (live(meta) || live(tt)) {
      var spendSeries = [];
      if (live(meta)) spendSeries.push({ name: "Meta", cls: "s1", values: map(meta.daily, "spend") });
      if (live(tt)) spendSeries.push({ name: "TikTok", cls: "s2", values: map(tt.daily, "spend") });
      parts.push(section("Spend per day", "Pounds. Meta and TikTok report spend within minutes.", [barChart(dates, spendSeries, gbp, "Ad spend per day")]));
    }

    // Meta
    parts.push(section("Meta (Instagram)", freshness(meta, "account " + (meta.currency || "")), [
      sourceState(meta, "Meta"),
      live(meta) ? table([
        { label: "Campaign", get: function (r) { return r.name; } },
        { label: "Status", get: function (r) { return pill(r.status); } },
        { label: "Budget", num: true, get: function (r) { return r.budget == null ? "–" : gbp(r.budget) + (r.budget_type === "daily" ? "/day" : ""); } },
        { label: "Spend", num: true, get: function (r) { return gbp(r.spend); }, total: totalOf("spend", gbp) },
        { label: "Impressions", num: true, get: function (r) { return n(r.impressions); }, total: totalOf("impressions") },
        { label: "Link clicks", num: true, get: function (r) { return n(r.link_clicks); }, total: totalOf("link_clicks") },
        { label: "CTR", num: true, get: function (r) { return r.ctr == null ? "–" : n(r.ctr, 2) + "%"; } },
        { label: "Installs", num: true, get: function (r) { return n(r.installs); }, total: totalOf("installs") },
        { label: "Cost/install", num: true, get: function (r) { return r.cpi == null ? "–" : gbp(r.cpi); } },
      ], meta.campaigns, { total: true }) : null,
      live(meta) ? h("details", {}, [h("summary", { text: "Ad sets" }), table([
        { label: "Ad set", get: function (r) { return r.name; } },
        { label: "Campaign", get: function (r) { return r.campaign; } },
        { label: "Spend", num: true, get: function (r) { return gbp(r.spend); } },
        { label: "Impressions", num: true, get: function (r) { return n(r.impressions); } },
        { label: "Link clicks", num: true, get: function (r) { return n(r.link_clicks); } },
        { label: "Installs", num: true, get: function (r) { return n(r.installs); } },
        { label: "Cost/install", num: true, get: function (r) { return r.cpi == null ? "–" : gbp(r.cpi); } },
      ], meta.adsets)]) : null,
      live(meta) ? h("details", {}, [h("summary", { text: "By country" }), table([
        { label: "Country", get: function (r) { return regionName(r.country); } },
        { label: "Spend", num: true, get: function (r) { return gbp(r.spend); } },
        { label: "Impressions", num: true, get: function (r) { return n(r.impressions); } },
        { label: "Link clicks", num: true, get: function (r) { return n(r.link_clicks); } },
        { label: "Installs", num: true, get: function (r) { return n(r.installs); } },
        { label: "Cost/install", num: true, get: function (r) { return r.cpi == null ? "–" : gbp(r.cpi); } },
      ], meta.countries)]) : null,
    ]));

    // TikTok
    var ttKids = [sourceState(tt, "TikTok")];
    if (tt.configured === false) ttKids.push(h("p", { class: "muted", text: "Until TikTok approves API access, its traffic shows up below: /get/ visitors with tt-* tokens, and App Store downloads under the same campaign tokens." }));
    if (live(tt)) ttKids.push(table([
      { label: "Campaign", get: function (r) { return r.name; } },
      { label: "Status", get: function (r) { return pill(r.status); } },
      { label: "Spend", num: true, get: function (r) { return gbp(r.spend); }, total: totalOf("spend", gbp) },
      { label: "Impressions", num: true, get: function (r) { return n(r.impressions); }, total: totalOf("impressions") },
      { label: "Clicks", num: true, get: function (r) { return n(r.clicks); }, total: totalOf("clicks") },
      { label: "Cost/click", num: true, get: function (r) { return r.cpc == null ? "–" : "£" + n(r.cpc, 3); } },
      { label: "Conversions", num: true, get: function (r) { return n(r.conversions); }, total: totalOf("conversions") },
    ], tt.campaigns, { total: true }));
    parts.push(section("TikTok", freshness(tt) + (live(tt) ? " · TikTok Promote (in-app boosts) is not in the API" : ""), ttKids));

    // Apple
    var appleKids = [sourceState(apple, "App Store Connect")];
    if (live(apple)) {
      if (apple.partial) appleKids.push(h("p", { class: "notice", text: "Still downloading Apple's report files. This fills in over the next minute." }));
      appleKids.push(barChart(dates, [{ name: "First-time downloads", cls: "s1", values: map(apple.daily, "first") }], n, "App Store first-time downloads per day"));
      var rows = Object.keys(apple.daily).sort().reverse().map(function (k) { return Object.assign({ date: k }, apple.daily[k]); });
      appleKids.push(table([
        { label: "Date", get: function (r) { return shortDate(r.date); } },
        { label: "Impressions", num: true, get: function (r) { return n(r.impressions); }, total: totalOf("impressions") },
        { label: "Page views", num: true, get: function (r) { return n(r.page_views); }, total: totalOf("page_views") },
        { label: "First-time", num: true, get: function (r) { return n(r.first); }, total: totalOf("first") },
        { label: "Redownloads", num: true, get: function (r) { return n(r.redownload); }, total: totalOf("redownload") },
        { label: "Updates", num: true, get: function (r) { return n(r.updates); }, total: totalOf("updates") },
      ], rows, { total: true }));
      appleKids.push(h("div", { class: "grid2" }, [
        h("div", {}, [h("h3", { text: "By campaign token" }), table([
          { label: "Token", get: function (r) { return r.k; } },
          { label: "Page views", num: true, get: function (r) { return n(r.page_views); } },
          { label: "First-time", num: true, get: function (r) { return n(r.first); } },
          { label: "Redownloads", num: true, get: function (r) { return n(r.redownload); } },
        ], entries(apple.campaigns, "page_views"))]),
        h("div", {}, [h("h3", { text: "By source" }), table([
          { label: "Source", get: function (r) { return r.k; } },
          { label: "Page views", num: true, get: function (r) { return n(r.page_views); } },
          { label: "First-time", num: true, get: function (r) { return n(r.first); } },
        ], entries(apple.sources, "first"))]),
        h("div", {}, [h("h3", { text: "Referring app or site" }), table([
          { label: "Referrer", get: function (r) { return friendlyReferrer(r.k); } },
          { label: "Page views", num: true, get: function (r) { return n(r.page_views); } },
          { label: "First-time", num: true, get: function (r) { return n(r.first); } },
        ], entries(apple.referrers, "page_views"))]),
        h("div", {}, [h("h3", { text: "By country" }), table([
          { label: "Country", get: function (r) { return regionName(r.k); } },
          { label: "Page views", num: true, get: function (r) { return n(r.page_views); } },
          { label: "First-time", num: true, get: function (r) { return n(r.first); } },
        ], entries(apple.territories, "first").slice(0, 25))]),
      ]));
      var pk = Object.keys(apple.purchases || {});
      if (pk.length) {
        var cols = {};
        pk.forEach(function (k) { Object.keys(apple.purchases[k]).forEach(function (c) { cols[c] = 1; }); });
        appleKids.push(h("h3", { text: "Purchases" }), table([{ label: "Date", get: function (r) { return shortDate(r.date); } }].concat(Object.keys(cols).map(function (c) {
          return { label: c, num: true, get: function (r) { return n(r[c], /USD|GBP|Proceeds|Sales/i.test(c) ? 2 : 0); }, total: totalOf(c, function (v) { return n(v, /USD|GBP|Proceeds|Sales/i.test(c) ? 2 : 0); }) };
        })), pk.sort().reverse().map(function (k) { return Object.assign({ date: k }, apple.purchases[k]); }), { total: true }));
      }
    }
    parts.push(section("App Store", freshness(apple, "Apple publishes daily, 1–2 days behind; campaigns under 5 downloads are hidden by Apple"), appleKids));

    // Play
    var playKids = [sourceState(play, "Google Play")];
    if (live(play)) {
      playKids.push(barChart(dates, [{ name: "Installs", cls: "s1", values: map(play.daily, "installs") }], n, "Google Play installs per day"));
      playKids.push(h("div", { class: "grid2" }, [
        h("div", {}, [h("h3", { text: "By country" }), table([
          { label: "Country", get: function (r) { return regionName(r.k); } },
          { label: "Installs", num: true, get: function (r) { return n(r.installs); } },
        ], entries(play.countries, "installs").slice(0, 25))]),
        h("div", {}, [h("h3", { text: "Store listing by source · UTM source / campaign" + (play.sources_latest ? " (to " + shortDate(play.sources_latest) + ")" : "") }), table([
          { label: "Source", get: function (r) { return r.k; } },
          { label: "Visitors", num: true, get: function (r) { return n(r.visitors); } },
          { label: "Installs", num: true, get: function (r) { return n(r.acquisitions); } },
        ], entries(play.sources, "visitors"), { empty: "Play has not published this month's traffic-source file yet; it comes later than installs." })]),
      ]));
    }
    parts.push(section("Google Play", freshness(play, "Play publishes daily, a few days behind"), playKids));

    // /get/
    var getKids = [sourceState(gt, "/get/ tally")];
    if (live(gt)) {
      getKids.push(barChart(dates, [
        { name: "iPhone/iPad", cls: "s1", values: map(gt.daily, "iphone") },
        { name: "Android", cls: "s2", values: map(gt.daily, "android") },
        { name: "Other", cls: "s3", values: map(gt.daily, "other") },
      ], n, "/get/ visitors per day, by device"));
      getKids.push(table([
        { label: "Token", get: function (r) { return r.k; } },
        { label: "iPhone/iPad", num: true, get: function (r) { return n(r.iphone); }, total: totalOf("iphone") },
        { label: "Android", num: true, get: function (r) { return n(r.android); }, total: totalOf("android") },
        { label: "Other", num: true, get: function (r) { return n(r.other); }, total: totalOf("other") },
        { label: "Bots/checkers", num: true, get: function (r) { return n(r.bot); }, total: totalOf("bot") },
      ], entries(gt.tokens, "iphone"), { total: true }));
    }
    parts.push(section("/get/ campaign links", "Live. TikTok's in-app browser loads links before anyone taps, so read this as device mix, not a click count.", getKids));

    // SKAN
    var pbKids = [sourceState(pb, "Postbacks")];
    if (live(pb)) pbKids.push(table([
      { label: "Received", get: function (r) { return new Date(r.received).toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" }); } },
      { label: "Network", get: function (r) { return r.network; } },
      { label: "Won", get: function (r) { return r.won === true ? "yes" : r.won === false ? "no" : "–"; } },
      { label: "Campaign/source id", get: function (r) { return r.source || "–"; } },
      { label: "Value", get: function (r) { return r.conversion == null ? "–" : String(r.conversion); } },
      { label: "Window", get: function (r) { return r.sequence == null ? "–" : String(+r.sequence + 1); } },
      { label: "Version", get: function (r) { return r.version; } },
    ], pb.postbacks, { empty: "No install reports from Apple in this range." }));
    parts.push(section("Install reports from Apple (SKAdNetwork)", "Copies of the postbacks Apple sends ad networks. Live as they arrive; Apple delays each by 24–48 hours or more, at random.", pbKids));

    // GA4
    var gaKids = [sourceState(ga, "Google Analytics")];
    if (live(ga)) {
      gaKids.push(barChart(dates, [{ name: "Sessions", cls: "s1", values: map(ga.daily, "sessions") }], n, "Website sessions per day"));
      gaKids.push(h("div", { class: "grid2" }, [
        h("div", {}, [h("h3", { text: "Where visitors came from" }), table([
          { label: "Source / medium", get: function (r) { return r.source + " / " + r.medium; } },
          { label: "Campaign", get: function (r) { return r.campaign === "(not set)" ? "–" : r.campaign; } },
          { label: "Sessions", num: true, get: function (r) { return n(r.sessions); } },
        ], ga.sources)]),
        h("div", {}, [h("h3", { text: "Pages" }), table([
          { label: "Page", get: function (r) { return r.page; } },
          { label: "Views", num: true, get: function (r) { return n(r.views); } },
        ], ga.pages)]),
        live(rt) && rt.countries.length ? h("div", {}, [h("h3", { text: "On the site in the last 30 minutes" }), table([
          { label: "Country", get: function (r) { return r.country; } },
          { label: "Users", num: true, get: function (r) { return n(r.users); } },
        ], rt.countries)]) : null,
      ]));
    }
    parts.push(section("Website (wren.spencerfields.com)", freshness(ga, "only visitors who accepted cookies are counted"), gaKids));

    app.replaceChildren.apply(app, parts.filter(Boolean));
    return live(apple) && apple.partial;
  }

  function map(daily, f) { var o = {}; Object.keys(daily || {}).forEach(function (k) { o[k] = daily[k][f] || 0; }); return o; }
  function entries(obj, by) {
    return Object.keys(obj || {}).map(function (k) { return Object.assign({ k: k }, obj[k]); })
      .sort(function (a, b) { return (b[by] || 0) - (a[by] || 0); });
  }
  function friendlyReferrer(id) {
    return { "com.burbn.instagram": "Instagram", "com.zhiliaoapp.musically": "TikTok", "com.ss.iphone.ugc.Ame": "TikTok (CN)", "com.facebook.Facebook": "Facebook", "com.apple.MobileSMS": "Messages", "com.google.GoogleMobile": "Google app", "com.apple.mobilesafari": "Safari" }[id] || id;
  }

  // ------------------------------------------------------------ loading

  function load(refresh) {
    clearTimeout(timer);
    document.getElementById("updated").textContent = "Updating…";
    fetch("api.php?days=" + days + (refresh ? "&refresh=1" : ""), { credentials: "same-origin" })
      .then(function (r) {
        if (r.status === 401) { location.reload(); throw new Error("signed out"); }
        return r.json();
      })
      .then(function (d) {
        lastData = d;
        var partial = render(d);
        document.getElementById("updated").textContent = "Updated " + new Date().toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
        timer = setTimeout(load, partial ? 15000 : 300000);
      })
      .catch(function (e) {
        document.getElementById("updated").textContent = "Update failed";
        timer = setTimeout(load, 60000);
      });
  }

  document.querySelectorAll(".range button").forEach(function (b) {
    b.setAttribute("aria-pressed", String(+b.dataset.days === days));
    b.addEventListener("click", function () {
      days = +b.dataset.days;
      try { localStorage.setItem("wren-dash-days", String(days)); } catch (e) { /* ignore */ }
      document.querySelectorAll(".range button").forEach(function (x) { x.setAttribute("aria-pressed", String(x === b)); });
      load(false);
    });
  });
  document.getElementById("refresh").addEventListener("click", function () { load(true); });
  document.getElementById("logout").addEventListener("click", function () {
    var body = new URLSearchParams({ action: "logout", csrf: document.querySelector('meta[name="csrf"]').content });
    fetch("auth.php", { method: "POST", body: body, credentials: "same-origin" }).finally(function () { location.reload(); });
  });
  document.addEventListener("visibilitychange", function () { if (!document.hidden) load(false); });
  var lastData = null, resizeTimer = null;
  window.addEventListener("resize", function () {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () { if (lastData) render(lastData); }, 200);
  });
  load(false);
})();
