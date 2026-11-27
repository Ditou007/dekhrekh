#!/usr/bin/env bash
# ./test.sh   build and run the unit checks in Tests/ against Sources/Shared
set -euo pipefail

cd "$(dirname "$0")"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# An empty config and a scratch state folder, so the checks never read or write the real ones.
echo '{"stateDir": "'"$OUT"'/state"}' > "$OUT/config.json"
export DEKHREKH_CONFIG="$OUT/config.json"

swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -o "$OUT/tests" Sources/Shared/*.swift Tests/*.swift
"$OUT/tests"
