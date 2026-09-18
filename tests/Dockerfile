# Unit-test image: busybox ash + jq + the pinned xray core (tools/pin-core.sh keeps the tag
# below in step with gatygo/files/lib/core.pin) for `xray run -test`, trimmed to what
# OpenWrt 25.12 actually ships so the tests fail on anything the router would reject.
FROM ghcr.io/xtls/xray-core:26.9.9 AS xray

# OpenWrt's `jq` package is built without oniguruma: no test/match/sub/capture/scan/splits.
FROM alpine:3.22 AS jq
RUN apk add --no-cache build-base curl
RUN curl -fsSL -o jq.tar.gz https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-1.8.1.tar.gz \
 && echo "2be64e7129cecb11d5906290eba10af694fb9e3e7f9fc208a311dc33ca837eb0  jq.tar.gz" | sha256sum -c - \
 && tar xzf jq.tar.gz && cd jq-1.8.1 \
 && ./configure --disable-docs --disable-shared --without-oniguruma && make -j"$(nproc)" && strip jq

FROM alpine:3.22
RUN apk add --no-cache curl python3
COPY --from=jq /jq-1.8.1/jq /usr/local/bin/jq
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
# OpenWrt's busybox has neither `stat` nor `timeout` (`date -r`, `wc -c` and `ls -l` do the job).
RUN rm -f /bin/stat /usr/bin/stat /bin/timeout /usr/bin/timeout \
 && ! command -v stat && ! command -v timeout \
 && jq --version && ! jq -n '"a" | test("a")' 2>/dev/null
# GATYGO_XRAY: the tests run this image's xray (or the stub in front of it), not a downloaded core
ENV GATYGO_LIB=/src/gatygo/files/lib \
    GATYGO_XRAY=xray \
    FIXTURES=/src/tests/fixtures \
    XRAY_LOCATION_ASSET=/src/tests/fixtures/geo
WORKDIR /src
