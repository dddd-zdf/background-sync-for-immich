# Changelog

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
