#!/bin/sh
# Build the lvim-rest daemon into core/build/lvim-rest-daemon — the path the Lua loader
# (lua/lvim-rest/backend/rpc.lua) probes first. Requires a Rust toolchain (cargo). Without the
# daemon the plugin still works: it falls back to curl for HTTP/GraphQL (see :checkhealth lvim-rest).
#
#   sh core/build.sh
#
set -e
cd "$(dirname "$0")"

cargo build --release "$@"

mkdir -p build
cp -f target/release/lvim-rest-daemon build/lvim-rest-daemon
echo "installed build/lvim-rest-daemon"
