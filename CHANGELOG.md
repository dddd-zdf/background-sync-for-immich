# Changelog

## 0.7.0 (2026-10-18): choose how it syncs; ready to share

- New settings, so sync can be set up your way:
  - Upload: Videos, Screenshots, Older photos (photos from before upload was turned on that Immich lacks).
    These only hold back new uploads; edits of photos already in Immich still sync.
  - Edits: keep the original under the edit (as before), latest edit only (each edit replaces the last
    one, no stack), or don't sync edits.
  - Delete sync: each direction can be turned off (both off = backup only); the "ask first" limit for
    many iPhone deletes at once is adjustable (was fixed at 25). Deletes made while a direction is off
    are never synced later.
- No built-in server address any more (new installs start empty). The address is cleaned up on save:
  no `https://`, a trailing `/` or the Immich app's `.../api` form all work.
- "Save and check" also says which API key permissions are missing.
- Wi-Fi only now also covers matching: on cellular the library check doesn't download photos kept only
  in iCloud to hash them (a first sync could otherwise pull the whole library).
- "Waiting to upload" follows the upload filters.
- The "Trashed in Immich" album isn't created while that delete direction is off.
- Notifications are asked for the first time there's something to notify, not on first launch.
- An unreadable state file is kept as `*.unreadable.json` (and logged) instead of silently replaced.
- Public docs: README for users, internals in docs/DEVELOPMENT.md, MIT license. A `v*` tag now attaches
  the IPA to a GitHub release and publishes the proxy image `ghcr.io/dddd-zdf/immich-sync-proxy`.
- Who must act: the user installs the IPA (defaults match 0.6.1, nothing to change). The proxy is unchanged.

## 0.6.1 (2026-10-15): originals come back from the trash

