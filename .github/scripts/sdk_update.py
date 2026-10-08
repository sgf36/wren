"""Find a newer stable release of an advertising SDK and stage the bump for review.

Run by .github/workflows/sdk-update.yml (weekly), once per SDK. Wren pins each
SDK EXACTLY, in two places that must agree: the Swift package and the
CocoaPods fallback. This never floats a pin. It proposes a new exact pin, with
the SDK's privacy manifests compared, because the App Store privacy label was
built from what these SDKs collect: a release that starts collecting a new data
type must not reach users under the old label.

Two SDKs, from 8 Oct 2026:

  meta    facebook/facebook-ios-sdk, tags "v18.1.1". Only releases Meta marks
          stable count: on 4 Oct 2026 v18.0.2 was a pre-release, and main
          already named a 19.0.0 that had no tag.
  tiktok  tiktok/tiktok-business-ios-sdk, tags "1.7.2". Its privacy manifest
          declares almost nothing although the SDK reads the advertising
          identifier, the vendor identifier, App Store purchases and crashes,
          so for TikTok the manifest diff alone would report a false all-clear.
          The report also compares a scan of the SDK's source for those APIs.

    python sdk_update.py check  <sdk>               # prints current/latest, writes GITHUB_OUTPUT
    python sdk_update.py apply  <sdk> <version>     # rewrites both pins
    python sdk_update.py report <sdk> <old> <new> > body.md
"""
import io
import json
import os
import plistlib
import re
import sys
import tarfile
import urllib.request

PACKAGE = "packages/meta_app_events/ios/meta_app_events/Package.swift"
PODSPEC = "packages/meta_app_events/ios/meta_app_events.podspec"

SDKS = {
    "meta": {
        "name": "Meta's iOS SDK",
        "repo": "facebook/facebook-ios-sdk",
        "tag": "v{}",
        "pkg": re.compile(r'(\.package\(url: "https://github\.com/facebook/facebook-ios-sdk", exact: ")([0-9.]+)(")'),
        "pod": re.compile(r"(s\.dependency 'FBSDKCoreKit', ')([0-9.]+)(')"),
        # The manifests Wren links: FacebookCore pulls in FacebookAEM and FacebookBasics.
        "manifests": ["Sources/FacebookCore/Resources/PrivacyInfo.xcprivacy",
                      "Sources/FacebookAEM/Resources/PrivacyInfo.xcprivacy",
                      "Sources/FacebookBasics/Resources/PrivacyInfo.xcprivacy"],
        "scan": False,
    },
    "tiktok": {
        "name": "TikTok's App Events SDK",
        "repo": "tiktok/tiktok-business-ios-sdk",
        "tag": "{}",
        "pkg": re.compile(r'(\.package\(url: "https://github\.com/tiktok/tiktok-business-ios-sdk", exact: ")([0-9.]+)(")'),
        "pod": re.compile(r"(s\.dependency 'TikTokBusinessSDK', ')([0-9.]+)(')"),
        "manifests": ["PrivacyInfo.xcprivacy"],
        "scan": True,
    },
}

# What the App Store label for TikTok rests on (decided 8 Oct 2026, from the
# 1.7.2 source): each pattern is a kind of data the SDK can read. A pattern
# appearing or disappearing between versions is what a reviewer must see.
SIGNALS = {
    "advertising identifier (IDFA)": r"advertisingIdentifier",
    "vendor identifier (IDFV)": r"identifierForVendor",
    "App Store purchases, StoreKit 1": r"SKPaymentQueue|SKPaymentTransaction",
    "App Store purchases, StoreKit 2": r"Transaction\.(updates|currentEntitlements|all)|StoreKit2|sk2",
    "crash reports": r"TTSDKCrash|crash_monitor",
    "IP address": r"getifaddrs|IP_ADDR_IPv4",
    "SKAdNetwork / AdAttributionKit": r"SKAdNetwork|AdAttributionKit",
    "location": r"CLLocationManager|CoreLocation",
    "contacts": r"CNContactStore|Contacts/Contacts",
    "photos": r"PHPhotoLibrary|PHAsset",
    "pasteboard": r"UIPasteboard",
    "user email or phone": r"\bemail\b|phone_number|phoneNumber",
}

