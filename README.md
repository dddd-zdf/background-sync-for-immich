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
> needs one small extra container on your Immich server. Read the requirements before you start.

## Requirements

- iPhone on **iOS 27** or later.
- Your own **Immich** server (tested with Immich v3.3).
- Access to your Immich server to add one small Docker container and one reverse proxy route
  (below). Immich must be reachable over HTTPS from wherever your iPhone is.
- A way to sideload an IPA whose signer also signs its **ExtensionKit extension** (see below).

## 1. Add the companion container to your server

iOS's background upload can only send a plain file, and Immich only takes form uploads, so a small
container next to Immich (`immich-sync-proxy`) converts between the two. It runs on your server, stores
nothing and uses your own API key. About 5 minutes if you run Immich with Docker Compose:

1. Add the service to Immich's `docker-compose.yml` and `docker compose up -d`:

   ```yaml
     immich-sync-proxy:
       container_name: immich-sync-proxy
       image: ghcr.io/dddd-zdf/immich-sync-proxy:latest
       restart: always
       environment:
         LISTEN_ADDR: 0.0.0.0:2284
         IMMICH_URL: http://immich-server:2283
       ports:
         - 127.0.0.1:2284:2284
   ```

2. In your reverse proxy, send the one path `/api/assets/background` to it. Caddy:

   ```
   photos.example.com {
       reverse_proxy /api/assets/background 127.0.0.1:2284
       reverse_proxy 127.0.0.1:2283
   }
   ```

3. Check from outside: `curl -i -X OPTIONS https://photos.example.com/api/assets/background` answers `501`.

**nginx, Nginx Proxy Manager, Traefik, Tailscale Serve, Cloudflare Tunnel, and troubleshooting:
[docs/SERVER.md](docs/SERVER.md).**

## 2. Install the app

Download `ImmichSync-<version>.ipa` from [Releases](../../releases) and sideload it your usual way.
Updating over an existing install keeps your settings.

**Your signer must handle the extension.** The upload extension is an ExtensionKit extension, which
lives in the app's `Extensions/` folder (not the older `PlugIns/`), and it needs the same App Group as the
app. Signers that only look in `PlugIns/` leave it unsigned and the install fails; as of October 2026 that
includes official SideStore and iloader. Signing with your own certificate (a paid Apple developer
account, with a tool that re-signs every nested bundle) should work, but the author hasn't tested it. A patched SideStore that signs it with a free
account is in the works.

If your sideloading app reads AltStore/SideStore sources, add this one for updates:

```
https://github.com/dddd-zdf/immich-backup/releases/latest/download/source.json
```

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

The three classic modes:

- **Backup only:** both delete directions off. Nothing is ever deleted anywhere.
- **One-way, Immich keeps your curation:** only "Deleted on iPhone" on. Photos you delete in Immich stay
  on the iPhone but are **never uploaded again**.
- **Full two-way sync:** both on (the default).

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
  can share. Server-side problems: [docs/SERVER.md](docs/SERVER.md#troubleshooting).
- **Albums** are not synced (Immich albums and iPhone albums stay separate). Favorites are set on upload.
- Works over a VPN (e.g. Tailscale) as long as the iPhone can reach the server when iOS runs the upload.

## Support

If this saves you time, you can [buy me a coffee](DONATION_LINK). Bugs and ideas: open an issue.

## For developers

How it works inside (edit detection, Live Photo pairing, the proxy's headers, building without a Mac):
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Changes per version: [CHANGELOG.md](CHANGELOG.md).

## License

MIT. Not affiliated with Immich or FUTO.
