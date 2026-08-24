"""Generate sitemap.xml from what is actually on disk.

    python web/sitemap.py            # rewrite web/sitemap.xml
    python web/sitemap.py --check    # exit 1 if it is out of date, change nothing

The hand-written sitemap this replaces listed four URLs while the site served
96. Fifteen translations and the Apps page — the only page that carried a
download link — were never declared to any search engine. Nothing errors when a
sitemap is short: it simply under-reports, indefinitely, which is why this is
generated rather than maintained.

Run `--check` in CI so a new page or a new language cannot be added without the
sitemap following it.
"""
import argparse
import datetime
import pathlib
import sys

ROOT = pathlib.Path(__file__).parent
BASE = "https://wren.spencerfields.com"

# Priority and change frequency by page, highest first. A page not listed here
# is still included, at the default — a new page is under-ranked, never dropped.
PAGES = {
    "index.html":           ("1.0", "weekly"),
    "apps.html":            ("0.9", "monthly"),
    "support.html":         ("0.8", "monthly"),
    "privacy.html":         ("0.5", "yearly"),
    "android-privacy.html": ("0.5", "yearly"),
    "terms.html":           ("0.5", "yearly"),
}
DEFAULT = ("0.5", "monthly")


def url_for(path: pathlib.Path) -> str:
    rel = path.relative_to(ROOT).as_posix()
    # A directory index is addressed by the directory, not by the filename, so
    # the canonical form matches the <link rel="canonical"> the pages carry.
    if rel == "index.html":
        return BASE + "/"
    if rel.endswith("/index.html"):
        return f"{BASE}/{rel[:-len('index.html')]}"
    return f"{BASE}/{rel}"


def entries():
    out = []
    for path in sorted(ROOT.glob("*.html")) + sorted(ROOT.glob("*/*.html")):
        priority, freq = PAGES.get(path.name, DEFAULT)
        # A translation ranks just below its English original.
        if path.parent != ROOT:
            priority = f"{max(float(priority) - 0.1, 0.1):.1f}"
        lastmod = datetime.date.fromtimestamp(path.stat().st_mtime).isoformat()
        out.append((url_for(path), lastmod, freq, priority))
    return sorted(out, key=lambda e: (-float(e[3]), e[0]))


def render() -> str:
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    for loc, lastmod, freq, priority in entries():
        lines += ["  <url>",
                  f"    <loc>{loc}</loc>",
                  f"    <lastmod>{lastmod}</lastmod>",
                  f"    <changefreq>{freq}</changefreq>",
                  f"    <priority>{priority}</priority>",
                  "  </url>"]
    lines.append("</urlset>")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="report staleness without writing")
    args = ap.parse_args()

    target = ROOT / "sitemap.xml"
    fresh = render()

    if args.check:
        current = target.read_text(encoding="utf-8") if target.exists() else ""
        if current == fresh:
            print(f"  sitemap.xml is current, {len(entries())} URLs")
            return 0
        print("  sitemap.xml is STALE — run: python web/sitemap.py")
        return 1

    target.write_text(fresh, encoding="utf-8")
    print(f"  wrote {target} — {len(entries())} URLs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
