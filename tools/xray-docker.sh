#!/bin/sh
# Run xray-core (same version as the OpenWrt 25.12.5 feed) in Docker.
# Repo root is mounted at /work; tests/fixtures/geo is used as XRAY_LOCATION_ASSET.
# Usage: tools/xray-docker.sh run -test -c /work/some-config.json
#        tools/xray-docker.sh version
set -e
cd "$(dirname "$0")/.."
exec docker run --rm -i \
  -e XRAY_LOCATION_ASSET=/work/tests/fixtures/geo \
  -v "$PWD:/work" \
  ghcr.io/xtls/xray-core:26.3.27 "$@"
