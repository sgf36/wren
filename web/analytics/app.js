// The dashboard: fetches api.php and draws it. No libraries; the charts are SVG.
(function () {
  "use strict";

  var app = document.getElementById("app");
  var tip = document.getElementById("tip");
  var days = 14; // 0 is the "Real time" tab
  try {
    var saved = localStorage.getItem("wren-dash-days");
    if (saved !== null && [0, 1, 7, 14, 30].indexOf(+saved) >= 0) days = +saved;
  } catch (e) { /* storage blocked */ }
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

  // badges: how current this section's figures are (see badge()).
  function section(title, note, kids, badges) {
    return h("section", { class: "panel" }, [h("div", { class: "panel-head" }, [h("h2", { text: title }),
      badges && badges.length ? h("div", { class: "fresh-row" }, badges.filter(Boolean)) : null,
      note ? h("p", { class: "muted note", text: note }) : null])].concat(kids));
  }

  // How current each source's figures are. Every tile, section and chart says so,
  // so a zero that only means "not reported yet" is never read as "none".
  //   live   counted as it happens
  //   near   minutes to hours behind (or, for install reports, a day or more)
  //   daily  published once a day; the badge names the last day actually published
  var FRESH = {
    meta: ["near", "Near real-time", "Meta updates spend, impressions and clicks about every 15 minutes; this page re-reads them every 5."],
    meta_installs: ["near", "1–3 days late", "Meta counts iOS installs through Apple's SKAdNetwork, which holds each one back 24–72 hours."],
    tiktok: ["near", "Within hours", "TikTok's reporting runs up to a few hours behind; this page re-reads it every 5 minutes."],
    ga4: ["near", "Same day", "Google Analytics shows today within hours and finalises each day after 24–48 hours."],
    ga4_realtime: ["live", "Live", "Visitors in the last 30 minutes, re-read every minute."],
    get: ["live", "Live", "Each tap is counted the moment it happens."],
    funnel: ["live", "Live", "Each step is counted the moment the app reports it (Wren 2.1.9 and later)."],
    postbacks: ["near", "about installs 1–2 days earlier", "Counted on the day Apple sends them. Apple holds each report back on a timer (24 hours after the app is first opened, plus up to 24 more at random), so every one describes an install from a day or two before it arrives."],
    // daily sources: [.., .., tooltip, days Apple/Google usually take to publish a day, how to say it]
    apple: ["daily", "", "Apple publishes App Store analytics once a day, usually 1–2 days behind.", 2, "1–2 days later"],
    sales: ["daily", "", "Apple publishes sales once a day, for the previous day.", 1, "the next day"],
    play: ["daily", "", "Google publishes Play installs once a day, a few days behind.", 3, "a few days later"],
    play_sales: ["daily", "", "Google refreshes the month's Play sales file once a day.", 1, "the next day"],
  };
  var TODAY = "", SINCE = "", hatchCount = 0;
  function addDays(d, k) { return new Date(Date.parse(d + "T00:00:00Z") + k * 864e5).toISOString().slice(0, 10); }
  function daysBehind(latest) { return Math.round((Date.parse(TODAY + "T00:00:00Z") - Date.parse(latest + "T00:00:00Z")) / 864e5); }
  function badge(key, s, prefix, latestOverride) {
    var f = FRESH[key], kind = f[0], text = f[1], tipText = f[2], who = prefix ? prefix + ": " : "";
    if (!s || s.configured === false || !s.ok) return h("span", { class: "fresh off", title: tipText, text: "○ " + who + "not available" });
    if (s.waiting) return h("span", { class: "fresh near", title: "Google is applying the Play Console access you granted; this takes up to 24 hours.", text: "◷ " + who + "waiting for Google" });
    if (kind === "daily") {
      var latest = latestOverride || s.latest_date;
      // Nothing yet is normal when every day shown is younger than the source's
      // usual publishing delay ("Today" always is): say when it comes, without
      // the warning triangle. Older days with nothing are worth a warning.
      if (!latest) {
        var normal = f[3] && SINCE && daysBehind(SINCE) < f[3];
        kind = normal ? "near" : "stale";
        text = normal ? "not published yet · comes " + f[4] : "nothing published for these dates";
      }
      else {
        var b = daysBehind(latest);
        text = "to " + shortDate(latest) + " · " + (b <= 0 ? "up to date" : b === 1 ? "1 day behind" : b + " days behind");
        if (b >= 3) kind = "stale";
      }
    }
    var title = tipText + (s.fetched ? " Checked " + ago(s.fetched) + "." : "") + (s.stale ? " Showing the last good copy: " + s.stale : "");
    var words = who + text + (s.stale ? " (last good copy)" : "");
    if (kind === "live") {
      // A pulsing green dot, so live figures stand out at a glance.
      return h("span", { class: "fresh live", title: title }, [h("span", { class: "pulse", "aria-hidden": "true" }), words]);
    }
    var icon = { near: "◷", daily: "▦", stale: "▲" }[kind];
    return h("span", { class: "fresh " + kind, title: title, text: icon + " " + words });
  }
  function checked(s) { return s && s.ok && s.fetched ? h("span", { class: "fresh-checked", text: "checked " + ago(s.fetched) }) : null; }

  function sourceState(s, label) {
    if (!s) return h("p", { class: "muted", text: label + ": not requested." });
    if (s.configured === false) return h("p", { class: "notice", text: label + " is not connected yet. Its credentials are not in the server's config." });
    if (s.waiting) return h("p", { class: "notice", text: "Waiting for Google to apply the Play Console access you granted. Google takes up to 24 hours; nothing needs changing here, and the figures appear on their own." });
    if (!s.ok) return h("p", { class: "notice error", text: label + " could not be read: " + s.error });
    return null;
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
    var kind = /NO_RECENT_DELIVERY|PAUSE|DISABLE|NOT_DELIVER|ARCHIVED/.test(s) ? "off" : /ACTIVE|ENABLE|DELIVERY_OK|DELIVERING_NOW/.test(s) ? "good"
      : /REVIEW|PROCESS|LEARN|DELIVERED_YESTERDAY/.test(s) ? "wait" : /ISSUE|REJECT|DISAPPROVED|ERROR/.test(s) ? "bad" : "off";
    var icon = { good: "●", off: "○", wait: "◐", bad: "▲" }[kind];
    return h("span", { class: "pill " + kind, text: icon + " " + s.replace(/^CAMPAIGN_STATUS_|_/g, " ").trim().toLowerCase() });
  }

  // badges: one per source behind the number, so a tile mixing a live source
  // with a daily one says which part is which.
  function tile(label, value, sub, note, badges) {
    return h("div", { class: "tile" }, [h("div", { class: "tile-label", text: label }), h("div", { class: "tile-value", text: value }),
      h("div", { class: "tile-sub muted", text: sub || "" }), note ? h("div", { class: "tile-note muted", text: note }) : null,
      h("div", { class: "tile-fresh" }, (badges || []).filter(Boolean))]);
  }

  // A stacked daily bar chart. series: [{name, cls, values: {date: number}}].
  // reportedTo: the last day the source has published; later days are hatched
  // "not reported yet", so they are not read as zero.
  function barChart(dates, series, fmt, title, reportedTo) {
    fmt = fmt || n;
    var pendingFrom = reportedTo ? dates.filter(function (d) { return d > reportedTo; }) : [];
    // Drawn at the panel's real width, so text stays 11px rather than scaling.
    var W = Math.max(300, Math.min(1240, (app.clientWidth || 752) - 66)), H = 200, L = 52, R = 8, T = 10, B = 26;
    var totals = dates.map(function (d) { return series.reduce(function (t, s) { return t + (+(s.values[d] || 0)); }, 0); });
    var max = Math.max.apply(null, totals.concat([0]));
    if (max === 0) return h("p", { class: "muted", text: "Nothing recorded in this range" + (reportedTo ? " (reported to " + shortDate(reportedTo) + ")." : ".") });
    // Gridlines at 0, half and top: pick a round half-value, so both labels are
    // round; counts never get a fractional half (3 would label 1.5 as "2").
    var half = max / 2, mag = Math.pow(10, Math.floor(Math.log10(half)));
    var mid = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].map(function (m) { return m * mag; })
      .filter(function (m) { return m >= half - 1e-9 && (fmt !== n || Math.abs(m - Math.round(m)) < 1e-9); })[0];
    var nice = 2 * (fmt === n ? Math.max(1, mid || Math.ceil(half)) : mid);
    var ns = "http://www.w3.org/2000/svg";
    function s(tag, a) { var e = document.createElementNS(ns, tag); for (var k in a) e.setAttribute(k, a[k]); return e; }
    var svg = s("svg", { viewBox: "0 0 " + W + " " + H, class: "chart", role: "img", "aria-label": title });
    var plotW = W - L - R, plotH = H - T - B, bw = plotW / dates.length;
    if (pendingFrom.length) {
      var defs = s("defs", {}), hid = "hatch" + (++hatchCount), pat = s("pattern", { id: hid, width: 6, height: 6, patternUnits: "userSpaceOnUse", patternTransform: "rotate(45)" });
      pat.appendChild(s("line", { x1: 0, y1: 0, x2: 0, y2: 6, class: "hatch" }));
      defs.appendChild(pat); svg.appendChild(defs);
      var px0 = L + dates.indexOf(pendingFrom[0]) * bw;
      svg.appendChild(s("rect", { x: px0, y: T, width: W - R - px0, height: plotH, class: "pending", fill: "url(#" + hid + ")" }));
    }
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
        if (reportedTo && d > reportedTo) { tip.appendChild(h("div", { class: "muted", text: "Not reported yet" })); }
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
    var keys = series.length > 1 ? series.map(function (se) { return h("span", {}, [h("span", { class: "key " + se.cls }), se.name]); }) : [];
    if (pendingFrom.length) keys.push(h("span", {}, [h("span", { class: "key pending-key" }), "Not reported yet (after " + shortDate(reportedTo) + ")"]));
    var legend = keys.length ? h("div", { class: "legend" }, keys) : null;
    return h("figure", { class: "figure" }, [h("figcaption", { text: title }), legend, svg]);
  }

  // ------------------------------------------------------------ the page

  // The app's funnel steps, in order, then the events along the way. Shared by
  // the dated view and the "Real time" tab, so both name a step the same way.
  var FUNNEL = [
    ["first_open", "Opened Wren for the first time"],
    ["import_started", "Started an import"],
    ["reel_read:free", "Read a post on a free read"],
    ["paywall_shown", "Saw a purchase sheet"],
    ["buy_tapped", "Tapped a buy button"],
    ["purchased", "Bought"],
  ];
  var SIDE = [
    ["paywall_shown:places", "Sheet: more than 3 places"],
    ["paywall_shown:combine", "Sheet: adding to an existing guide"],
    ["paywall_shown:reels", "Sheet: reading a post"],
    ["purchase_failed", "Purchase cancelled or failed"],
    ["paywall_dismissed", "Closed the sheet without choosing"],
    ["saved_free_instead", "Saved the free 3 instead"],
    ["restore_tapped", "Tapped restore"],
    ["reel_read:paid", "Read a post on a purchase"],
    ["guide_saved", "Saved a guide / sent places"],
  ];

  // Where /get/ visitors opened the link, their country and their language:
  // three separate tallies kept by web/get/index.php since 10 Oct 2026, bots
  // left out. cell(id, value) draws a count (the Real time tab lights changes).
  var APP_NAMES = { tiktok: "TikTok", instagram: "Instagram", facebook: "Facebook", messenger: "Messenger", snapchat: "Snapchat",
    pinterest: "Pinterest", linkedin: "LinkedIn", x: "X", "google app": "Google app", browser: "A web browser" };
  var GET_SOURCES_NOTE = "Below: counted since 10 Oct 2026, bots left out. Three separate tallies, so they cannot be combined into one visitor. Country from MaxMind GeoLite2.";
  var langName = (function () {
    try { var d = new Intl.DisplayNames(["en-GB"], { type: "language" }); return function (c) { try { return d.of(c) || c; } catch (e) { return c; } }; }
    catch (e) { return function (c) { return c; }; }
  })();
  function getSources(apps, countries, langs, cell) {
    cell = cell || function (id, v) { return n(v); };
    function one(title, first, obj, name, id) {
      var rows = Object.keys(obj || {}).map(function (k) { return { k: k, v: +obj[k] }; }).sort(function (a, b) { return b.v - a.v; });
      // Share of this table's own total, over every row (not only the 25 shown).
      var total = rows.reduce(function (t, r) { return t + r.v; }, 0);
      return h("div", {}, [h("h3", { text: title }), table([
        { label: first, get: function (r) { return r.k === "unknown" ? "Unknown" : name(r.k); } },
        { label: "Visitors", num: true, get: function (r) { return cell(id + r.k, r.v); } },
        { label: "Share", num: true, get: function (r) { var p = total ? 100 * r.v / total : 0; return !total ? "–" : p > 0 && p < 1 ? "<1%" : n(p) + "%"; } },
      ], rows.slice(0, 25), { empty: "None yet." })]);
    }
    return h("div", { class: "grid2" }, [
      one("Opened in", "App", apps, function (k) { return APP_NAMES[k] || k; }, "a-"),
      one("Country", "Country", countries, regionName, "c-"),
      one("Language", "Language", langs, langName, "l-"),
    ]);
  }

  // ------------------------------------------------------------ the "Real time" tab
  //
  // Only what is counted the moment it happens: the app's funnel steps, /get/
  // link visitors, and people on the website now. Every figure except the last
  // starts at zero when the tab is opened and counts up while it stays open;
  // leaving the tab, or reloading, starts again. The server sends running
  // totals keyed by day; the first answer is kept as the baseline and each
  // figure is the growth since, key by key, so midnight cannot make one fall.

  var liveBase = null, liveSince = 0, livePrev = {};

  function renderLive(d) {
    var C = d.counts || {};
    if (!liveBase) { liveBase = C; liveSince = Date.now(); livePrev = {}; }
    var grew = {}; // "funnel|<step>|<platform>" or "get|<token>|<device>" -> growth
    Object.keys(C).forEach(function (k) {
      var g = (+C[k]) - (+(liveBase[k] || 0));
      if (g <= 0) return;
      var p = k.split("|");
      var key = p[0] + "|" + p[2] + "|" + p[3];
      grew[key] = (grew[key] || 0) + g;
    });
    var next = {};
    // A count that went up since the last look briefly lights up.
    function cnt(id, v) {
      next[id] = v;
      return h("span", { class: v > (livePrev[id] || 0) ? "bump" : "", text: n(v) });
    }
    function step(key) {
      var out = { ios: 0, android: 0, all: 0 };
      Object.keys(grew).forEach(function (k) {
        var p = k.split("|");
        if (p[0] !== "funnel" || !(p[1] === key || p[1].indexOf(key + ":") === 0)) return;
        if (p[2] === "ios" || p[2] === "android") out[p[2]] += grew[k];
        out.all += grew[k];
      });
      return out;
    }
    var appSteps = 0, tokens = {}, visitors = { iphone: 0, android: 0, other: 0 }, dims = { app: {}, lang: {}, country: {} };
    Object.keys(grew).forEach(function (k) {
      var p = k.split("|");
      if (p[0] === "funnel") appSteps += grew[k];
      if (p[0] === "getd" && dims[p[1]]) dims[p[1]][p[2]] = (dims[p[1]][p[2]] || 0) + grew[k];
      if (p[0] === "get" && p[2] !== "bot") {
        visitors[p[2]] = (visitors[p[2]] || 0) + grew[k];
        var t = tokens[p[1]] = tokens[p[1]] || { k: p[1], iphone: 0, android: 0, other: 0 };
        t[p[2]] = (t[p[2]] || 0) + grew[k];
      }
    });
    var rt = (d.sources || {}).ga4_realtime || {};
    var mine = { ok: true, configured: true, fetched: d.generated };
    var mins = Math.floor((Date.now() - liveSince) / 60000);
    var since = new Date(liveSince).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });

    var parts = [h("p", { class: "notice live-note", text: "Counting since " + since + (mins ? " (" + mins + " min)" : "") +
      ". Each figure starts at zero when you open this tab and goes up as things happen; leaving the tab starts again. " +
      "Ad spend runs minutes to hours behind and the stores report daily, so those stay on the other tabs." })];

    parts.push(h("div", { class: "tiles" }, [
      h("div", { class: "tile" }, [h("div", { class: "tile-label", text: "App steps" }),
        h("div", { class: "tile-value" }, [cnt("t-app", appSteps)]), h("div", { class: "tile-sub muted", text: "Every funnel event, both platforms" }),
        h("div", { class: "tile-fresh" }, [badge("funnel", mine)])]),
      h("div", { class: "tile" }, [h("div", { class: "tile-label", text: "/get/ visitors" }),
        h("div", { class: "tile-value" }, [cnt("t-get", visitors.iphone + visitors.android + visitors.other)]),
        h("div", { class: "tile-sub muted", text: n(visitors.iphone) + " iPhone · " + n(visitors.android) + " Android" }),
        h("div", { class: "tile-fresh" }, [badge("get", mine)])]),
      tile("On the website now", n(rt.ok && rt.configured !== false ? rt.active : null), "Visitors in the last 30 minutes",
        "A count of who is there now, so it can fall; only those who accepted cookies", [badge("ga4_realtime", rt)]),
    ]));

    function stepRows(list) {
      return list.map(function (f) { var c = step(f[0]); return { id: f[0], k: f[1], ios: c.ios, android: c.android, all: c.all }; });
    }
    var cols = [
      { label: "Step", get: function (r) { return r.k; } },
      { label: "iPhone", num: true, get: function (r) { return cnt("f-" + r.id + "-ios", r.ios); } },
      { label: "Android", num: true, get: function (r) { return cnt("f-" + r.id + "-and", r.android); } },
      { label: "Total", num: true, get: function (r) { return cnt("f-" + r.id + "-all", r.all); } },
    ];
    parts.push(section("Purchase funnel, since you opened this tab", "Counts of events, not people.", [
      table(cols, stepRows(FUNNEL)), h("h3", { text: "Along the way" }), table(cols, stepRows(SIDE)),
    ], [badge("funnel", mine)]));

    parts.push(section("/get/ campaign links, since you opened this tab", "Checkers and bots are left out.", [
      table([
        { label: "Token", get: function (r) { return r.k; } },
        { label: "iPhone/iPad", num: true, get: function (r) { return cnt("g-" + r.k + "-i", r.iphone); } },
        { label: "Android", num: true, get: function (r) { return cnt("g-" + r.k + "-a", r.android); } },
        { label: "Other", num: true, get: function (r) { return cnt("g-" + r.k + "-o", r.other); } },
      ], entries(tokens, "iphone"), { empty: "No visitors since you opened this tab." }),
      h("p", { class: "muted note", text: GET_SOURCES_NOTE.replace("Below: counted since 10 Oct 2026, bots", "Below: bots") }),
      getSources(dims.app, dims.country, dims.lang, cnt),
    ], [badge("get", mine)]));

    app.replaceChildren.apply(app, parts);
    livePrev = next;
  }

  function render(d) {
    var S = d.sources, dates = dateList(d.since, d.until);
    TODAY = d.until;
    SINCE = d.since;
    var meta = S.meta || {}, tt = S.tiktok || {}, apple = S.apple || {}, play = S.play || {};
    var gt = S.get || {}, pb = S.postbacks || {}, ga = S.ga4 || {}, rt = S.ga4_realtime || {};
    var sales = S.sales || {}, ps = S.play_sales || {}, fn = S.funnel || {};
    var live = function (s) { return s && s.ok && s.configured !== false && !s.waiting; };

    var metaSpend = live(meta) ? sum(meta.daily, "spend") : null;
    var ttSpend = live(tt) ? sum(tt.daily, "spend") : null;
    var spend = (metaSpend || 0) + (ttSpend || 0);
    var appleFirst = live(apple) ? sum(apple.daily, "first") : null;
    var playInst = live(play) ? sum(play.daily, "installs") : null;
    var people = live(gt) ? sum(gt.daily, "iphone") + sum(gt.daily, "android") + sum(gt.daily, "other") : null;
    var won = live(pb) ? pb.postbacks.filter(function (p) { return p.won !== false; }).length : null;
    // Stores report days late, so set downloads only against spend on the days
    // they have reported; otherwise today's spend inflates the cost.
    var cutoff = [live(apple) && apple.latest_date, live(play) && play.latest_date].filter(Boolean).sort()[0] || null;
    function toCutoff(dly, f) {
      var t = 0;
      Object.keys(dly || {}).forEach(function (k) { if (cutoff && k <= cutoff) t += +(dly[k][f] || 0); });
      return t;
    }
    var spendToCutoff = toCutoff(live(meta) && meta.daily, "spend") + toCutoff(live(tt) && tt.daily, "spend");
    var downloadsToCutoff = toCutoff(live(apple) && apple.daily, "first") + toCutoff(live(play) && play.daily, "installs");

    // A blended figure is only as current as its slowest daily source, so its
    // badge names the day it runs to.
    var cutSrc = { ok: true, latest_date: cutoff, fetched: (apple.fetched || play.fetched) };
    var tiles = h("div", { class: "tiles" }, [
      tile("Ad spend", gbp(spend), (live(meta) ? "Meta " + gbp(metaSpend) : "Meta not connected") + " · " + (live(tt) ? "TikTok " + gbp(ttSpend) : "TikTok not connected"), null,
        [badge("meta", meta, "Meta"), badge("tiktok", tt, "TikTok")]),
      tile("App Store first-time downloads", n(appleFirst), "All sources, not only ads", null, [badge("apple", apple)]),
      tile("Google Play installs", n(playInst), "Daily user installs", null, [badge("play", play)]),
      tile("Cost per download", downloadsToCutoff > 0 && spendToCutoff > 0 ? gbp(spendToCutoff / downloadsToCutoff) : "–",
        "Spend ÷ (App Store + Play downloads)", "Both sides stop at the stores' last reported day", [badge("apple", cutSrc, "Stores", cutoff)]),
      tile("Meta-reported installs", n(live(meta) ? sum(meta.daily, "installs") : null), "iOS 14+ campaigns, modelled by Meta",
        "The last 3 days keep rising as Apple's reports reach Meta, so a low figure for today is not final", [badge("meta_installs", meta)]),
      // Counted by the day Apple sent them, which is not the day of the install:
      // name the days the installs most likely happened instead.
      tile("Install reports received from Apple", n(won), "SKAdNetwork, winning only",
        "Installs from about " + (SINCE === TODAY ? shortDate(addDays(SINCE, -2)) + "–" + shortDate(addDays(TODAY, -1))
          : shortDate(addDays(SINCE, -2)) + " to " + shortDate(addDays(TODAY, -1))) + ": Apple sends each one a day or two late", [badge("postbacks", pb)]),
      tile("/get/ visitors", n(people), live(gt) ? n(sum(gt.daily, "iphone")) + " iPhone · " + n(sum(gt.daily, "android")) + " Android" : "", "Includes in-app browser prefetch", [badge("get", gt)]),
      tile("On the website now", n(live(rt) ? rt.active : null), "Visitors in the last 30 minutes", "Only those who accepted cookies", [badge("ga4_realtime", rt)]),
    ]);

    // In-app purchases: Apple's sales report (net proceeds) and Play's sales
    // report (gross charged). Return on spend only over days both sides cover.
    var iapCount = (live(sales) ? sum(sales.daily, "purchases") : 0) + (live(ps) ? sum(ps.daily, "purchases") : 0);
    var iapRefunds = (live(sales) ? sum(sales.daily, "refunds") : 0) + (live(ps) ? sum(ps.daily, "refunds") : 0);
    var iapMoney = (live(sales) ? sum(sales.daily, "proceeds") : 0) + (live(ps) ? sum(ps.daily, "gross") : 0);
    var salesCut = [live(sales) && sales.latest_date, live(ps) && ps.latest_date].filter(Boolean).sort()[0] || null;
    function sumTo(dly, f, cut) { var t = 0; Object.keys(dly || {}).forEach(function (k) { if (cut && k <= cut) t += +(dly[k][f] || 0); }); return t; }
    var moneyToCut = sumTo(live(sales) && sales.daily, "proceeds", salesCut) + sumTo(live(ps) && ps.daily, "gross", salesCut);
    var spendToSalesCut = sumTo(live(meta) && meta.daily, "spend", salesCut) + sumTo(live(tt) && tt.daily, "spend", salesCut);
    var anySales = live(sales) || live(ps);
    tiles.appendChild(tile("In-app purchases", anySales ? n(iapCount) : "–",
      anySales ? n(iapRefunds) + " refunded" : "Sales reports not connected",
      "Every buyer, from the stores' sales reports", [badge("sales", sales, "App Store"), badge("play_sales", ps, "Play")]));
    tiles.appendChild(tile("In-app revenue", anySales ? "≈" + gbp(iapMoney) : "–", "App Store net proceeds + Play gross", "Converted to £ at today's rate",
      [badge("sales", sales, "App Store"), badge("play_sales", ps, "Play")]));
    tiles.appendChild(tile("Return on ad spend", anySales && spendToSalesCut > 0 ? n(moneyToCut / spendToSalesCut, 2) + "×" : "–",
      "In-app revenue ÷ ad spend", "All revenue, not only ad-driven; both sides stop at the sales reports' last day",
      [badge("sales", { ok: anySales, latest_date: salesCut, fetched: sales.fetched || ps.fetched }, "Sales", salesCut)]));

    var parts = [tiles];

    // Spend
    if (live(meta) || live(tt)) {
      var spendSeries = [];
      if (live(meta)) spendSeries.push({ name: "Meta", cls: "s1", values: map(meta.daily, "spend") });
      if (live(tt)) spendSeries.push({ name: "TikTok", cls: "s2", values: map(tt.daily, "spend") });
      parts.push(section("Spend per day", "Pounds. Today's bar keeps growing until the day ends.", [barChart(dates, spendSeries, gbp, "Ad spend per day")],
        [badge("meta", meta, "Meta"), badge("tiktok", tt, "TikTok"), checked(meta)]));
    }

    // In-app purchases
    var iapKids = [sourceState(sales, "App Store sales reports"), sourceState(ps, "Google Play sales reports")];
    if (live(sales) && sales.partial) iapKids.push(h("p", { class: "notice", text: "Still downloading Apple's daily sales reports. This fills in over the next minute." }));
    if (live(sales) && sales.unconverted && sales.unconverted.length) iapKids.push(h("p", { class: "notice", text: "No exchange rate for " + sales.unconverted.join(", ") + "; those amounts are left out of the £ figures." }));
    if (anySales) {
      var iapSeries = [];
      if (live(sales)) iapSeries.push({ name: "App Store", cls: "s1", values: map(sales.daily, "purchases") });
      if (live(ps)) iapSeries.push({ name: "Google Play", cls: "s2", values: map(ps.daily, "purchases") });
      iapKids.push(barChart(dates, iapSeries, n, "In-app purchases per day", salesCut));
      var drows = {};
      [[live(sales) && sales.daily, "proceeds", "a"], [live(ps) && ps.daily, "gross", "g"]].forEach(function (x) {
        Object.keys(x[0] || {}).forEach(function (k) {
          var d = drows[k] = drows[k] || { date: k, purchases: 0, refunds: 0, apple: 0, play: 0 };
          d.purchases += +(x[0][k].purchases || 0); d.refunds += +(x[0][k].refunds || 0);
          d[x[2] === "a" ? "apple" : "play"] += +(x[0][k][x[1]] || 0);
        });
      });
      iapKids.push(table([
        { label: "Date", get: function (r) { return shortDate(r.date); } },
        { label: "Purchases", num: true, get: function (r) { return n(r.purchases); }, total: totalOf("purchases") },
        { label: "Refunds", num: true, get: function (r) { return n(r.refunds); }, total: totalOf("refunds") },
        { label: "App Store net ≈£", num: true, get: function (r) { return n(r.apple, 2); }, total: totalOf("apple", function (v) { return n(v, 2); }) },
        { label: "Play gross ≈£", num: true, get: function (r) { return n(r.play, 2); }, total: totalOf("play", function (v) { return n(v, 2); }) },
      ], Object.keys(drows).sort().reverse().map(function (k) { return drows[k]; }).filter(function (r) { return r.purchases || r.refunds; }),
        { total: true, empty: "No in-app purchases in this range." }));
      var prod = {};
      [[live(sales) && sales.products, "proceeds", "App Store"], [live(ps) && ps.products, "gross", "Play"]].forEach(function (x) {
        Object.keys(x[0] || {}).forEach(function (k) { prod[x[2] + " · " + k] = { purchases: x[0][k].purchases || 0, refunds: x[0][k].refunds || 0, money: x[0][k][x[1]] || 0 }; });
      });
      var ctry = {};
      [live(sales) && sales.countries, live(ps) && ps.countries].forEach(function (c) {
        Object.keys(c || {}).forEach(function (k) { var o = ctry[k] = ctry[k] || { purchases: 0, proceeds: 0 }; o.purchases += +(c[k].purchases || 0); o.proceeds += +(c[k].proceeds || 0); });
      });
      iapKids.push(h("div", { class: "grid2" }, [
        h("div", {}, [h("h3", { text: "By product" }), table([
          { label: "Store · product", get: function (r) { return r.k; } },
          { label: "Purchases", num: true, get: function (r) { return n(r.purchases); } },
          { label: "Refunds", num: true, get: function (r) { return n(r.refunds); } },
          { label: "≈£", num: true, get: function (r) { return n(r.money, 2); } },
        ], entries(prod, "purchases"))]),
        h("div", {}, [h("h3", { text: "By country" }), table([
          { label: "Country", get: function (r) { return regionName(r.k); } },
          { label: "Purchases", num: true, get: function (r) { return n(r.purchases); } },
        ], entries(ctry, "purchases").filter(function (r) { return r.purchases; }).slice(0, 25))]),
      ]));
    }
    parts.push(section("In-app purchases", "Stores publish sales once a day. App Store figures are net proceeds; Play's are gross charged.", iapKids,
      [badge("sales", sales, "App Store"), badge("play_sales", ps, "Play"), checked(live(sales) ? sales : ps)]));

    // Purchase funnel: what the app reports at each step, in order. Counts are
    // of events, not people (nothing identifies anyone), so a step can exceed
    // the one before it when someone repeats it.
    function stepTotal(key) {
      var st = (fn.steps || {}), out = { ios: 0, android: 0, all: 0 };
      Object.keys(st).forEach(function (k) {
        if (k === key || k.indexOf(key + ":") === 0) ["ios", "android", "all"].forEach(function (p) { out[p] += +(st[k][p] || 0); });
      });
      return out;
    }
    var fnKids = [sourceState(fn, "Funnel")];
    if (live(fn)) {
      var prev = null, top = Math.max.apply(null, FUNNEL.map(function (f) { return stepTotal(f[0]).all; }).concat([1]));
      var frows = FUNNEL.map(function (f) {
        var c = stepTotal(f[0]), r = { k: f[1], ios: c.ios, android: c.android, all: c.all, pct: prev ? (prev > 0 ? c.all / prev : null) : null, w: c.all / top };
        prev = c.all; return r;
      });
      fnKids.push(table([
        { label: "Step", get: function (r) { return r.k; } },
        // Width set through the style object, not a style attribute: the page's
        // Content-Security-Policy refuses inline style attributes.
        { label: "", get: function (r) { var bar = h("span", { class: "fbar" }); bar.style.width = Math.round(r.w * 100) + "%"; return bar; } },
        { label: "iPhone", num: true, get: function (r) { return n(r.ios); } },
        { label: "Android", num: true, get: function (r) { return n(r.android); } },
        { label: "Total", num: true, get: function (r) { return n(r.all); } },
        { label: "Of step above", num: true, get: function (r) { return r.pct == null ? "–" : n(r.pct * 100, 0) + "%"; } },
      ], frows, { empty: "No steps reported yet. Counts start with Wren 2.1.9." }));
      fnKids.push(h("h3", { text: "Along the way" }), table([
        { label: "Event", get: function (r) { return r.k; } },
        { label: "iPhone", num: true, get: function (r) { return n(r.ios); } },
        { label: "Android", num: true, get: function (r) { return n(r.android); } },
        { label: "Total", num: true, get: function (r) { return n(r.all); } },
      ], SIDE.map(function (s) { var c = stepTotal(s[0]); return { k: s[1], ios: c.ios, android: c.android, all: c.all }; })));
      var vers = Object.keys(fn.versions || {}).sort().reverse();
      if (vers.length) fnKids.push(h("p", { class: "muted note", text: "App versions reporting: " + vers.map(function (v) { return v + " (" + n(fn.versions[v].events) + ")"; }).join(", ") }));
    }
    parts.push(section("Purchase funnel", "Counts of events, not people: nothing identifies anyone, so one person opening the sheet twice counts twice.", fnKids,
      [badge("funnel", fn), checked(fn)]));

    // Revenue per campaign
    var rpc = [];
    if (live(meta)) meta.campaigns.forEach(function (c) { rpc.push({ k: "Meta · " + c.name, spend: c.spend, installs: c.installs, purchases: c.purchases, revenue: c.revenue }); });
    if (live(tt)) tt.campaigns.forEach(function (c) { rpc.push({ k: "TikTok · " + c.name, spend: c.spend, installs: c.installs, purchases: c.purchases, revenue: c.revenue }); });
    var appleRpc = live(apple) ? Object.keys(apple.purchase_campaigns || {}) : [];
    var rpcKids = [table([
      { label: "Campaign", get: function (r) { return r.k; } },
      { label: "Spend", num: true, get: function (r) { return gbp(r.spend); }, total: totalOf("spend", gbp) },
      { label: "Installs", num: true, get: function (r) { return n(r.installs); }, total: totalOf("installs") },
      { label: "Purchases", num: true, get: function (r) { return n(r.purchases); }, total: totalOf("purchases") },
      { label: "Revenue", num: true, get: function (r) { return gbp(r.revenue); }, total: totalOf("revenue", gbp) },
      { label: "Return", num: true, get: function (r) { return r.spend > 0 && r.revenue != null ? n(r.revenue / r.spend, 2) + "×" : "–"; } },
    ], rpc, { total: true, empty: "No campaigns with data in this range." })];
    if (appleRpc.length) {
      var acols = {};
      appleRpc.forEach(function (k) { Object.keys(apple.purchase_campaigns[k]).forEach(function (c) { acols[c] = 1; }); });
      rpcKids.push(h("h3", { text: "App Store purchases by campaign token (people who share analytics only)" }), table(
        [{ label: "Token", get: function (r) { return r.k; } }].concat(Object.keys(acols).map(function (c) { return { label: c, num: true, get: function (r) { return n(r[c], /USD|GBP|Proceeds|Sales/i.test(c) ? 2 : 0); } }; })),
        entries(apple.purchase_campaigns, Object.keys(acols)[0])));
    }
    if (anySales) {
      var attributed = rpc.reduce(function (t, r) { return t + (+r.revenue || 0); }, 0);
      rpcKids.push(h("p", { class: "muted note", text: "All in-app revenue in this range ≈" + gbp(iapMoney) + "; the ad platforms claim " + gbp(attributed) +
        ". The rest came from people the platforms could not link to an ad (no tracking consent, organic, or another source)." }));
    }
    parts.push(section("Revenue per campaign", "What each ad platform attributes to its campaigns, from the purchase events Wren's Meta and TikTok SDKs report. Platform-reported, so it may overlap and differs from Apple's net proceeds.", rpcKids,
      [badge("meta", meta, "Meta"), badge("tiktok", tt, "TikTok"), appleRpc.length ? badge("apple", apple, "App Store") : null]));

    // Who the ads reached: the platforms' own age and gender breakdowns. Ages are
    // on TikTok's brackets (Meta's 55-64 and 65+ are merged into 55+ server-side).
    if ((live(meta) && meta.audience) || (live(tt) && tt.audience)) {
      var AGES = ["13-17", "18-24", "25-34", "35-44", "45-54", "55+", "unknown"];
      var GENDERS = ["female", "male", "unknown"];
      var aud = function (by, keys) {
        var rows = {};
        keys.forEach(function (k) { rows[k] = { k: k, mi: 0, mc: 0, ti: 0, tc: 0, spend: 0 }; });
        [[live(meta) && meta.audience, "m"], [live(tt) && tt.audience, "t"]].forEach(function (x) {
          (x[0] || []).forEach(function (a) {
            var r = rows[a[by]]; if (!r) return;
            r[x[1] + "i"] += +a.impressions; r[x[1] + "c"] += +a.clicks; r.spend += +a.spend;
          });
        });
        var list = keys.map(function (k) { return rows[k]; }).filter(function (r) { return r.mi || r.ti; });
        var top = Math.max.apply(null, list.map(function (r) { return r.mc + r.tc; }).concat([1]));
        list.forEach(function (r) { r.w = (r.mc + r.tc) / top; });
        return list;
      };
      var label = { female: "Women", male: "Men", unknown: "Not stated" };
      var audCols = function (first, name) {
        return [
          { label: first, get: function (r) { return name ? name(r.k) : (r.k === "unknown" ? "Not stated" : r.k); } },
          { label: "", get: function (r) { var bar = h("span", { class: "fbar" }); bar.style.width = Math.round(r.w * 100) + "%"; return bar; } },
          { label: "Meta seen", num: true, get: function (r) { return n(r.mi); }, total: totalOf("mi") },
          { label: "Meta clicks", num: true, get: function (r) { return n(r.mc); }, total: totalOf("mc") },
          { label: "TikTok seen", num: true, get: function (r) { return n(r.ti); }, total: totalOf("ti") },
          { label: "TikTok clicks", num: true, get: function (r) { return n(r.tc); }, total: totalOf("tc") },
          { label: "Click rate", num: true, get: function (r) { var i = r.mi + r.ti; return i ? n(100 * (r.mc + r.tc) / i, 2) + "%" : "–"; } },
          { label: "Spend", num: true, get: function (r) { return gbp(r.spend); }, total: totalOf("spend", gbp) },
        ];
      };
      parts.push(section("Who the ads reached", "Age and gender as Meta and TikTok report them for their own users; Wren never learns either. Bars show each group's share of clicks. Meta's 55–64 and 65+ are merged to match TikTok's 55+.", [
        h("h3", { text: "By age" }), table(audCols("Age"), aud("age", AGES), { total: true }),
        h("h3", { text: "By gender" }), table(audCols("Gender", function (k) { return label[k] || k; }), aud("gender", GENDERS), { total: true }),
      ], [badge("meta", meta, "Meta"), badge("tiktok", tt, "TikTok"), checked(meta)]));
    }

    // Meta
    parts.push(section("Meta (Instagram)", "Spend, impressions and clicks are near real-time; installs arrive 1–3 days late through Apple.", [
      sourceState(meta, "Meta"),
      live(meta) ? table([
        { label: "Campaign", get: function (r) { return r.name; } },
        { label: "Status", get: function (r) { return pill(r.status); } },
        { label: "Budget", num: true, get: function (r) { return r.budget == null ? "–" : gbp(r.budget) + (/^daily/.test(r.budget_type) ? "/day" : "") + (/ad sets/.test(r.budget_type) ? " (ad sets)" : ""); } },
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
    ], [badge("meta", meta), badge("meta_installs", meta, "Installs"), checked(meta)]));

    // TikTok
    var ttKids = [sourceState(tt, "TikTok")];
    if (tt.configured === false) ttKids.push(h("p", { class: "muted", text: "Until TikTok approves API access, its traffic shows up below: /get/ visitors with tt-* tokens, and App Store downloads under the same campaign tokens." }));
    if (live(tt)) ttKids.push(table([
      { label: "Campaign", get: function (r) { return r.name; } },
      { label: tt.campaigns.some(function (c) { return c.status_inferred; }) ? "Delivery (from impressions)" : "Status", get: function (r) { return pill(r.status); } },
      { label: "Spend", num: true, get: function (r) { return gbp(r.spend); }, total: totalOf("spend", gbp) },
      { label: "Impressions", num: true, get: function (r) { return n(r.impressions); }, total: totalOf("impressions") },
      { label: "Clicks", num: true, get: function (r) { return n(r.clicks); }, total: totalOf("clicks") },
      { label: "Cost/click", num: true, get: function (r) { return r.cpc == null ? "–" : "£" + n(r.cpc, 3); } },
      { label: "Conversions", num: true, get: function (r) { return n(r.conversions); }, total: totalOf("conversions") },
    ], tt.campaigns, { total: true }));
    // Which languages each ad group's clicks come from (the viewer's TikTok app
    // language). An ad group with no language set takes whoever TikTok finds in
    // its countries, which on 10 Oct 2026 meant mostly Russian speakers in "Dutch".
    if (live(tt) && tt.adgroup_languages && tt.adgroup_languages.length) {
      var langLabel = function (k) { return k === "unknown" ? "Not stated" : langName(k); };
      ttKids.push(h("h3", { text: "Clicks by language, per ad group" }), table([
        { label: "Ad group", get: function (r) { return r.name.replace(/^Wren - (Short Form - Dubbed Audio - |TikTok - )/, ""); } },
        { label: "Clicks", num: true, get: function (r) { return n(r.clicks); }, total: totalOf("clicks") },
        { label: "Spend", num: true, get: function (r) { return gbp(r.spend); }, total: totalOf("spend", gbp) },
        { label: "Languages, by share of clicks", get: function (r) {
          var langs = Object.keys(r.languages).filter(function (k) { return r.languages[k].clicks > 0; });
          if (!r.clicks || !langs.length) return "–";
          var shown = langs.slice(0, 5).map(function (k) { var p = 100 * r.languages[k].clicks / r.clicks; return langLabel(k) + " " + (p < 1 ? "<1" : n(p)) + "%"; });
          return shown.join(" · ") + (langs.length > 5 ? " · +" + (langs.length - 5) + " more" : "");
        } },
      ], tt.adgroup_languages, { total: true }));
      ttKids.push(h("p", { class: "muted note", text: "The language each viewer's TikTok app is set to. Set an ad group's languages under Demographics → Languages in TikTok Ads Manager; with none set, it reaches every language in its countries." }));
    }
    parts.push(section("TikTok", "TikTok Promote (boosts made in the TikTok app) is not in TikTok's API, so it is not here.", ttKids,
      [badge("tiktok", tt), checked(tt)]));

    // Apple
    var appleKids = [sourceState(apple, "App Store Connect")];
    if (live(apple)) {
      if (apple.partial) appleKids.push(h("p", { class: "notice", text: "Still downloading Apple's report files. This fills in over the next minute." }));
      appleKids.push(barChart(dates, [{ name: "First-time downloads", cls: "s1", values: map(apple.daily, "first") }], n, "App Store first-time downloads per day", apple.latest_date));
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
    parts.push(section("App Store", "Apple hides campaigns with fewer than 5 downloads, and counts only people who share analytics.", appleKids,
      [badge("apple", apple), checked(apple)]));

    // Play
    var playKids = [sourceState(play, "Google Play")];
    if (live(play)) {
      playKids.push(barChart(dates, [{ name: "Installs", cls: "s1", values: map(play.daily, "installs") }], n, "Google Play installs per day", play.latest_date));
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
    parts.push(section("Google Play", "The traffic-source (UTM) file is published later than installs; its own date is in its heading.", playKids,
      [badge("play", play, "Installs"), live(play) && play.sources_latest ? badge("play", play, "Sources", play.sources_latest) : null, checked(play)]));

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
      if (gt.opened_in) getKids.push(h("p", { class: "muted note", text: GET_SOURCES_NOTE }), getSources(gt.opened_in, gt.countries, gt.languages));
    }
    parts.push(section("/get/ campaign links", "TikTok's in-app browser loads links before anyone taps, so read this as device mix, not a click count.", getKids,
      [badge("get", gt), checked(gt)]));

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
    parts.push(section("Install reports from Apple (SKAdNetwork)", "Copies of the postbacks Apple sends ad networks, listed by when they arrived. Apple holds each one back on a timer, so a report received today is about an install from yesterday or the day before.", pbKids,
      [badge("postbacks", pb), checked(pb)]));

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
    parts.push(section("Website (wren.spencerfields.com)", "Only visitors who accepted cookies are counted.", gaKids,
      [badge("ga4", ga, "Daily"), badge("ga4_realtime", rt, "Right now"), checked(ga)]));

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

  // The "Real time" tab asks every 5 seconds: it reads only this server's own
  // small files (Google's live count is cached for a minute), so it is cheap.
  // A hidden browser tab asks once a minute instead, and keeps its baseline.
  function loadLive() {
    clearTimeout(timer);
    fetch("api.php?live=1", { credentials: "same-origin" })
      .then(function (r) {
        if (r.status === 401) { location.reload(); throw new Error("signed out"); }
        return r.json();
      })
      .then(function (d) {
        if (days !== 0) return; // the tab was left while this was in flight
        renderLive(d);
        document.getElementById("updated").textContent = "Live · " + new Date().toLocaleTimeString("en-GB");
        timer = setTimeout(load, document.hidden ? 60000 : 5000);
      })
      .catch(function () {
        document.getElementById("updated").textContent = "Update failed";
        timer = setTimeout(load, 15000);
      });
  }

  function load(refresh) {
    if (days === 0) return loadLive();
    clearTimeout(timer);
    document.getElementById("updated").textContent = "Updating…";
    fetch("api.php?days=" + days + (refresh ? "&refresh=1" : ""), { credentials: "same-origin" })
      .then(function (r) {
        if (r.status === 401) { location.reload(); throw new Error("signed out"); }
        return r.json();
      })
      .then(function (d) {
        if (days === 0) return; // "Real time" was opened while this was in flight
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
      liveBase = null; // opening "Real time", or leaving it, starts its counts again
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
    resizeTimer = setTimeout(function () { if (lastData && days !== 0) render(lastData); }, 200);
  });
  load(false);
})();
