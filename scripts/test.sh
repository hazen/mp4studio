#!/bin/zsh
# Runs the unit and end-to-end tests with the Command Line Tools (see README).
set -euo pipefail
cd "$(dirname "$0")/.."
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
