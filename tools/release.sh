#!/bin/sh
# Cut a release from main. The version is the current UTC time as yyyymmdd.hhmm (apk rejects a
# dash: "20260916-2310" is invalid, "20260916.2310-r1" is fine and sorts after 0.1.0). It is
# written into both package Makefiles, committed, tagged v<version> and pushed; CI builds the
# .apk files for the tag and attaches them to the GitHub release (.github/workflows/build.yml).
# Usage: tools/release.sh
set -eu
cd "$(dirname "$0")/.."
[ "$(git branch --show-current)" = main ] || { echo "release from main only" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean" >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main is not in sync with origin/main" >&2; exit 1; }
V=$(date -u +%Y%m%d.%H%M)
for f in gatygo/Makefile luci-app-gatygo/Makefile; do
    sed -i.bak "s/^PKG_VERSION:=.*/PKG_VERSION:=$V/" "$f" && rm -f "$f.bak"
    grep -q "^PKG_VERSION:=$V\$" "$f"
done
git add gatygo/Makefile luci-app-gatygo/Makefile
git commit -q -m "release: $V"
git tag -a "v$V" -m "gatygo $V"
git push -q origin main "v$V"
echo "released v$V: https://github.com/$(git remote get-url origin | sed -E 's#.*github.com[:/]##; s#\.git$##')/releases/tag/v$V"
