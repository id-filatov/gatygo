# gatygo

**English** · [Русский](README.ru.md)

VPN client for OpenWrt 25.12. Takes an Xray-JSON subscription, runs xray with the chosen
profile and routes the whole LAN through it (nftables tproxy). Managed from one LuCI page.

## Features

- Scheduled subscription updates. Every config is checked with `xray run -test`; a failed update
  keeps the working one.
- Profiles as buttons with response times (TCP connect to the fastest server).
- Checks whether common services open through the tunnel.
- LAN DNS goes through xray, the router's own traffic is untouched, LAN IPv6 to the internet is
  blocked. Everything is restored on stop.
- Routing, balancer and geo files come from the subscription only; no built-in rules.
- Connection caps against OOM: 600 per device, 1000 total (Advanced → Settings).
- If xray dies: no internet (default) or direct.
- Plain error messages: expired subscription, device limit, client not recognised.

## Requirements

- OpenWrt 25.12 (apk, firewall4).
- ~40 MB free on overlay (the xray core is 35 MB).
- 256 MB RAM.
- A subscription that returns Xray-JSON. If the panel filters by User-Agent, set it in
  Advanced → Settings.

## Install

```sh
wget -qO- https://raw.githubusercontent.com/id-filatov/gatygo/main/install.sh | sh
```

The script checks the router (OpenWrt version, conflicting proxy packages, dependencies in the
feeds, free space, dnsmasq, an xray build for the architecture) and installs nothing if a check
fails. Then it installs the latest release and the xray core. The service is not enabled.

- `--version <tag>` for a specific release; `install.sh gatygo-*.apk luci-app-gatygo-*.apk` for
  local files.
- A custom-built image usually has no kmods feed: add
  `kmod-nft-tproxy kmod-nft-connlimit jq curl ca-bundle unzip ip-full` to the image.
- By hand: both `.apk` from [releases](https://github.com/id-filatov/gatygo/releases/latest), then
  `apk add --allow-untrusted gatygo-*.apk luci-app-gatygo-*.apk`.

Then: LuCI → **Services → gatygo**, paste the link, **Connect**.

- Update: run the script again, settings are kept.
- Drop the subscription: **Delete** in Advanced → Settings or `gatygo forget`.
- Remove: `apk del luci-app-gatygo gatygo`; `/etc/gatygo` and `/etc/config/gatygo` stay.

## The xray core

Not the feed's `xray-core`. Each gatygo release pins an
[Xray-core](https://github.com/XTLS/Xray-core) version and the SHA256 of its archives
(`gatygo/files/lib/core.pin`). The router downloads the archive for its architecture, checks
the hash, and only then unpacks and runs it. The core is updated only with gatygo.

## Command line

```
gatygo start|stop|restart        service control
gatygo connect <url>             store the link, enable and start
gatygo forget                    delete the subscription, reset settings
gatygo update                    update the subscription
gatygo select <profile>          switch profile
gatygo status                    JSON: state, profile, subscription, last result
gatygo check [fresh]             JSON: services reachable through the tunnel
gatygo ping [kept]               JSON: profile response times
gatygo nodes                     JSON: outbounds, balancer choice, traffic
gatygo log [N]                   last N lines of the xray and gatygo log
```

Settings in `/etc/config/gatygo`, state in `/etc/gatygo`, logs via `logread -e gatygo`,
`logread -e xray`.

## Ports

- 12345 tproxy, 5353 DNS: LAN traffic.
- 10085 xray API, 10808 SOCKS for the services check: `127.0.0.1` only, SOCKS is
  password-protected (`/etc/gatygo`, 0600).
- The subscription link, user id and HWID never go to the log.

## Development

```sh
tests/run.sh                     # unit tests in Docker (busybox ash, jq, the pinned xray)
tests/run.sh test_core.sh        # one file
tools/build-apk.sh               # build both .apk with the OpenWrt SDK
tests/vm/run.sh [gatygo.apk]     # e2e on an OpenWrt VM
tools/pin-core.sh v26.9.9        # pin another xray version
tools/release.sh                 # release from main; CI builds the packages
```

POSIX sh for busybox ash. Test fixtures are synthetic.

## License

MIT
