#!/usr/bin/env bash
# Validate the config, then hot-reload nginx (no dropped connections).
set -euo pipefail

CONTAINER=nginx-proxy

podman exec "$CONTAINER" nginx -t
podman exec "$CONTAINER" nginx -s reload
echo "reloaded"
