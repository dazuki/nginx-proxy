# nginx-proxy

Path-prefix reverse proxy under podman. Each service adds one `location` drop-in to `nginx/conf.d/locations/` and is served at `/name/` on port 80 (and 443 once enabled).

```
compose.yaml
reload.sh                    nginx -t, then hot reload
nginx/conf.d/
  00-defaults.conf           :80 catch-all server, /healthz, unmatched -> 444
  10-https.conf.disabled     :443 server, same drop-ins
  locations/                 one .conf per service (gitignored)
    example.conf.disabled    template
nginx/snippets/
  proxy.conf                 standard, 60s timeouts
  proxy-sse.conf             streaming (SSE/MCP), 24h timeouts
nginx/ssl/                   certs (gitignored)
logs/
```

## Start

```sh
podman network create mcp-net    # once
podman-compose up -d
curl -s localhost/healthz        # ok
```

## Add a service

`nginx/conf.d/locations/myapp.conf`:

```nginx
location = /myapp {
    return 308 /myapp/;
}

location /myapp/ {
    include /etc/nginx/snippets/proxy.conf;    # or proxy-sse.conf, never both
    proxy_pass http://myapp:3000/;             # trailing / strips /myapp prefix
}
```

```sh
./reload.sh                      # bad config is rejected, old one keeps running
```

Keep the drop-in in the service's own repo and copy it to the server.

## Upstream addresses

| Service runs on | `proxy_pass` |
|---|---|
| Podman host | `http://host.containers.internal:8080/` |
| Other machine | `http://10.0.0.12:8080/` |
| Container on `mcp-net` | `http://container-name:8080/` |

Container upstreams join `mcp-net` and publish no port:

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

The upstream container must be running on `mcp-net` before nginx starts or reloads (`host not found in upstream`).

## HTTPS

Port 443 is published but off until a cert exists. Enable (also used for renewal):

```sh
# leaf first, then intermediate, no root
{ cat <leaf>.crt; echo; cat <intermediate>.crt; } > nginx/ssl/fullchain.pem
cp <key> nginx/ssl/privkey.pem && chmod 600 nginx/ssl/privkey.pem
cp nginx/conf.d/10-https.conf.disabled nginx/conf.d/10-https.conf
./reload.sh
```

Verify:

```sh
# order: leaf, then issuer
openssl crl2pkcs7 -nocrl -certfile nginx/ssl/fullchain.pem | openssl pkcs7 -print_certs -noout
# key matches cert: identical hashes
openssl x509 -in nginx/ssl/fullchain.pem -noout -pubkey | openssl sha256
openssl pkey -in nginx/ssl/privkey.pem -pubout | openssl sha256
# served chain: "Verify return code: 0 (ok)"
openssl s_client -connect <host>:443 -servername <host> </dev/null 2>/dev/null | grep "Verify return"
```

- Browsers hide a missing intermediate; server-side clients (MCP, scripts) fail. Test with `openssl`/`curl`.
- `ssl_trusted_certificate` is not sent to clients and does not complete the chain.
- Certs go in `nginx/ssl/` only. Not `/etc/ssl/certs` (system CA store), never in git.

All drop-ins are served on both ports. HTTPS only for one service, inside its `location`:

```nginx
if ($scheme = http) { return 308 https://$host$request_uri; }    # 307 while testing, never 301
```

## Server setup

```sh
# Rootless podman: allow binding ports 80/443
echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf
sudo sysctl --system

# Restart containers after reboot (no docker daemon to do it)
systemctl --user enable --now podman-restart
sudo loginctl enable-linger "$USER"

# After compose.yaml changes (ports, mounts)
podman-compose up -d --force-recreate
```
