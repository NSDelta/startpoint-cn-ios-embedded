#!/var/jb/usr/bin/zsh
# Node.js wrapper with iOS-optimized V8 flags

NODE_BIN="/var/jb/usr/local/lib/nodejs/node"

# V8 flags required for stable iOS execution
V8_FLAGS="--no-wasm-code-gc --no-opt --no-sparkplug --single-threaded --liftoff --no-wasm-tier-up"

exec "$NODE_BIN" $V8_FLAGS "$@"
