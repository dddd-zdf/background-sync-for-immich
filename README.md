# Immich Backup

iCloud-style background backup from an iPhone to Immich. It uses the iOS 27 PhotoKit
background upload extension, which iOS runs on its own schedule whether or not the
app is open. The official Immich app stays the viewer; turn its own backup off.

```
iPhone: PhotoKit runs UploadExtension -> raw POST /api/assets/background
  -> Caddy on home -> immich-backup-proxy (127.0.0.1:2284) -> multipart POST /api/assets -> Immich
```

- `App/`: SwiftUI host app (settings, enable the extension, status, log).
- `UploadExtension/`: PhotoKit extension; queues upload jobs, records results.
- `Shared/`: app group lookup, settings, log, upload state (both targets).
- `proxy/`: Go service; PhotoKit can only send the raw file, Immich only takes multipart.
- `project.yml`: XcodeGen spec. No Mac needed: CI (`xcode-27` runner) builds unsigned IPAs.

## Fixed identifiers (do not change)

Free Apple account: every new bundle ID costs an App ID (10 per week).

| What | ID |
|---|---|
| App | `com.difei.immichbackup` |
| Extension | `com.difei.immichbackup.upload` |
| App group | `group.com.difei.immichbackup` (SideStore renames it `...<TEAMID>`; the app reads the real one from `embedded.mobileprovision`) |

## Build and install

1. Push to `main` (or run the "iOS build" workflow). The `ipa-N` artifact has `ImmichBackup-<version>.ipa`.
2. Install it with the patched SideStore (below); official SideStore can't sign the extension.
   Updating over an existing install keeps settings and upload state.
3. In the app: server URL and API key (Immich: Account settings > API keys, permissions
   `asset.upload` and `user.read`), full Photos access, turn on the extension, then
   "Back up new photos automatically" (covers photos taken from that moment on).

Verified 2026-10-15 on the author's iPhone (iOS 27, free account, SideStore 0.7.0-extfix.2): photos
reach Immich about 2 minutes after they're taken, with the app closed and after a force-quit.

## How iOS runs the extension

- iOS calls `processJobs()` when it's enabled, on photo library changes, and again while we return
  `.processing`. After `.completed` it waits for the next library change, so the app's test button
  re-enables the extension to get an immediate run.
- iOS may call `willTerminate()` and then reuse the same instance; the stop flag is reset per run.
- Debug with the app's Log screen (extension and app write to `log.txt` in the app group) and
  `ssh home sudo docker logs immich-backup-proxy`.

## SideStore and ExtensionKit

SideStore's signer (SideSign `AppBundle.loadExtensions`) only looks in `PlugIns/`. This
extension is an ExtensionKit extension, which lives in `Extensions/`, so official SideStore
leaves it without an App ID or profile and the install fails. Moving it to `PlugIns/` doesn't work
either: iOS then demands an `NSExtension` dictionary ("extensionDictionary must be set", tested 2026-10-14).

Fix: SideSign also scans `Extensions/` (one function). Until that is upstream, use the patched
SideStore from the private repo github.com/dddd-zdf/sidestore-extfix (SideStore develop 12ff39c +
`patches/sidesign-extensions.patch`, built with Xcode 26.4 like the official nightly). Install its
IPA from inside SideStore (or with iloader). iloader's own signer (isideload) has the same gap.

Apple sign-in (error 80045 / 503, Oct 2026): SideStore's default Android anisette servers stopped
working. Use the Windows servers iloader 2.3.8 uses: Anisette Servers > Server List URL
`https://example.com/anisette-servers.json`, pick Jkcoxson, then User Customizations >
Anisette Client Configuration > Fetch > Save as Overrides, reset adi.pb, sign in with
trusted-device 2FA.

## Proxy

Runs on `home` as Docker container `immich-backup-proxy` (host network, 127.0.0.1:2284).
Caddy routes `photos.example.com/api/assets/background` to it. See infra `vms/home.md`.

- `OPTIONS` -> 501 (tells PhotoKit: no resumable uploads, send one plain request).
- Request headers: `x-api-key`, `X-Filename` (percent-encoded), `X-Content-Type`,
  `X-File-Created-At`, `X-File-Modified-At`, `X-Is-Favorite`, `X-Duration-Ms`, `X-Live-Photo-Video-Id`.
- Response headers (PhotoKit keeps only headers): `X-Immich-Asset-Id`, `X-Immich-Status`,
  `X-Immich-Result` (created/duplicate), `X-Immich-Error`.

Deploy: copy `proxy/` to `/opt/immich-backup-proxy`, then
`sudo docker build -t immich-backup-proxy:latest . && sudo docker rm -f immich-backup-proxy && sudo docker run -d --name immich-backup-proxy --restart unless-stopped --network host -e LISTEN_ADDR=127.0.0.1:2284 -e IMMICH_URL=http://127.0.0.1:2283 immich-backup-proxy:latest`.

### Immich upgrades

The only coupling to Immich is `POST /api/assets` (multipart fields `assetData`, `fileCreatedAt`,
`fileModifiedAt`, `filename`, `isFavorite`, `duration`, `livePhotoVideoId`), checked against v3.3.3.
Before bumping `IMMICH_VERSION`, check that DTO in the release. If Immich merges resumable uploads
(immich-app/immich#22385), PhotoKit could upload to Immich directly and the proxy can go.

## References

- Apple: "Uploading asset resources in the background" (PhotoKit).
- Nextcloud iOS PRs #4279, #4343 (iOS 27 implementation).
- YAIIU (github.com/FawenYo/YAIIU) and its immich-proxy (same idea).
