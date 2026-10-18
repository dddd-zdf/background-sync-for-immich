# Immich Sync: how it works

Developer notes. For installing and using the app, see the [README](../README.md).
(Repo and bundle IDs keep the old name, Immich Backup.)

```
iPhone: PhotoKit runs UploadExtension -> raw POST <server>/api/assets/background
  -> reverse proxy -> immich-sync proxy (:2284) -> multipart POST /api/assets -> Immich
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

## Build

Push to `main` (or run the "iOS build" workflow); the `ipa-N` artifact has
`ImmichSync-<version>.ipa`. Pushing a `v*` tag also attaches the IPA to a GitHub release and
publishes the proxy image `ghcr.io/dddd-zdf/immich-sync-proxy`. Bump `MARKETING_VERSION` in
`project.yml` and add a CHANGELOG entry first.

Tested on iOS 27 with a free Apple account and the patched SideStore 0.7.0-extfix.2: photos reach
Immich about 2 minutes after they're taken, with the app closed and after a force-quit; Live Photos
arrive paired, videos arrive, deletes go both ways (Live Photo videos included).

## What gets uploaded

Below is the default behaviour. Settings (`Shared/Settings.swift`) change it: `includeVideos`,
`skipScreenshots` and `uploadOlder` filter new uploads only; `editMode` `.latest` skips the original
(no stack, `X-Replace-Asset-Id` alone) and `.ignore` skips `findEdits`; `syncPhoneDeletes` /
`syncImmichDeletes` turn off a delete direction (deletes seen while off are marked gone);
`bulkTrashLimit` replaces the fixed 25.

- Each job uploads one file: the version you see in Photos (the edited render if any, named like the
  original, e.g. `IMG_1234.jpg`). Up to 20 jobs at once; photos from the last day first, then newer
  ones since upload was turned on, then older ones the library check marked as not in Immich. A file that fails 3 times waits for "Retry all".
- Live Photos: two jobs in sequence. The video goes first; once its job is acknowledged with an
  Immich ID, the still goes with `X-Live-Photo-Video-Id`, which Immich uses to pair them.
- Edits (0.6.0): an edited photo is one stack in Immich, the edit on top and the untouched original
  under it, like Photos. The original goes first (Live Photos: its video, then the still), then the
  render with `X-Stack-Original-Id`. Edit detection: when an asset's modification date moves, the
  extension compares a hash of its adjustment data with the one recorded at upload.
  - First edit of a photo that reached Immich unedited: what Immich has is the original; only the
    render uploads, and gets the original's albums.
  - Later edits: the new render goes on top (`X-Replace-Asset-Id` = the previous render: its albums,
    shared links and sidecar move over, its stack is removed, it is trashed). The original stays.
  - Revert in Photos: no upload. The extension removes the stack, copies the render's albums and
    favorite to the original and trashes the render.
  - Photos edited before 0.6.0 (or before the photo first uploaded under 0.5.x) are a single render
    in Immich until Advanced > "Keep originals of edited photos" queues them like a new edit.
    Immich matches anything it already has by checksum, so only what's missing is stored. An original
    matched to a trashed asset is restored from Immich's trash (`X-Immich-Restored`).
  - Anything with a full-size render counts as edited, including Portrait photos straight from the camera.
- `state.json` in the app group (written only by the extension; the app asks for changes through
  settings flags): `uploaded` (Photos ID -> Immich ID, for later two-way sync), `liveVideos`,
  `versions`, `replacing`, `originals` and `originalVideos` (edited photos), `inflight`, `failed`.

## Two-way delete sync

Runs in the app (`App/DeleteSync.swift`): on open, pull to refresh, and the Shortcuts action "Sync
Immich deletions" (Shortcuts > Automation > Time of Day > Run Immediately; the only way to run it
with the app swiped away). The upload extension also trashes iPhone deletions itself, but iOS only
wakes it for new photos, not deletions (tested 2026-10-15). The Shortcuts action also stages
photos trashed in Immich in a "Trashed in Immich" album, so an automation can delete them unprompted
(Find Photos by album > Delete Photos, with Shortcuts' Allow Deleting Without Confirmation). State is `sync.json` in the app group,
written only by the app; the extension's trashes are in `UploadState.trashed`.

1. Reads every Immich asset (`POST /api/search/metadata`, timeline + archive, trashed included).
2. Deleted on the iPhone (tracked photo no longer in Photos) -> `DELETE /api/assets` (trash), with
   the Live Photo video (Immich doesn't cascade). Over 25 at once waits for a tap.
3. Links library photos the app didn't upload: same name (any extension) or capture time +-2 s as
   candidates, then SHA1 of the current (else original) bytes must equal Immich's `checksum`.
   No candidate or no hash match -> `unmatched`, rechecked only if the photo changes.
4. Trashed in Immich -> `pendingRemoval`. Background runs post a notification; the delete needs
   iOS's prompt, so it happens when the app is in front (notification tap or the button).

A photo whose edit is still being replaced, or with a job in flight, is skipped that run, so the
edit replace (which trashes the old Immich asset) never deletes the iPhone photo.

## How iOS runs the extension

- iOS calls `processJobs()` when it's enabled, on photo library changes, and again while we return
  `.processing`. After `.completed` it waits for the next library change, so the app's test button
  re-enables the extension to get an immediate run.
- iOS may call `willTerminate()` and then reuse the same instance; the stop flag is reset per run.
- Debug with the app's Log screen (extension and app write to `log.txt` in the app group) and
  the proxy's container log (`docker logs immich-sync-proxy`).

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
working. Use the Windows servers iloader 2.3.8 uses: Anisette Servers > Server List URL (a JSON
list with those servers), pick Jkcoxson, then User Customizations >
Anisette Client Configuration > Fetch > Save as Overrides, reset adi.pb, sign in with
trusted-device 2FA.

## Proxy

Runs next to Immich (see the README for compose and reverse proxy setup). Env: `LISTEN_ADDR`
(default `127.0.0.1:2284`), `IMMICH_URL` (default `http://127.0.0.1:2283`). `GET /health` answers `ok`.
It keeps no state and stores no keys: each request carries the user's own `x-api-key`.