UA = {"User-Agent": "wren-sdk-update", "Accept": "application/vnd.github+json"}


def http(url, raw=False):
    headers = dict(UA)
    if os.environ.get("GITHUB_TOKEN") and "api.github.com" in url:
        headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
    if raw:
        headers["Accept"] = "application/vnd.github.raw"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as r:
        return r.read()


def vtuple(v):
    return tuple(int(x) for x in v.split("."))


def pinned(sdk):
    c = SDKS[sdk]
    pkg = c["pkg"].search(open(PACKAGE, encoding="utf-8").read())
    pod = c["pod"].search(open(PODSPEC, encoding="utf-8").read())
    if not pkg or not pod:
        sys.exit("cannot find the %s pin in %s or %s" % (sdk, PACKAGE, PODSPEC))
    if pkg.group(2) != pod.group(2):
        sys.exit("%s pins disagree: Package.swift %s, podspec %s" % (sdk, pkg.group(2), pod.group(2)))
    return pkg.group(2)


def latest_stable(sdk):
    releases = json.loads(http("https://api.github.com/repos/%s/releases?per_page=30" % SDKS[sdk]["repo"]))
    tags = [r["tag_name"].lstrip("v") for r in releases
            if not r["prerelease"] and not r["draft"] and re.fullmatch(r"v?\d+\.\d+\.\d+", r["tag_name"])]
    return max(tags, key=vtuple)


def manifest(sdk, version, path):
    c = SDKS[sdk]
    try:
        data = http("https://api.github.com/repos/%s/contents/%s?ref=%s" % (
            c["repo"], path, c["tag"].format(version)), raw=True)
    except Exception:
        return None
    d = plistlib.loads(data)
    rows = set()
    for t in d.get("NSPrivacyCollectedDataTypes", []) or []:
        rows.add("collects %s; linked=%s; tracking=%s; purposes=%s" % (
            t["NSPrivacyCollectedDataType"].replace("NSPrivacyCollectedDataType", ""),
            t["NSPrivacyCollectedDataTypeLinked"], t["NSPrivacyCollectedDataTypeTracking"],
            ",".join(sorted(p.replace("NSPrivacyCollectedDataTypePurpose", "")
                            for p in t["NSPrivacyCollectedDataTypePurposes"]))))
    rows.add("tracking=%s" % d.get("NSPrivacyTracking"))
    for dom in d.get("NSPrivacyTrackingDomains", []) or []:
        rows.add("tracking domain %s" % dom)
    for a in d.get("NSPrivacyAccessedAPITypes", []) or []:
        rows.add("required-reason API %s (%s)" % (
            a["NSPrivacyAccessedAPIType"].replace("NSPrivacyAccessedAPICategory", ""),
            ",".join(sorted(a.get("NSPrivacyAccessedAPITypeReasons", [])))))
    return rows


def compare_manifests(sdk, old, new):
    changed, lines = False, []
    for path in SDKS[sdk]["manifests"]:
        a, b = manifest(sdk, old, path), manifest(sdk, new, path)
        name = path.split("/")[1] if "/" in path else path
        # A manifest that could not be read is never "unchanged": two failed
        # fetches would otherwise compare equal and report a false all-clear.
        if a is None or b is None:
            changed = True
            lines.append("- **%s**: COULD NOT COMPARE (manifest unreadable in %s); check by hand" % (
                name, " and ".join(v for v, m in ((old, a), (new, b)) if m is None)))
            continue
        if a == b:
            lines.append("- **%s**: unchanged" % name)
            continue
        changed = True
        lines.append("- **%s**: CHANGED" % name)
        lines += ["  - removed: %s" % r for r in sorted(a - b)]
        lines += ["  - added: %s" % r for r in sorted(b - a)]
    return changed, lines


def scan(sdk, version):
    """Which SIGNALS appear anywhere in the SDK's own source at this version."""
    c = SDKS[sdk]
    try:
        blob = http("https://codeload.github.com/%s/tar.gz/refs/tags/%s" % (c["repo"], c["tag"].format(version)))
    except Exception:
        return None
    found = {k: 0 for k in SIGNALS}
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
        for m in tar.getmembers():
            n = m.name.lower()
            if not m.isfile() or not n.endswith((".m", ".h", ".swift", ".mm", ".c")):
                continue
            # The SDK's own code only: its sample app and tests are not linked into Wren.
            if "testapp" in n or "/tests" in n or "tests/" in n:
                continue
            text = tar.extractfile(m).read().decode("utf-8", "replace")
            for k, rx in SIGNALS.items():
                found[k] += len(re.findall(rx, text))
    return found