- Immich matches uploads to trashed photos too. "Keep originals of edited photos" would have
  stacked an edit on an original sitting in Immich's trash (752 there now, mostly from the
  2026-10-14 cleanup), which Immich then deletes for good after 30 days (from about 2026-11-12).
  The proxy now restores an original (and a Live Photo's original video) when Immich matches it
  to an existing asset. Other uploads are unchanged: a photo trashed in Immich stays trashed.
- "Keep originals" skips photos trashed in Immich that are waiting to be deleted from the iPhone.
- Who must act: the user installs 0.6.1 instead of 0.6.0 and taps "Keep originals of edited photos"
  before 2026-11-12. Claude deployed the proxy.

## 0.6.0 (2026-10-15): edits keep the original

- An edited photo is now one stack in Immich: the edit on top (what the timeline shows), the
  untouched original under it. Editing again replaces only the edit; Revert in Photos puts the
  original back on top and trashes the edit, without uploading anything. Live Photos and videos too.
- Photos edited earlier: Advanced > "Keep originals of edited photos" gives them the same stack
  (Immich reuses what it already has; the rest uploads).
- Delete sync trashes the original along with the edit.
- Proxy: new `X-Stack-Original-Id` header (needs the new proxy on home; older apps are unaffected).
- Who must act: the user adds `stack.create`, `stack.read`, `stack.delete` to the app's Immich API key
  (Account settings > API keys > edit), installs the IPA, then optionally taps "Keep originals of
  edited photos". Claude deployed the proxy.

## 0.5.2 (2026-10-15): never delete from a stale list

- If a deletion sync fails (Immich unreachable, an error mid-run), the list of photos trashed in
  Immich is now emptied instead of kept from the last good sync, so the "Trashed in Immich" album is
  emptied too. Before, a photo restored in Immich after that last good sync could still be deleted
  from the iPhone by the album Shortcut or the delete button. The next good sync refills the list.
- The delete button stops with "Nothing removed" when its fresh check fails.
- Who must act: the user installs the IPA (no setting changes).

## 0.5.1 (2026-10-15): fully automatic with a Shortcut

- The "Sync Immich deletions" action also fills a Photos album "Trashed in Immich" with exactly the
  photos trashed in Immich that are still on the iPhone (restored ones drop out). A Shortcut can then
  delete them with no tap: Sync Immich deletions > Find Photos (Album is Trashed in Immich) > Delete
  Photos, with Settings > Apps > Shortcuts > Advanced > Allow Deleting Without Confirmation on.
  They still go to Recently Deleted. Anything added to the album by hand is deleted too.
- The album is created on every sync, even empty, so Find Photos can offer it as a filter (before,
  it only appeared once something was waiting). Every sync, not only the Shortcut, keeps it current.
- Suggested triggers: Photos app Is Closed (iPhone deletes reach Immich right away) and a daily time.
- Who must act: the user installs the IPA and builds the Shortcut automation.

## 0.4.4 (2026-10-15)

- Found on the phone: iOS doesn't wake the upload extension for deletions, only for new photos.
  So a delete on the iPhone reaches Immich's trash at the next new photo, the next Shortcut run, or
  when the app opens. A daily "Sync Immich deletions" automation covers both directions.
- Removed iOS background refresh: it failed under SideStore signing ("Unrecognized Identifier")
  and never runs for swiped-away apps.
- Who must act: the user installs the IPA and sets up the daily Shortcuts automation.

## 0.4.3 (2026-10-15)

- Fix: background trash of iPhone deletions found nothing, likely because fetching photos by ID
  still returns ones in Recently Deleted. The extension now scans the library like the app does,
  and logs each check ("delete check: N tracked, M gone").
- Who must act: the user installs the IPA and retests.

## 0.4.2 (2026-10-15)

- Deleting on the iPhone reaches Immich's trash in the background: the upload extension, which iOS
  wakes on every photo library change, sends the trash request itself (Live Photo videos too).
  More than 25 at once still waits for a tap in the app.
- Links remember a Live Photo's video ID (filled in for existing links on the next sync).
- Who must act: the user installs the IPA, then deletes a photo without opening the app to test.

## 0.4.1 (2026-10-15): renamed to Immich Sync

- The app is now called Immich Sync (home screen, titles, Photos permission text); status reads
  "In sync" / "Syncing" / "Sync is off". Settings sections are "Upload" and "Deletes".
- No more "Photos taken since" date: anything on the iPhone that isn't in Immich uploads. New photos
  go right away; older ones once the library check finds no copy in Immich with the same bytes
  (a photo edited after the Immich app uploaded it counts as missing, so its edited version uploads).
- The CI artifact is now `ImmichSync-<version>.ipa`. Bundle IDs, app group and repo name unchanged,
  so it installs over the old app and keeps everything.
- Who must act: the user installs the IPA (optional).

## 0.4.0 (2026-10-15): new look

- App icon: the Immich pinwheel with an indigo two-way sync badge (`design/app-icon.svg`; for
  personal sideloading only, it borrows Immich's logo). Indigo accent colour to match.
- Home screen shows only what matters: backup status, problems with a fix button (Photos access,
  upload off, no server, failures), and "Delete from iPhone" when photos trashed in Immich wait.
  Pull down to check Immich now.
- Everything else moved to Settings (gear); extension details, recent results and the Log are
  under Settings > Advanced.
- Who must act: the user installs the IPA (optional).

## 0.3.0 (2026-10-15): two-way delete sync

- Deleted on the iPhone -> moved to Immich's trash (Live Photo videos too). More than 25 at once
  wait for a tap in the app (guards against Photos access loss looking like mass deletion).
- Trashed in Immich -> removed from the iPhone after iOS's own "Allow deleting?" prompt (every
  delete needs it; apps can't skip it). The photos then sit in Recently Deleted for 30 days.
- The whole library is linked to Immich, not just this app's uploads: a photo with the same file
  name or capture time (within 2 s) is a candidate, and it's linked only if the SHA1 of its bytes
  equals Immich's checksum. Linked library photos also get edit replacement.
- Runs on app open (at most every 15 min), "Sync now", iOS background refresh, and a Shortcuts
  action "Sync Immich deletions" (for a daily automation). Background runs post a notification
  "Ask to delete" (on/off): while photos trashed in Immich wait, a notification every N days
  (type a number, default 7) at a chosen local time (default 7:00 pm); nothing when nothing waits. Tapping it goes
  straight to iOS's delete prompt.
- Who must act: the user installs the IPA, adds `asset.read` to the Immich API key (search), allows
  notifications, and optionally sets up the Shortcuts automation. Cairn can be uninstalled
  (this covers iPhone -> Immich deletes; running both is harmless).

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
