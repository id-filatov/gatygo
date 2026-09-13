# Unit-test image: busybox ash + jq (as on OpenWrt 25.12) + xray-core 26.3.27 for `xray run -test`.
FROM ghcr.io/xtls/xray-core:26.3.27 AS xray

FROM alpine:3.22
RUN apk add --no-cache jq curl python3
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
ENV GATYGO_LIB=/src/gatygo/files/lib \
    FIXTURES=/src/tests/fixtures \
    XRAY_LOCATION_ASSET=/src/tests/fixtures/geo
WORKDIR /src
