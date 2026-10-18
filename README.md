# Immich Sync for iPhone

Two-way sync between your iPhone's Photos library and your own [Immich](https://immich.app) server,
running in the background even when the app is closed.

- **New photos upload on their own**, usually within a couple of minutes, using the iOS 27 PhotoKit
  background upload extension. iOS runs it whether or not the app is open, even after a force-quit.
- **Edits sync.** Edit a photo in Photos and Immich gets the new version, with the untouched original
  stacked under it (or just the latest edit, your choice). Revert in Photos and Immich reverts too.
- **Deletes sync both ways.** Delete on the iPhone and it goes to Immich's trash. Trash it in Immich
  and it's deleted from the iPhone (after iOS's prompt, or fully automatic with a Shortcut).
- **Live Photos** arrive paired, **videos** too. Albums, favorites and shared links survive edits.
- **Already using the Immich app?** Your existing library is matched by checksum, so nothing uploads twice.

Keep the official Immich app for browsing; turn its own backup off.

> **Status:** works daily for the author. It is a sideloaded app (not on the App Store) and
> needs a small proxy next to your Immich server. Read the requirements before you start.

## Requirements

- iPhone on **iOS 27** or later.
- An **Immich** server reachable over HTTPS from wherever your iPhone is (tested with Immich v3.3).
- A place to run one small Docker container next to Immich (the upload proxy, below).
- A computer for sideloading once: **SideStore** with a free Apple account works.
  The app has an ExtensionKit extension that official SideStore can't sign yet, so use the
  [patched SideStore](https://github.com/dddd-zdf/sidestore-extfix/releases) until the fix is upstream.

## 1. Run the upload proxy

PhotoKit can only send a photo as a raw file; Immich only accepts multipart uploads. The proxy
converts one into the other. It stores nothing and has no keys of its own: every request carries your
Immich API key.

Add it to your Immich `docker-compose.yml`:

```yaml
  immich-sync-proxy:
    image: ghcr.io/dddd-zdf/immich-sync-proxy:latest
    restart: unless-stopped
    environment:
      LISTEN_ADDR: 0.0.0.0:2284
      IMMICH_URL: http://immich-server:2283
    ports:
      - 127.0.0.1:2284:2284
```

Then send **one path** of your Immich site to it in your reverse proxy, everything else stays as is.

Caddy:

```
photos.example.com {
    reverse_proxy /api/assets/background 127.0.0.1:2284
    reverse_proxy 127.0.0.1:2283
}
```

nginx (inside your Immich `server` block):

```nginx
location = /api/assets/background {
    proxy_pass http://127.0.0.1:2284;
    client_max_body_size 0;
    proxy_request_buffering off;
    proxy_read_timeout 600s;
}
```

Check: `curl http://127.0.0.1:2284/health` answers `ok`.

## 2. Install the app

1. Install the [patched SideStore](https://github.com/dddd-zdf/sidestore-extfix/releases) (same steps as
   regular SideStore).
2. Download `ImmichSync-<version>.ipa` from [Releases](../../releases) and open it in SideStore.
   Updating later the same way keeps your settings.

Free Apple accounts must refresh sideloaded apps every 7 days; SideStore does this for you.

## 3. Set it up

1. In Immich: **Account settings > API keys > New API key** with these permissions:
   `asset.upload`, `asset.read`, `asset.copy`, `asset.delete`, `user.read`,
   `stack.create`, `stack.read`, `stack.delete`.
2. In the app: **Settings > Immich server**: your server URL (e.g. `https://photos.example.com`) and
   the key, then **Save and check**.
3. Allow **full Photos access** and turn on **Background upload**.
4. Turn on **Upload new photos**.

The app then matches your library with what's already in Immich and uploads whatever is missing.

## Settings

| Setting | What it does | Default |
|---|---|---|
| Upload new photos | Background upload on/off | off until you turn it on |
| Wi-Fi only | No uploads over cellular | off |
| Videos / Screenshots | Upload these too | on / on |
| Older photos | Also upload photos from before you turned upload on that Immich doesn't have | on |
| Edited photos | **Keep the original under the edit** (an Immich stack, like Photos), **Latest edit only**, or **Don't sync edits** | keep the original |
| Deleted on iPhone: trash in Immich | One direction of delete sync | on |
| Ask first if over N | More deletes than this at once wait for your tap (protects against a lost Photos permission looking like a mass delete) | 25 |
| Trashed in Immich: delete from iPhone | The other direction | on |
| Ask to delete | A reminder notification while photos trashed in Immich wait to be deleted from the iPhone | weekly, 19:00 |

Turn both delete directions off for a plain backup that never deletes anything.

## Deleting from the iPhone without a tap

iOS only lets an app delete photos after a confirmation prompt. To make Immich-to-iPhone deletes
fully automatic, the app keeps a **Trashed in Immich** album with exactly the photos waiting to go,
and a Shortcut can delete them without asking:

1. Shortcuts > Automation > New > **Time of Day** (e.g. daily), **Run Immediately**.
2. Actions: **Sync Immich deletions** (from this app) > **Find Photos** where Album is *Trashed in Immich*
   > **Delete Photos**.
3. In the Delete Photos action's details, turn on **Allow Deleting Without Confirmation**.

Deleted photos sit in Recently Deleted for 30 days, and photos restored in Immich drop out of the album
before they can be deleted. Don't add photos to that album by hand.

The same automation also keeps iPhone-to-Immich deletes flowing when you don't open the app (iOS wakes
the extension for new photos, not for deletions).

## Good to know

- **Deletes go to trash on both sides**, never straight to permanent deletion.
- The **upload extension decides its own schedule**; iOS usually runs it within minutes of a new photo.
  Large backlogs take a while: up to 20 uploads run at once.
- **Troubleshooting:** Settings > Advanced has a test upload, the extension's run count and a log you
  can share. The proxy's log is `docker logs immich-sync-proxy`.
- **Albums** are not synced (Immich albums and iPhone albums stay separate). Favorites are set on upload.
- Works over a VPN (e.g. Tailscale) as long as the iPhone can reach the server when iOS runs the upload.

## Support

If this saves you time, you can [buy me a coffee](DONATION_LINK). Bugs and ideas: open an issue.

## For developers

How it works inside (edit detection, Live Photo pairing, the proxy's headers, building without a Mac):
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Changes per version: [CHANGELOG.md](CHANGELOG.md).

## License

MIT. Not affiliated with Immich or FUTO.
