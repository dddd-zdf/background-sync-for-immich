# Server setup

Immich Sync needs one small container next to your Immich server, `immich-sync-proxy`. It runs on
**your** server; nothing goes through anyone else's.

**Why it's needed:** iOS's background upload (the part that keeps working with the app closed) can only
send a photo as a plain file. Immich only accepts uploads as a form (multipart) with the date and file
name as fields. The container rewraps one into the other and passes the request on to Immich. It
stores nothing and has no keys of its own; each upload carries your Immich API key. Once Immich supports
resumable uploads (immich-app/immich#22385), it won't be needed anymore.

Two steps: run the container, then send **one URL path** of your Immich site to it.

```
iPhone --HTTPS--> your reverse proxy --/api/assets/background--> immich-sync-proxy:2284 --> Immich
                                     --everything else---------> Immich (unchanged)
```

## What you need

- Immich reachable over **HTTPS** at the address you'll put in the app (e.g. `https://photos.example.com`),
  from wherever your iPhone is: background uploads happen away from home too. A VPN such as Tailscale
  works if it's always on.
- A reverse proxy (or Tailscale Serve / Cloudflare Tunnel) in front of Immich where you can add a route.
  Immich used directly as `http://<ip>:2283` doesn't work: iOS requires HTTPS, and the extra path
  needs a reverse proxy.

## 1. Run the container

Add this service to the `docker-compose.yml` you run Immich with (next to `immich-server`):

```yaml
  immich-sync-proxy:
    container_name: immich-sync-proxy
    image: ghcr.io/dddd-zdf/immich-sync-proxy:latest
    restart: always
    environment:
      LISTEN_ADDR: 0.0.0.0:2284
      IMMICH_URL: http://immich-server:2283
    ports:
      - 127.0.0.1:2284:2284   # only for a reverse proxy on the host; drop it if yours runs in Docker
```

Then `docker compose up -d`. Check it: `curl http://127.0.0.1:2284/health` prints `ok`.

- `IMMICH_URL` is how the container reaches Immich. `http://immich-server:2283` works inside Immich's
  own compose file. In a separate compose file, use `http://<host-ip>:2283` instead.
- Images are built for amd64 and arm64 (Raspberry Pi, Apple silicon, Ampere).
- Without Docker: `cd proxy && go build` gives a single binary; set the same two environment variables.

## 2. Route the upload path to it

Only `/api/assets/background` goes to the container. Pick your setup:

### Caddy

```
photos.example.com {
    reverse_proxy /api/assets/background 127.0.0.1:2284
    reverse_proxy 127.0.0.1:2283
}
```

### nginx

Inside the `server` block that already serves Immich:

```nginx
location = /api/assets/background {
    proxy_pass http://127.0.0.1:2284;
    client_max_body_size 0;
    proxy_request_buffering off;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
}
```

### Nginx Proxy Manager

Edit Immich's proxy host > **Custom locations** > Add location:

- Location: `/api/assets/background`
- Scheme `http`, Forward hostname `immich-sync-proxy` (same Docker network) or the host's IP, port `2284`
- In the location's gear (advanced) box: `client_max_body_size 0; proxy_request_buffering off;`

### Traefik

Labels on the `immich-sync-proxy` service (adjust the entrypoint and cert resolver to yours). The
longer rule wins over Immich's own router automatically:

```yaml
    labels:
      - traefik.enable=true
      - traefik.http.routers.immich-sync.rule=Host(`photos.example.com`) && Path(`/api/assets/background`)
      - traefik.http.routers.immich-sync.entrypoints=websecure
      - traefik.http.routers.immich-sync.tls.certresolver=letsencrypt
      - traefik.http.services.immich-sync.loadbalancer.server.port=2284
```

### Tailscale Serve

If you already serve Immich with `tailscale serve`, add the path:

```
tailscale serve --bg --set-path /api/assets/background http://127.0.0.1:2284
```

### Cloudflare Tunnel

Add a public hostname rule **above** Immich's: same hostname, path `^/api/assets/background$`, service
`http://immich-sync-proxy:2284` (or `localhost:2284`). Note: Cloudflare's free plan rejects uploads over
100 MB, so long videos fail there (the same limit applies to Immich's own app).

## 3. Check from outside

```
curl -i -X OPTIONS https://photos.example.com/api/assets/background
```

It must answer **501**. (That's on purpose: it tells iOS to send each file in one plain request.)
In the app, **Settings > Immich server > Save and check** runs the same test and shows
`Upload proxy: ok`.

## Troubleshooting

| What you see | Cause |
|---|---|
| Save and check: `Upload proxy: HTTP 404` (or 200/401 from Immich) | The route isn't in place: the request reaches Immich instead of the container. |
| `Upload proxy: HTTP 502` / `503` | The reverse proxy can't reach the container: check its address and port, and that it's running. |
| Uploads fail with `HTTP 413` | A body size limit in the reverse proxy (nginx `client_max_body_size`) or Cloudflare's 100 MB. |
| Uploads fail with `HTTP 401` / `403` | API key wrong or missing permissions (Save and check lists the missing ones). |
| Container log says `immich unreachable` | `IMMICH_URL` is wrong from inside the container. |
| Nothing uploads, no errors | Settings: Background upload and Upload new photos both on? Advanced > "Upload newest photo (test)" forces a run. |

The container logs one line per upload: `docker logs immich-sync-proxy`.

## Updating

`docker compose pull immich-sync-proxy && docker compose up -d`. Each app release says in the
changelog when it needs a newer container; older containers keep working with older app versions.
Immich upgrades: the container uses Immich's public asset and stack APIs, checked against Immich v3.3.
