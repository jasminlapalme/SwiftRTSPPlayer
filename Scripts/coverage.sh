#!/usr/bin/env bash
set -euo pipefail

# Prints the line coverage of Sources/ as a percentage, e.g. "30.47".
# Reads the profile left behind by a previous run — it does not run the tests:
#
#   swift test --enable-code-coverage && ./Scripts/coverage.sh
#
# Pass --report for the per-file table instead of the bare number.

codecov_json=$(swift test --show-codecov-path)
codecov_dir=$(dirname "$codecov_json")
profdata="$codecov_dir/default.profdata"

if [ ! -f "$profdata" ]; then
	echo "error: no coverage profile at $profdata. Run: swift test --enable-code-coverage" >&2
	exit 1
fi

# The test bundle sits next to the codecov directory; its layout differs
# between the .xctest bundle on macOS and the bare executable elsewhere.
build_dir=$(dirname "$codecov_dir")
binary=$(find "$build_dir" -maxdepth 4 -type f -path "*PackageTests.xctest/Contents/MacOS/*" | head -1)
if [ -z "$binary" ]; then
	binary=$(find "$build_dir" -maxdepth 1 -type f -name "*PackageTests.xctest" | head -1)
fi

if [ -z "$binary" ]; then
	echo "error: could not find the test binary under $build_dir" >&2
	exit 1
fi

# Tests and checked-out dependencies are not the code under measurement.
ignore='(Tests|\.build)/'

if [ "${1:-}" = "--report" ]; then
	exec xcrun llvm-cov report "$binary" -instr-profile="$profdata" -ignore-filename-regex="$ignore"
fi

xcrun llvm-cov export "$binary" \
	-instr-profile="$profdata" \
	-ignore-filename-regex="$ignore" \
	-summary-only \
	| jq -r '.data[0].totals.lines.percent' \
	| xargs printf '%.2f\n'
