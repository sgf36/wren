"""Find a newer stable Meta iOS SDK and stage the bump for review.

Run by .github/workflows/meta-sdk-update.yml (weekly). Wren pins Meta's SDK
EXACTLY, in two places that must agree: the Swift package and the CocoaPods
fallback. This never floats the pin. It proposes a new exact pin, with the
SDK's privacy manifests compared, because those manifests are what the App
Store privacy label was built from (4 Oct 2026): a release that starts
collecting a new data type must not reach users under the old label.

Only releases Meta marks stable count: on 4 Oct 2026 v18.0.2 was a
pre-release, and main already named a 19.0.0 that had no tag.

    python meta_sdk_update.py check            # prints current/latest, writes GITHUB_OUTPUT
    python meta_sdk_update.py apply <version>  # rewrites both pins
    python meta_sdk_update.py report <old> <new> > body.md
"""
import json
import os
import plistlib
import re
import subprocess
import sys
import urllib.request

REPO = "facebook/facebook-ios-sdk"
PACKAGE = "packages/meta_app_events/ios/meta_app_events/Package.swift"
PODSPEC = "packages/meta_app_events/ios/meta_app_events.podspec"
PKG_RE = re.compile(r'(\.package\(url: "https://github\.com/facebook/facebook-ios-sdk", exact: ")([0-9.]+)(")')
POD_RE = re.compile(r"(s\.dependency 'FBSDKCoreKit', ')([0-9.]+)(')")
# The manifests Wren links: FacebookCore pulls in FacebookAEM and FacebookBasics.
MANIFESTS = ["Sources/FacebookCore/Resources/PrivacyInfo.xcprivacy",
             "Sources/FacebookAEM/Resources/PrivacyInfo.xcprivacy",
             "Sources/FacebookBasics/Resources/PrivacyInfo.xcprivacy"]
UA = {"User-Agent": "wren-meta-sdk-update", "Accept": "application/vnd.github+json"}


def http(url, raw=False):
    headers = dict(UA)
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
    if raw:
        headers["Accept"] = "application/vnd.github.raw"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as r:
        return r.read()


def vtuple(v):
    return tuple(int(x) for x in v.split("."))


def pinned():
    pkg = PKG_RE.search(open(PACKAGE, encoding="utf-8").read())
    pod = POD_RE.search(open(PODSPEC, encoding="utf-8").read())
    if not pkg or not pod:
        sys.exit("cannot find the SDK pin in %s or %s" % (PACKAGE, PODSPEC))
    if pkg.group(2) != pod.group(2):
        sys.exit("pins disagree: Package.swift %s, podspec %s" % (pkg.group(2), pod.group(2)))
    return pkg.group(2)


def latest_stable():
    releases = json.loads(http("https://api.github.com/repos/%s/releases?per_page=30" % REPO))
    tags = [r["tag_name"].lstrip("v") for r in releases
            if not r["prerelease"] and not r["draft"] and re.fullmatch(r"v?\d+\.\d+\.\d+", r["tag_name"])]
    return max(tags, key=vtuple)


def manifest(version, path):
    try:
        data = http("https://api.github.com/repos/%s/contents/%s?ref=v%s" % (REPO, path, version), raw=True)
    except Exception:
        return None
    d = plistlib.loads(data)
    rows = set()
    for c in d.get("NSPrivacyCollectedDataTypes", []):
        rows.add("collects %s; linked=%s; tracking=%s; purposes=%s" % (
            c["NSPrivacyCollectedDataType"].replace("NSPrivacyCollectedDataType", ""),
            c["NSPrivacyCollectedDataTypeLinked"], c["NSPrivacyCollectedDataTypeTracking"],
            ",".join(sorted(p.replace("NSPrivacyCollectedDataTypePurpose", "")
                            for p in c["NSPrivacyCollectedDataTypePurposes"]))))
    rows.add("tracking=%s" % d.get("NSPrivacyTracking"))
    for dom in d.get("NSPrivacyTrackingDomains", []) or []:
        rows.add("tracking domain %s" % dom)
    for a in d.get("NSPrivacyAccessedAPITypes", []) or []:
        rows.add("required-reason API %s (%s)" % (
            a["NSPrivacyAccessedAPIType"].replace("NSPrivacyAccessedAPICategory", ""),
            ",".join(sorted(a.get("NSPrivacyAccessedAPITypeReasons", [])))))
    return rows


def compare(old, new):
    changed, lines = False, []
    for path in MANIFESTS:
        a, b = manifest(old, path), manifest(new, path)
        name = path.split("/")[1]
        # A manifest that could not be read is never "unchanged": two failed
        # fetches would otherwise compare equal and report a false all-clear.
        if a is None or b is None:
            changed = True
            lines.append("- **%s**: COULD NOT COMPARE (manifest unreadable in %s); check by hand" % (
                name, " and ".join("v%s" % v for v, m in ((old, a), (new, b)) if m is None)))
            continue
        if a == b:
            lines.append("- **%s**: unchanged" % name)
            continue
        changed = True
        lines.append("- **%s**: CHANGED" % name)
        lines += ["  - removed: %s" % r for r in sorted(a - b)]
        lines += ["  - added: %s" % r for r in sorted(b - a)]
    return changed, lines


def main():
    cmd = sys.argv[1]
    if cmd == "check":
        cur, new = pinned(), latest_stable()
        newer = vtuple(new) > vtuple(cur)
        print("pinned %s, latest stable %s, update %s" % (cur, new, "needed" if newer else "not needed"))
        out = os.environ.get("GITHUB_OUTPUT")
        if out:
            with open(out, "a") as f:
                f.write("current=%s\nlatest=%s\nnewer=%s\n" % (cur, new, str(newer).lower()))
    elif cmd == "apply":
        v = sys.argv[2]
        for path, rx in ((PACKAGE, PKG_RE), (PODSPEC, POD_RE)):
            s = open(path, encoding="utf-8", newline="").read()
            s2, n = rx.subn(lambda m: m.group(1) + v + m.group(3), s)
            if n != 1:
                sys.exit("expected one pin in %s, found %d" % (path, n))
            open(path, "w", encoding="utf-8", newline="").write(s2)
        print("pinned %s in both files" % v)
    elif cmd == "report":
        old, new = sys.argv[2], sys.argv[3]
        changed, lines = compare(old, new)
        major = vtuple(new)[0] != vtuple(old)[0]
        out = []
        if changed:
            out += ["> [!CAUTION]",
                    "> **Meta's privacy manifest changed.** Do not merge until the App Store privacy "
                    "label (and, if needed, the privacy policy) has been checked against the changes below.", ""]
        if major:
            out += ["> [!WARNING]",
                    "> **Major version (%s to %s).** Expect API changes; CI's iOS build is the test." % (old, new), ""]
        out += ["Bumps Meta's iOS SDK from **%s** to **%s** (latest stable release)." % (old, new), "",
                "Release notes: https://github.com/%s/releases/tag/v%s" % (REPO, new), "",
                "### Privacy manifests (what the App Store label is built from)", ""] + lines + [
                "", "### Before merging",
                "- [ ] CI `Build iOS` is green on this branch",
                "- [ ] Privacy manifests unchanged, or the App Store label updated to match",
                "", "Opened by `.github/workflows/meta-sdk-update.yml`. The pin stays exact; this only proposes the next one."]
        print("\n".join(out))
        out_env = os.environ.get("GITHUB_OUTPUT")
        if out_env:
            with open(out_env, "a") as f:
                f.write("privacy_changed=%s\nmajor=%s\n" % (str(changed).lower(), str(major).lower()))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