def compare_scan(sdk, old, new):
    a, b = scan(sdk, old), scan(sdk, new)
    if a is None or b is None:
        return True, ["- COULD NOT SCAN (source unreadable for %s); check by hand" % (
            " and ".join(v for v, s in ((old, a), (new, b)) if s is None))]
    changed, lines = False, []
    for k in SIGNALS:
        was, now = a[k] > 0, b[k] > 0
        if was != now:
            changed = True
            lines.append("- **%s**: %s" % (k, "NEWLY PRESENT" if now else "no longer present"))
        else:
            lines.append("- %s: %s (%d -> %d mentions)" % (k, "present" if now else "absent", a[k], b[k]))
    return changed, lines


def main():
    cmd, sdk = sys.argv[1], sys.argv[2]
    if sdk not in SDKS:
        sys.exit("unknown sdk %r; one of %s" % (sdk, ", ".join(SDKS)))
    c = SDKS[sdk]
    out_env = os.environ.get("GITHUB_OUTPUT")
    if cmd == "check":
        cur, new = pinned(sdk), latest_stable(sdk)
        newer = vtuple(new) > vtuple(cur)
        print("%s: pinned %s, latest stable %s, update %s" % (sdk, cur, new, "needed" if newer else "not needed"))
        if out_env:
            with open(out_env, "a") as f:
                f.write("current=%s\nlatest=%s\nnewer=%s\n" % (cur, new, str(newer).lower()))
    elif cmd == "apply":
        v = sys.argv[3]
        for path, rx in ((PACKAGE, c["pkg"]), (PODSPEC, c["pod"])):
            s = open(path, encoding="utf-8", newline="").read()
            s2, n = rx.subn(lambda m: m.group(1) + v + m.group(3), s)
            if n != 1:
                sys.exit("expected one %s pin in %s, found %d" % (sdk, path, n))
            open(path, "w", encoding="utf-8", newline="").write(s2)
        print("%s pinned %s in both files" % (sdk, v))
    elif cmd == "report":
        old, new = sys.argv[3], sys.argv[4]
        changed, lines = compare_manifests(sdk, old, new)
        scan_changed, scan_lines = compare_scan(sdk, old, new) if c["scan"] else (False, [])
        major = vtuple(new)[0] != vtuple(old)[0]
        out = []
        if changed or scan_changed:
            out += ["> [!CAUTION]",
                    "> **What %s collects may have changed.** Do not merge until the App Store privacy "
                    "label (and, if needed, the privacy policy) has been checked against the changes below." % c["name"], ""]
        if major:
            out += ["> [!WARNING]",
                    "> **Major version (%s to %s).** Expect API changes; CI's iOS build is the test." % (old, new), ""]
        out += ["Bumps %s from **%s** to **%s** (latest stable release)." % (c["name"], old, new), "",
                "Release notes: https://github.com/%s/releases/tag/%s" % (c["repo"], c["tag"].format(new)), "",
                "### Privacy manifests", ""] + lines
        if c["scan"]:
            out += ["", "### What the SDK's source reads",
                    "",
                    "TikTok's manifest declares almost nothing, so the label for it was built from what the code "
                    "does. These are the data-reading APIs found in the SDK's own source (sample app and tests "
                    "excluded); any line marked NEWLY PRESENT needs the label checked.", ""] + scan_lines
        out += ["", "### Before merging",
                "- [ ] CI `Build iOS` is green on this branch",
                "- [ ] Nothing above changed, or the App Store label and privacy policy updated to match",
                "", "Opened by `.github/workflows/sdk-update.yml`. The pin stays exact; this only proposes the next one."]
        print("\n".join(out))
        if out_env:
            with open(out_env, "a") as f:
                f.write("privacy_changed=%s\nmajor=%s\n" % (str(changed or scan_changed).lower(), str(major).lower()))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
