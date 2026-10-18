#!/usr/bin/env python3
"""Writes the SideStore/AltStore source for a release: sidestore-source.py <tag> <ipa> <notes-file> <out>.

Published as a release asset, so the source URL is always
https://github.com/<repo>/releases/latest/download/source.json
Lists this release first, then every earlier release that has an IPA (read with `gh`).
"""
import datetime, json, os, subprocess, sys

tag, ipa, notes_file, out = sys.argv[1:5]
repo = os.environ.get("GITHUB_REPOSITORY", "dddd-zdf/background-sync-for-immich")
version = tag.lstrip("v")
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
        if r["tag_name"] == tag or r.get("draft") or not ipa_assets:
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
    "name": "Background Sync for Immich",
    "identifier": "io.github.dddd-zdf.background-sync-for-immich",
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
            "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "localizedDescription": notes,
            "downloadURL": f"https://github.com/{repo}/releases/download/{tag}/{os.path.basename(ipa)}",
            "size": os.path.getsize(ipa),
            "minOSVersion": "27.0",
        }] + earlier_versions(),
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
