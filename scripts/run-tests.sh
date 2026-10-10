#!/usr/bin/env bash
# Runs PerfectRouter unit tests and PerfectRouterUITests on a named iPhone simulator.
#
# Usage:
#   scripts/run-tests.sh
#   scripts/run-tests.sh "iPhone 16"
#
# The UI tests launch the app with -UITestStubServices. Pass the simulator
# name Simulator.app shows (Xcode ▸ Window ▸ Devices and Simulators).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIMULATOR_NAME="${1:-iPhone 16}"
LOG="${TMPDIR:-/tmp}/perfectrouter-tests.log"
RESULT="${TMPDIR:-/tmp}/perfectrouter-tests.xcresult"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is not on PATH. Install Xcode and run this script on a Mac."
  exit 1
fi

rm -rf "$RESULT"

echo "Running unit tests and UI tests"
echo "  scheme: PerfectRouter"
echo "  simulator: ${SIMULATOR_NAME}"
echo

set +e
xcodebuild test \
  -project PerfectRouter.xcodeproj \
  -scheme PerfectRouter \
  -destination "platform=iOS Simulator,name=${SIMULATOR_NAME}" \
  -resultBundlePath "$RESULT" \
  2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e

echo
echo "Summary (${SIMULATOR_NAME})"

awk '
  /Test [Cc]ase .* passed / { passed++ }
  /Test [Cc]ase .* failed / { failed++; print "  FAIL " $0 }
  /\*\* TEST SUCCEEDED \*\*/ { succeeded = 1 }
  /\*\* TEST FAILED \*\*/ { failed_suite = 1 }
  END {
    printf "  passed: %d\n", passed + 0
    printf "  failed: %d\n", failed + 0
    if (succeeded && failed + 0 == 0) {
      print "  result: PASS"
    } else if (failed_suite || failed + 0 > 0) {
      print "  result: FAIL"
    } else if (passed + 0 == 0) {
      print "  result: FAIL (no tests ran)"
    } else {
      print "  result: FAIL"
    }
  }
' "$LOG"

exit "$STATUS"
