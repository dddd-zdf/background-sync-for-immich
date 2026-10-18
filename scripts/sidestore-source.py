#!/usr/bin/env python3
"""Writes a SideStore/AltStore source: sidestore-source.py <stable|nightly> <tag> <ipa> <notes-file> <out>.

Published as a release asset, so the URLs never change:
- stable:  https://github.com/<repo>/releases/latest/download/source.json
  (this release first, then every earlier non-prerelease release with an IPA, read with `gh`)
- nightly: https://github.com/<repo>/releases/download/nightly/source.json
  (just the newest build from main)
Both use the app's real bundle ID, so switching channels is an ordinary update. BUILD_NUMBER is the
IPA's CFBundleVersion, which tells builds of the same version apart.
"""
import datetime, json, os, subprocess, sys

channel, tag, ipa, notes_file, out = sys.argv[1:6]
nightly = channel == "nightly"
build = os.environ.get("BUILD_NUMBER", "1")
repo = os.environ.get("GITHUB_REPOSITORY", "dddd-zdf/background-sync-for-immich")
version = os.environ.get("APP_VERSION") or tag.lstrip("v")
raw = f"https://raw.githubusercontent.com/{repo}/main"
notes = open(notes_file, encoding="utf-8").read().strip()


def earlier_versions():
    try:
        out = subprocess.run(["gh", "api", f"repos/{repo}/releases", "--paginate"],
                             capture_output=True, text=True, check=True).stdout
        releases = json.loads(out)
    except Exception as e:  # no gh or no access: just this version
        print(f"earlier releases not listed: {e}", file=sys.stderr)
        return []
    versions = []
    for r in releases:
        ipa_assets = [a for a in r.get("assets", []) if a["name"].endswith(".ipa")]
        if r["tag_name"] == tag or r.get("draft") or r.get("prerelease") or not ipa_assets:
            continue
        versions.append({
            "version": r["tag_name"].lstrip("v"),
            "date": r.get("published_at") or r["created_at"],
            "localizedDescription": (r.get("body") or "").strip(),
            "downloadURL": ipa_assets[0]["browser_download_url"],
            "size": ipa_assets[0]["size"],
            "minOSVersion": "27.0",
        })
    return versions

source = {
    "name": "Background Sync for Immich" + (" (nightly)" if nightly else ""),
    "identifier": "io.github.dddd-zdf.background-sync-for-immich" + (".nightly" if nightly else ""),
    "subtitle": "Two-way iPhone Photos sync for Immich",
    "website": f"https://github.com/{repo}",
    "iconURL": f"{raw}/App/Assets.xcassets/AppIcon.appiconset/icon.png",
    "tintColor": "#4250AF",
    "apps": [{
        "name": "Background Sync for Immich",
        "bundleIdentifier": "com.difei.immichbackup",
        "developerName": "dddd-zdf",
        "subtitle": "Background upload and two-way sync with your Immich server",
        "localizedDescription": (
            "Keeps your iPhone's Photos library and your own Immich server in sync, in the background: "
            "new photos upload on their own, edits sync, and deletes go both ways (each direction can be "
            "turned off). Needs iOS 27, the patched SideStore that can sign its extension, and a small "
            f"proxy next to Immich. Setup: https://github.com/{repo}#readme"
        ),
        "iconURL": f"{raw}/App/Assets.xcassets/AppIcon.appiconset/icon.png",
        "tintColor": "#4250AF",
        "category": "photo-video",
        "versions": [{
            "version": version,
            "buildVersion": build,
            "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "localizedDescription": notes,
            "downloadURL": f"https://github.com/{repo}/releases/download/{tag}/{os.path.basename(ipa)}",
            "size": os.path.getsize(ipa),
            "minOSVersion": "27.0",
        }] + ([] if nightly else earlier_versions()),
        "appPermissions": {
            "entitlements": ["com.apple.security.application-groups"],
            "privacy": {
                "NSPhotoLibraryUsageDescription": "Uploads new photos to your Immich server and syncs deletions.",
            },
        },
    }],
    "news": [],
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(source, f, indent=2, ensure_ascii=False)
