# gatygo

A VPN client for OpenWrt routers. Paste the subscription link from your VPN provider, pick a
country, and the whole home network goes through the tunnel. No per-device setup.

gatygo takes an **Xray-JSON subscription** (a list of ready xray configs, one per country or
profile), runs xray with the one you picked and proxies the LAN transparently with nftables
tproxy. Everything is driven from one LuCI page; settings and the log live behind the gear.

## What it does

- Downloads the subscription on a schedule and tests every new config with `xray run -test`
  before using it. A failed update never touches the working config.
- Shows every profile of the subscription as a button with its response time (TCP connect from
  the router to the profile's fastest server).
- Checks that the usual services open through the tunnel (the probes go through xray the same
  way the LAN does).
- Redirects the LAN's DNS into xray, leaves the router's own traffic alone, drops the LAN's
  IPv6 traffic to the internet while the tunnel is up (it would go around the tunnel), and puts
  everything back on stop.
- Uses the routing, balancer and geo files the subscription names. gatygo has no built-in
  routing rules or server lists of its own.
- Says what went wrong in plain words: expired subscription, device limit, a server that did
  not recognise the client, and so on.
- Keeps xray from running the router out of memory: every open connection costs it 50–70 KB,
  so a device (a torrent client, say) gets at most 600 connections through the VPN at a time and
  the whole home 1000; new ones over that are refused, the ones already open stay. Both numbers
  are settings (Advanced → Settings).
- If xray quits for good (the router ran out of memory, say), the page says when and why. What
  the home network gets meanwhile is a setting: no internet until the VPN is back, so nothing
  goes around it (the default), or the regular internet.

## Requirements

- OpenWrt 25.12 (apk packages, firewall4/nftables).
- About 40 MB free on the overlay: gatygo's scripts are small, the xray core is 35 MB.
- 256 MB of RAM: xray takes 40–60 MB idle, depending on the subscription, and about 70 MB more
  when the home uses all the connections the caps allow.
- A subscription that answers with Xray-JSON. Some provider panels send it only to clients they
  know by User-Agent: the name gatygo introduces itself with is a setting (Advanced → Settings).

## Install

On the router:

```sh
wget -qO- https://raw.githubusercontent.com/id-filatov/gatygo/main/install.sh | sh
```

(`wget` is the stock image's uclient-fetch; `curl` is not in it yet.)

The script first checks the router and installs nothing until every check has passed: that
this OpenWrt is 25.12, that no other transparent-proxy package owns the same rules, that the
feeds can actually serve what gatygo needs (`jq`, `curl`, `ca-bundle`, `unzip`, `ip-full`,
`kmod-nft-tproxy`, `kmod-nft-connlimit`), that there is room on the overlay, that dnsmasq runs,
and that XTLS builds an xray for this architecture. A stock image already has the rest. Then it
installs both packages of the latest release, apk pulls the dependencies, and the pinned xray
core is downloaded and checked, so nothing is left to fetch but the subscription itself. Nothing
is switched on and no subscription is written.

An image built by hand is the one case that usually fails, and the script says so instead of
letting apk abort halfway: kernel modules come from the feed of one exact kernel build, and
downloads.openwrt.org has no modules for a kernel it did not build. Add `kmod-nft-tproxy
kmod-nft-connlimit jq curl ca-bundle unzip ip-full` to the image and run the script again.

`install.sh --version v20260918.1851` takes that release instead of the latest, and
`install.sh gatygo-*.apk luci-app-gatygo-*.apk` installs local files without downloading
anything.

By hand instead: download `gatygo-<version>.apk` and `luci-app-gatygo-<version>.apk` from the
[latest release](https://github.com/id-filatov/gatygo/releases/latest), copy them to the
router and install:

```sh
scp -O gatygo-*.apk luci-app-gatygo-*.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'apk add --allow-untrusted /tmp/gatygo-*.apk /tmp/luci-app-gatygo-*.apk'
```

Then open **Services → gatygo** in LuCI, paste the subscription link and press **Connect**.
The subscription brings the config, the list of countries and the geo files; the xray core
is already there when the script installed it, and is downloaded on the first start otherwise.

To update, run the script again (it keeps `/etc/config/gatygo`). To remove:
`apk del luci-app-gatygo gatygo` (the router's DNS and firewall are put back, the core is
deleted; `/etc/gatygo` and `/etc/config/gatygo` stay until you delete them).

## The xray core

gatygo does not use the feed's `xray-core` package. Every gatygo release pins one
[XTLS/Xray-core](https://github.com/XTLS/Xray-core) release together with the SHA256 of its
archive for each architecture (`gatygo/files/lib/core.pin`). The router downloads the archive
for its architecture, checks the SHA256, unpacks only the binary into `/usr/lib/gatygo/core`
and tries it before it replaces the one in place. Nothing is unpacked or run before the hash
matched. A new core arrives only with a new gatygo release; there is no separate core update.

Without access to GitHub the first start fails with a message on the page; a core already in
place keeps working.

## Command line

```
gatygo start|stop|restart        service control
gatygo connect <url>             first run: store the link, enable and start
gatygo update                    run the subscription update cycle now
gatygo select <profile>          switch to a profile and apply it
gatygo status                    JSON: state, profile, subscription facts, last result
gatygo check [fresh]             JSON: do the usual services open through the tunnel
gatygo ping [kept]               JSON: the response time of every profile
gatygo nodes                     JSON: outbounds with the balancer's choice and traffic
gatygo log [N]                   the last N lines of xray and gatygo from the system log
```

Settings are in `/etc/config/gatygo`, state in `/etc/gatygo` (kept over sysupgrade), logs in
the system log (`logread -e gatygo`, `logread -e xray`).

## What listens where

- tproxy (12345) and DNS (5353) inbounds take the LAN's redirected traffic.
- The xray API (10085) and a SOCKS inbound for the services check (10808) listen on
  `127.0.0.1` only. The SOCKS inbound asks for a password that is made on the router and kept
  in `/etc/gatygo` (mode 0600); the API exposes statistics and the balancer's state, not the
  outbounds.
- The subscription, the config and the secrets are readable by root only. The subscription
  link, user id and hardware id never go to the log.

## Development

```sh
tests/run.sh                     # unit tests (POSIX sh, in Docker: busybox ash, jq, the pinned xray)
tests/run.sh test_core.sh        # one file
tools/build-apk.sh               # build both .apk with the OpenWrt SDK container
tests/vm/run.sh [gatygo.apk]     # end-to-end on an OpenWrt VM (see the header of the script)
tools/pin-core.sh v26.9.9        # pin another xray release: core.pin + the test image
tools/release.sh                 # tag a release from main; CI builds and attaches the packages
```

The scripts are POSIX sh for busybox ash; OpenWrt's `jq` has no regular expressions and its
`curl` is a small build, and the unit test image is trimmed the same way. The test fixtures
are synthetic (`tools/gen-fixture.py`, `tools/gen-geodat.py`).

## License

MIT
