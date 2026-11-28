#!/bin/sh
# Execute the same role/failure suite through the real native UCI CLI.
set -eu
[ "$#" -eq 1 ] || { echo "Usage: $0 UCI_BINARY" >&2; exit 1; }
exec sh "$(dirname -- "$0")/test-uci-defaults.sh" "$1"