- `OPTIONS` -> 501 (tells PhotoKit: no resumable uploads, send one plain request).
- Request headers: `x-api-key`, `X-Filename` (percent-encoded), `X-Content-Type`,
  `X-File-Created-At`, `X-File-Modified-At`, `X-Is-Favorite`, `X-Duration-Ms`, `X-Live-Photo-Video-Id`,
  `X-Replace-Asset-Id` (after a successful upload with a different ID: `PUT /api/assets/copy`, then
  `DELETE /api/assets` to trash the old one), `X-Stack-Original-Id` (stack the upload on top of that
  original; with it, `X-Replace-Asset-Id` is what stood for the photo before, trashed unless it is
  the original). Others (`X-Asset-Id`, `X-Upload-Part`, ...) are only
  for the extension, which reads them back from the finished job.
- Response headers (PhotoKit keeps only headers): `X-Immich-Asset-Id`, `X-Immich-Status`,
  `X-Immich-Result` (created/duplicate), `X-Immich-Error`, `X-Immich-Replaced` and `X-Immich-Stacked` (ok or what failed).

Author's deploy (no registry): copy `proxy/` to `/opt/immich-backup-proxy`, then
`sudo docker build -t immich-backup-proxy:latest . && sudo docker rm -f immich-backup-proxy && sudo docker run -d --name immich-backup-proxy --restart unless-stopped --network host -e LISTEN_ADDR=127.0.0.1:2284 -e IMMICH_URL=http://127.0.0.1:2283 immich-backup-proxy:latest`.

### Immich upgrades

The coupling to Immich is `POST /api/assets` (multipart fields `assetData`, `fileCreatedAt`,
`fileModifiedAt`, `filename`, `isFavorite`, `duration`, `livePhotoVideoId`), `PUT /api/assets/copy`
(with `stack`/`favorite` flags), `DELETE /api/assets`, and stacks (`POST /api/stacks` with the shown
asset first, `GET /api/stacks?primaryAssetId=`, `DELETE /api/stacks/{id}`), checked against v3.3.3.
Before bumping `IMMICH_VERSION`, check that DTO in the release. If Immich merges resumable uploads
(immich-app/immich#22385), PhotoKit could upload to Immich directly and the proxy can go.

## References

- Apple: "Uploading asset resources in the background" (PhotoKit).
- Nextcloud iOS PRs #4279, #4343 (iOS 27 implementation).
- YAIIU (github.com/FawenYo/YAIIU) and its immich-proxy (same idea).
