# nginx-proxy

Reverse proxy on port 80, running under podman. Proxies are plain nginx config
files in `nginx/conf.d/`; add one, reload, done.

## Layout

```
compose.yaml               podman-compose service definition
reload.sh                  validate config + hot-reload nginx
nginx/conf.d/                one .conf per proxied service (mounted read-only)
  00-defaults.conf           websocket map + catch-all server, /healthz
  example.conf.disabled      template, not loaded (only *.conf is)
  locations/                 path-prefix proxies, included by the catch-all
    example.conf.disabled    template for those
nginx/snippets/
  proxy.conf                 shared proxy_set_header / timeout block
  proxy-sse.conf             same, but 24h timeouts for streaming upstreams
logs/                        access.log + error.log on the host
```

## Two ways to route

**By hostname** - a self-contained `server` block in `conf.d/`. Needs DNS (or a
hosts entry) pointing here.

**By path prefix** - a `location` block in `conf.d/locations/`, included into
the catch-all server. Works when the box is reached by bare IP with no DNS, and
lets several services share port 80 under `/name/`. A `location` cannot live in
its own `server` block, which is why these are included rather than dropped
into `conf.d/` directly.

## Start

```sh
podman-compose up -d
curl -s localhost/healthz    # -> ok
```

## Add a proxy

By hostname:

```sh
cp nginx/conf.d/example.conf.disabled nginx/conf.d/myapp.conf
$EDITOR nginx/conf.d/myapp.conf      # set server_name + proxy_pass
./reload.sh
```

By path prefix:

```sh
cp nginx/conf.d/locations/example.conf.disabled nginx/conf.d/locations/myapp.conf
$EDITOR nginx/conf.d/locations/myapp.conf   # set the prefix + proxy_pass
./reload.sh
```

Streaming upstreams (SSE, MCP servers, log tails) should include
`snippets/proxy-sse.conf` instead of `snippets/proxy.conf` - the latter's 60s
`proxy_read_timeout` cuts a long-lived stream. Include one or the other, never
both: nginx rejects a directive an include has already set, so the SSE variant
is a full copy rather than a supplement.

`reload.sh` runs `nginx -t` first, so a broken config fails loudly and the
running proxy keeps serving the old one. A full restart works too and picks up
the same files:

```sh
podman-compose restart nginx
```

## Upstream addresses

| Where the service runs | Use |
|---|---|
| On the podman host | `http://host.containers.internal:8080` |
| Another machine | `http://10.0.0.12:8080` |
| Another container | `http://container-name:8080` (needs a shared network) |

For the container case, `compose.yaml` joins the external network `mcp-net`.
Create it once, before starting anything:

```sh
podman network create mcp-net
```

Then give the upstream stack the same network and no published port, and
reference it by container name; podman's DNS resolves it.

```yaml
services:
  myapp:
    container_name: myapp
    expose: ['3000']
    networks: [mcp-net]

networks:
  mcp-net:
    external: true
```

## Server notes (podman)

**Rootless can't bind port 80.** Either lower the threshold:

```sh
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf
```

or run the stack as root (`sudo podman-compose up -d`).

**`restart: unless-stopped` does not survive a reboot on its own** the way it
does under a docker daemon - podman has no daemon to re-apply it. Enable the
restart service for rootless:

```sh
systemctl --user enable --now podman-restart
sudo loginctl enable-linger "$USER"   # so it starts without an active login
```

Rootful equivalent: `sudo systemctl enable --now podman-restart`.

**SELinux**: mounts carry `:z`, so no manual `chcon` is needed on
RHEL/Fedora-family hosts. Ignored elsewhere.

## TLS

Not configured - port 80 only, as specced. If certs are needed later, publish
443 as well, mount the cert dir, and add `listen 443 ssl;` blocks; the
`snippets/proxy.conf` include stays the same.
