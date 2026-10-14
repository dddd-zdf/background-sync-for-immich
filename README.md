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

1. Push to `main` (or run the "iOS build" workflow). The `ipa-N` artifact has two IPAs:
   - `ImmichBackup-extensions.ipa`: standard layout, extension in `Extensions/`.
   - `ImmichBackup-plugins.ipa`: extension moved to `PlugIns/` (workaround test, see below).
2. Install with SideStore. In the app: set server URL and API key (Immich: Account settings >
   API keys, permissions `asset.upload` and `user.read`), allow full Photos access, turn on the extension.

## Known risk: SideStore and ExtensionKit

SideStore's signer (SideSign `AppBundle.loadExtensions`) only looks in `PlugIns/`. This
extension is an ExtensionKit extension, which Xcode puts in `Extensions/`. If the standard IPA
fails to install or the extension never runs, the fix is to make SideSign scan `Extensions/` too.

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
