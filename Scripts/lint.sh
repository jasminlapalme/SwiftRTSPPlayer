#!/usr/bin/env bash
set -euo pipefail

if ! command -v swiftlint >/dev/null 2>&1; then
	echo "error: SwiftLint is not installed. Install it with: brew install swiftlint"
	exit 127
fi

swiftlint lint --strict --no-cache --config .swiftlint.yml
