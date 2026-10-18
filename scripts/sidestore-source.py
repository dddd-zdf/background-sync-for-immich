#!/usr/bin/env python3
"""Writes the SideStore/AltStore source for a release: sidestore-source.py <tag> <ipa> <notes-file> <out>.

Published as a release asset, so the source URL is always
https://github.com/<repo>/releases/latest/download/source.json
"""
import datetime, json, os, sys

tag, ipa, notes_file, out = sys.argv[1:5]
repo = os.environ.get("GITHUB_REPOSITORY", "dddd-zdf/immich-backup")
version = tag.lstrip("v")
raw = f"https://raw.githubusercontent.com/{repo}/main"
notes = open(notes_file, encoding="utf-8").read().strip()

source = {
    "name": "Immich Sync",
    "identifier": "io.github.dddd-zdf.immich-sync",
    "subtitle": "Two-way iPhone Photos sync for Immich",
    "website": f"https://github.com/{repo}",
    "iconURL": f"{raw}/App/Assets.xcassets/AppIcon.appiconset/icon.png",
    "tintColor": "#4250AF",
    "apps": [{
        "name": "Immich Sync",
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
        }],
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
