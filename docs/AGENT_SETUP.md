# Agent setup guide: Background Sync for Immich (server side)

You are an AI agent with shell access to the user's server. Your job: add the Background Sync for Immich
companion container next to their Immich and route one URL path to it, then hand the user the short
list of steps only they can do on their iPhone. Work carefully: this is their photo server.

Human-readable version of the same setup, with config for each reverse proxy:
https://github.com/dddd-zdf/background-sync-for-immich/blob/main/docs/SERVER.md

## Rules

- Change only what this guide says: one new container, one new reverse proxy route. Don't upgrade,
  restart or reconfigure Immich itself or anything else.
- Back up every file before editing it (`cp file file.bak-<date>`). Validate configs before reloading
  (`docker compose config -q`, `caddy validate`, `nginx -t`). Reload the proxy, don't restart it.
- Don't ask for, read or store the user's Immich API key; the server side never needs it.
- If anything doesn't match what this guide expects, stop and ask the user instead of guessing.
- Ask the user once, at the start, for the HTTPS address their iPhone uses for Immich
  (e.g. `https://photos.example.com`). Call it `$URL` below.

## 1. Look before changing anything

```sh
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}'
docker inspect immich_server --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}'
```

- The second command prints the folder with Immich's `docker-compose.yml`. If Immich isn't run with
  Docker Compose, stop and ask.
- Find the reverse proxy that serves `$URL`: Caddy, nginx, Nginx Proxy Manager, Traefik, Tailscale
  Serve or Cloudflare Tunnel (check running containers, `systemctl status caddy nginx`, `cloudflared`,
  `tailscale serve status`). If you can't tell, or it's something else, ask.
- Check that `$URL` works now: `curl -s $URL/api/server/ping` prints `{"res":"pong"}`. If it doesn't,
  stop: Immich itself isn't reachable at that address.
- Check that port 2284 is free: `ss -ltn | grep :2284` prints nothing.

## 2. Add the container

Add this service to Immich's `docker-compose.yml`, under `services:`, next to `immich-server`:

```yaml
  background-sync-server:
    container_name: background-sync-server
    image: ghcr.io/dddd-zdf/background-sync-for-immich-server:latest
    restart: always
    environment:
      LISTEN_ADDR: 0.0.0.0:2284
      IMMICH_URL: http://immich-server:2283
    ports:
      - 127.0.0.1:2284:2284
```

- `immich-server` must be the service name of Immich's server in that file; if it differs, use that name.
- If the reverse proxy runs in Docker (not on the host), remove the `ports:` lines and put the container
  on the proxy's Docker network instead; the proxy then reaches it as `background-sync-server:2284`.

Then:

```sh
docker compose config -q && docker compose up -d background-sync-server
curl -s http://127.0.0.1:2284/health     # prints: ok
```

`docker compose up -d background-sync-server` starts only the new container; Immich isn't touched.

## 3. Route one path

Send exactly `/api/assets/background` on `$URL` to the container; everything else must keep going to
Immich. Use the matching section of docs/SERVER.md (linked above) for the exact config. Uploads can be
large videos: no body size limit and long timeouts on that route.

## 4. Verify from outside

```sh
curl -s -o /dev/null -w '%{http_code}\n' -X OPTIONS $URL/api/assets/background
# must print 501
curl -s -D - -o /dev/null -X POST -H 'X-Filename: test.jpg' --data x $URL/api/assets/background | grep -i x-immich-status
# must print X-Immich-Status: 401  (reached Immich through the container; 401 because no key was sent)
curl -s $URL/api/server/ping
# still {"res":"pong"}: Immich itself unaffected
```

- 404 on the first check: the route isn't in effect. 502/503: the proxy can't reach the container.
- `docker logs background-sync-server` shows one line per request.

If a check fails and you can't fix it, roll back (below) and report what you saw.

## 5. Tell the user what's left (only they can do this)

Give them this list, filled in with `$URL`:

1. In Immich (web): **Account settings > API keys > New API key** with permissions `asset.upload`,
   `asset.read`, `asset.copy`, `asset.delete`, `user.read`, `stack.create`, `stack.read`, `stack.delete`.
2. Install the app: https://github.com/dddd-zdf/background-sync-for-immich#2-install-the-app
   (iOS 27; a sideloading tool that signs ExtensionKit extensions).
3. In the app (**BG Sync** on the home screen): Settings > Immich server: `$URL` and the key,
   **Save and check** (should say `API key: ok` and `Upload proxy: ok`). Then allow full Photos access,
   turn on **Background upload** and **Upload new photos**.
4. Optional: Settings has switches for videos, screenshots, older photos, how edits sync, and each
   direction of delete sync.

Also tell them what you changed (files, with backup paths) and how to undo it.

## Rollback

```sh
docker compose rm -sf background-sync-server
```

Then restore the backed-up compose file and proxy config, and reload the proxy.

## Updating later

```sh
docker compose pull background-sync-server && docker compose up -d background-sync-server
```
