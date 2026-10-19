# Background Sync for Immich

Two-way sync between your iPhone's Photos library and your own [Immich](https://immich.app) server,
running in the background even when the app is closed. Nothing to install on the server.

- **New photos upload on their own**, usually within minutes, using the iOS 27 PhotoKit background
  upload extension. iOS runs it whether or not the app is open, even after a force-quit.
- **Edits sync.** Edit a photo in Photos and Immich gets the new version, with the untouched original
  stacked under it (or just the latest edit, your choice). Revert in Photos and Immich reverts too.
- **Deletes sync both ways.** Delete on the iPhone and it goes to Immich's trash. Trash it in Immich
  and it's deleted from the iPhone (after iOS's prompt, or fully automatic with a Shortcut).
- **Live Photos** arrive paired, **videos** too. Albums, favorites and shared links survive edits.
- **Already using the Immich app?** Your existing library is matched by checksum, so nothing uploads twice.

Keep the official Immich app for browsing; turn its own backup off. On the home screen the app is
called **BG Sync**.

> An independent community project, not affiliated with or endorsed by Immich or FUTO.

> **Status:** works daily for the author. It is a sideloaded app (not on the App Store).

## Requirements

- iPhone on **iOS 27** or later.
- Your own **Immich** server (tested with Immich v3.3), reachable over **HTTPS** from wherever your
  iPhone is (background uploads happen away from home too; an always-on VPN such as Tailscale works).
- A computer once, to install SideStore (or another way to sideload that signs the app's extension; see below).

## 1. Install the app

The easiest way, with a free Apple account, is SideStore. The app's upload extension is an
ExtensionKit extension, which official SideStore can't sign yet, so use the patched build
[sidestore-extfix](https://github.com/dddd-zdf/sidestore-extfix) (SideStore with that one fix):

1. **Install SideStore** following [SideStore's guide](https://docs.sidestore.io) (it needs a computer
   once, e.g. with iloader). Skip this if you already have SideStore.
2. **Swap in the patched SideStore:** download `SideStore-<version>.ipa` from
   [sidestore-extfix releases](https://github.com/dddd-zdf/sidestore-extfix/releases) and open it in
   SideStore (share it to SideStore, or + in My Apps). It replaces SideStore and keeps your apps.
3. **Add this app's source** in SideStore (Sources > +):

   ```
   https://github.com/dddd-zdf/background-sync-for-immich/releases/latest/download/source.json
   ```

4. **Install Background Sync for Immich** from that source. SideStore keeps it signed (free accounts
   need a refresh every 7 days, which SideStore does in the background) and shows updates.

If Apple sign-in in SideStore fails (error 80045/503), see the patched SideStore's README.

Other ways: download `BackgroundSync-<version>.ipa` from [Releases](../../releases) and use any signer
that also signs `Extensions/` (signers that only look in `PlugIns/`, like official SideStore and iloader
as of October 2026, leave the extension unsigned and the install fails). With a paid Apple developer
account, signing every nested bundle with your own certificate should work, but hasn't been tested.

Less tested builds (every app change) are on the nightly source:
`https://github.com/dddd-zdf/background-sync-for-immich/releases/download/nightly/source.json`.
It's the same app, so switching is an ordinary update that keeps your settings.

## 2. Set it up

Open the app. It asks for your Immich server's address, then you sign in with your Immich account
(email and password, or your server's OAuth button). The app creates its own API key with only the
permissions it needs; you can see or remove it in Immich under **Account settings > API keys**. Your
password goes only to your server and isn't kept. Prefer making a key yourself? Choose **Use an API
key instead**.

Then tap **Allow access and start** and choose **Allow Full Access** to Photos. That's it: the app
matches your library with what's already in Immich and uploads whatever is missing, from then on in
the background.

## Settings

| Setting | What it does | Default |
|---|---|---|
| Upload new photos | Background upload on/off | on after setup |
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
  Large backlogs take a while: up to 10 uploads run at once.
- **Troubleshooting:** Settings > Advanced has a test upload, the extension's run count and a log you
  can share. Failed uploads show on the home screen with the reason.
- Each upload briefly needs free space on the iPhone for a copy of the file (it's built into Immich's
  upload format on the phone, then sent).
- **Albums** are not synced (Immich albums and iPhone albums stay separate). Favorites are set on upload.
- Works over a VPN (e.g. Tailscale) as long as the iPhone can reach the server when iOS runs the upload.

## Support

Bugs and ideas: open an issue.

If this saves you time, you can [leave a tip on Ko-fi](https://ko-fi.com/dfzhhh). If tips ever cover Apple's
developer fee ($99 USD a year), I'll look at putting the app on TestFlight or the App Store so nobody has
to sideload. No promises either way. Tips go to this app's developer, not to Immich; to support Immich
itself, [buy a product key](https://buy.immich.app).

## For developers

How it works inside (edit detection, Live Photo pairing, uploads straight to Immich, building without a Mac):
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Changes per version: [CHANGELOG.md](CHANGELOG.md).

## License

MIT. Not affiliated with or endorsed by Immich or FUTO; "Immich" here only names the server it works with.
