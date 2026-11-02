#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/logs
LOG="$PWD/.build/logs/verify-$(date +%Y%m%d-%H%M%S).log"
STEP=setup
CHILD=""
cancel() {
    trap - INT TERM
    if [[ -n "$CHILD" ]]; then
        pkill -TERM -P "$CHILD" 2>/dev/null || true
        kill -TERM "$CHILD" 2>/dev/null || true
        wait "$CHILD" || true
    fi
    printf 'failed: %s (cancelled)\nlog: %s\n' "$STEP" "$LOG" >&2
    exit 130
}
trap cancel INT TERM
run() {
    STEP="$1"; shift
    "$@" >>"$LOG" 2>&1 &
    CHILD=$!
    local result=0
    wait "$CHILD" || result=$?
    CHILD=""
    if (( result != 0 )); then
        printf 'failed: %s\n' "$STEP" >&2
        if rg -m 12 ':[0-9]+:[0-9]+: error:|Test Case .*failed|error: fatalError' "$LOG" >/dev/null; then
            rg -m 12 ':[0-9]+:[0-9]+: error:|Test Case .*failed|error: fatalError' "$LOG" | cut -c1-350 >&2
        else
            tail -n 10 "$LOG" | cut -c1-350 >&2
        fi
        printf 'log: %s\n' "$LOG" >&2
        exit "$result"
    fi
}
run 'macOS tests' swift test
if [[ "${1:-}" != --macos ]]; then
    run 'iOS package build' xcodebuild -scheme TokenEspressoUI -destination 'generic/platform=iOS' \
        -derivedDataPath .build/iOS CODE_SIGNING_ALLOWED=NO build
    run 'iOS providers build' xcodebuild -scheme TokenEspressoProviders -destination 'generic/platform=iOS' \
        -derivedDataPath .build/iOS CODE_SIGNING_ALLOWED=NO build
fi
printf 'ok\n'
