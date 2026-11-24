#!/bin/sh
# Cut a release from main. The version is the current UTC time as yyyymmdd.hhmm (apk rejects a
# dash: "20260916-2310" is invalid, "20260916.2310-r1" is fine and sorts after 0.1.0). It is
# written into both package Makefiles, committed, tagged v<version> and pushed; CI builds the
# .apk files for the tag and attaches them to the GitHub release (.github/workflows/build.yml).
# --pre cuts a pre-release from the current branch instead: "(pre-release)" ends the commit's
# subject, and CI marks the release so; releases/latest (the page, install.sh) never offers it.
# Usage: tools/release.sh [--pre]
set -eu
cd "$(dirname "$0")/.."
PRE=''
case ${1:-} in
    '') [ $# = 0 ] ;;
    --pre) [ $# = 1 ] && PRE=' (pre-release)' ;;
    *) false ;;
esac || { echo "usage: tools/release.sh [--pre]" >&2; exit 2; }
B=$(git branch --show-current)
[ -n "$B" ] || { echo "not on a branch" >&2; exit 1; }
[ -n "$PRE" ] || [ "$B" = main ] || { echo "release from main only" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean" >&2; exit 1; }
git fetch -q origin "$B" 2>/dev/null || { echo "could not fetch $B from origin: is it pushed?" >&2; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$B")" ] || { echo "$B is not in sync with origin/$B" >&2; exit 1; }
V=$(date -u +%Y%m%d.%H%M)
for f in gatygo/Makefile luci-app-gatygo/Makefile; do
    sed -i.bak "s/^PKG_VERSION:=.*/PKG_VERSION:=$V/" "$f" && rm -f "$f.bak"
    grep -q "^PKG_VERSION:=$V\$" "$f"
done
git add gatygo/Makefile luci-app-gatygo/Makefile
git commit -q -m "release: $V$PRE"
git tag -a "v$V" -m "gatygo $V$PRE"
# both or neither: a tag without its branch would be released from a commit on no branch
git push -q --atomic origin "$B" "v$V"
echo "released v$V$PRE: https://github.com/$(git remote get-url origin | sed -E 's#.*github.com[:/]##; s#\.git$##')/releases/tag/v$V"
