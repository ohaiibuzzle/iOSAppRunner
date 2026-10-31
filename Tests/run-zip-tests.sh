#!/bin/sh
# Usage: run-zip-tests.sh [path/to/ZipExtractor.swift]
set -e
here=$(cd "$(dirname "$0")" && pwd)
src=${1:-$here/../Host/ZipExtractor.swift}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
swiftc -parse-as-library -o "$tmp/zip_tests" "$src" "$here/zip_extractor_tests.swift"
"$tmp/zip_tests"
