#!/bin/sh
# Build the test image and run unit tests inside it.
# Usage: tests/run.sh                 # all tests/unit/test_*.sh
#        tests/run.sh test_hwid.sh    # only the named test files
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)

docker build -q -t gatygo-test -f "$ROOT/tests/Dockerfile" "$ROOT/tests" >/dev/null

TESTS=""
for t in "$@"; do TESTS="$TESTS /src/tests/unit/$t"; done

docker run --rm -v "$ROOT:/src:ro" -e "TESTS=$TESTS" gatygo-test sh -c '
    rc=0
    for t in ${TESTS:-/src/tests/unit/test_*.sh}; do
        sh "$t" || rc=1
    done
    exit $rc'
