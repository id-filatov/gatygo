# gatygo

**English** · [Русский](README.ru.md)

VPN client for OpenWrt 25.12. Takes an Xray-JSON subscription, runs xray with the chosen
profile and routes the whole LAN through the tunnel (nftables tproxy).

> [!WARNING]
> Beta: expect bugs; behaviour and settings may change between releases.
> If xray crashes, by default the home network stays offline until the VPN is back up or turned off
> (configurable in Advanced → Settings).
> Provided as is, without warranty. Report bugs in [Issues](https://github.com/id-filatov/gatygo/issues).

## Features

- Scheduled subscription updates. Every config is checked with `xray run -test`; a failed update
  keeps the working one.
- LAN DNS goes through xray, the router's own traffic is untouched.
- Routing, balancer and geo files come from the subscription only; no built-in rules.
- Connection caps against OOM.

## Requirements

- OpenWrt 25.12 (apk, firewall4).
- ~40 MB free on overlay.
- 256 MB RAM.
- A subscription that returns Xray-JSON.
- If the VPN provider filters by User-Agent, set it in Advanced → Settings.

## Install

```sh
wget -qO- https://raw.githubusercontent.com/id-filatov/gatygo/main/install.sh | sh
```

The script checks the router (OpenWrt version, conflicting proxy packages, dependencies in the
feeds, free space, dnsmasq, an xray build for the architecture) and installs nothing if a check
fails. Then it installs the latest release and the xray core.

Then: LuCI → **Services → gatygo**, paste the link, **Connect**.

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
- 10085 xray API, 10808 SOCKS for the services check: `127.0.0.1` only.

## Development

```sh
tests/run.sh                     # unit tests in Docker (busybox ash, jq, the pinned xray)
tests/run.sh test_core.sh        # one file
tools/build-apk.sh               # build both .apk with the OpenWrt SDK
tests/vm/run.sh [gatygo.apk]     # e2e on an OpenWrt VM
tools/pin-core.sh v26.9.9        # pin another xray version
tools/release.sh                 # release from main; CI builds the packages
```

## License

MIT
