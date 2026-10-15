# Changelog

## 0.2.0 (2026-10-15): full uploader

- Live Photos: the video uploads first, then the photo with its Immich ID, so Immich pairs them.
- Backlog: pick a "Photos taken since" date (default: when automatic backup was turned on).
  Photos from the last day go first, then the backlog oldest first.
- Edited photos replace their old version in Immich: the proxy copies albums, shared links and
  stack to the new asset, then moves the old one to Immich's trash. An edit is detected by a change
  in the photo's adjustment data, not just its modification date (favorites, albums and Photos'
  own analysis change that too). Photos uploaded by 0.1.x count as unedited from now on.
- Status screen: last upload, uploading, waiting, backed up, failed (with reasons and Retry all),
  Wi-Fi only toggle (set per upload request; jobs already queued keep their setting). Log kept.
- Edited renders upload as IMG_1234.jpg instead of FullSizeRender.jpg.
- Proxy: new `X-Replace-Asset-Id` request header and `X-Immich-Replaced` response header
  (deployed on `home` 2026-10-15).
- Who must act: the user installs the new IPA over the old one in SideStore and adds `asset.copy` and
  `asset.delete` to the Immich API key's permissions (or makes a new key with them).

## 0.1.2 (2026-10-15)

- Phase 0 verified on the phone: background uploads reach Immich with the app closed and after a
  force-quit (about 2 minutes after the photo).
- Fix: the test photo and automatic backup could queue the same photo twice in one run.
- CI builds one IPA (`ImmichBackup-<version>.ipa`); the `PlugIns/` variant is gone (iOS rejects it).
- Who must act: nobody (optional update).

## 0.1.1 (2026-10-15)

- Fix: the extension stayed stopped after iOS sent willTerminate but reused the process, so later
  runs silently queued nothing. Every run now logs its start.
- Test upload button re-enables the extension so iOS runs it right away (a settings flag is not a
  photo library change, so iOS never woke the extension for it).
- Who must act: the user installs the new IPA over the old one in SideStore.

## 0.1.0 (2026-10-14): Phase 0 test build

- App + iOS 27 PhotoKit upload extension with fixed bundle IDs; diagnostics screen and in-app log.
- Test upload (newest photo) and automatic backup of photos taken after it's turned on.
- Go proxy deployed on `home`, Caddy route `/api/assets/background`.
- CI builds two IPA layouts (`Extensions/` and `PlugIns/`) to test SideStore signing.
- Official SideStore can't sign ExtensionKit extensions and the `PlugIns/` workaround fails on iOS;
  patched SideStore built from private repo dddd-zdf/sidestore-extfix.
- Who must act: the user installs the patched SideStore, then the standard IPA, and creates an Immich API key.
