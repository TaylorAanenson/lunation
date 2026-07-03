#!/usr/bin/env bash
# run_tests.sh — run the full lunation test suite (daemon + menu-bar app).
#
#   ./run_tests.sh          # run everything
#
# Uses stock /usr/bin/python3 (no venv/pytest) to match the daemon's runtime.
# Exits non-zero if any group fails.

set -uo pipefail
cd "$(dirname "$0")"

PY="${PYTHON:-/usr/bin/python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python3

fail=0
run() {  # label, command...
  echo
  echo "=== $1 ==="
  if "${@:2}"; then
    echo "--- $1: PASS"
  else
    echo "--- $1: FAIL"
    fail=1
  fi
}

run "daemon unit tests"        "$PY" daemon/test_lunation.py
run "daemon decision tests"    "$PY" daemon/test_decision.py

# Menu-bar app (Swift) — needs Xcode. Skipped, not failed, where it's unavailable
# (e.g. CI without Xcode), so the daemon suite stays runnable everywhere.
if command -v xcodebuild >/dev/null 2>&1; then
  run "menu-bar app tests" xcodebuild test \
    -project MenuBarApp/Lunation.xcodeproj -scheme LunationTests \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet
else
  echo
  echo "=== menu-bar app tests ==="
  echo "--- SKIPPED (xcodebuild not found)"
fi

echo
if [[ "$fail" -eq 0 ]]; then
  echo "ALL TESTS PASSED"
else
  echo "SOME TESTS FAILED" >&2
fi
exit "$fail"
