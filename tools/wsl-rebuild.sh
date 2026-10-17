#!/usr/bin/env bash
# wsl-rebuild.sh -- full diagnostic rebuild inside WSL (ASCII only on purpose:
# Chinese text in a Windows-side command line gets mangled by the console codepage).
#
#   wsl -d Ubuntu-24.04 -u ubuntu -- bash /mnt/d/spcntweak/tools/wsl-rebuild.sh [build-dir] [rootful]
#
# Differences from build-wsl.sh (which stays the packaging entry point):
#   * does its own sync so source visibility is printed side by side
#   * runs `make package` WITHOUT piping through tail, so compiler diagnostics survive
#   * logs everything to /mnt/d/spcntweak/.work/wsl-build.log (survives WSL restarts)
set -uo pipefail

PROJ=/mnt/d/spcntweak
LOG=$PROJ/.work/wsl-build.log
SCHEME="${2:-rootless}"
DIR="${1:-$HOME/spcn-build}"

export THEOS=$HOME/theos
export PATH="$THEOS/toolchain/linux/iphone/bin:$THEOS/bin:$PATH"

mkdir -p "$PROJ/.work"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "== toolchain =="
echo "  THEOS=$THEOS"
command -v rsync >/dev/null 2>&1 && echo "  rsync: yes" || echo "  rsync: no (tar fallback)"
"$THEOS/toolchain/linux/iphone/bin/clang" --version 2>&1 | head -1

echo "== source, Windows side =="
ls -l --time-style=+%H:%M:%S "$PROJ/ios/src/"

echo "== sync -> $DIR =="
mkdir -p "$DIR"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete --exclude '.theos/' --exclude 'packages/' "$PROJ/ios/" "$DIR/"
else
  rm -rf "$DIR"; mkdir -p "$DIR"
  (cd "$PROJ/ios" && tar cf - --exclude='.theos' --exclude='packages' .) | (cd "$DIR" && tar xf -)
fi
find "$DIR" -type f \( -name Makefile -o -name '*.plist' -o -name '*.x' -o -name '*.xm' \
  -o -name '*.h' -o -name '*.m' \) -exec sed -i 's/\r$//' {} +
ls -l --time-style=+%H:%M:%S "$DIR/src/"

echo "== make clean =="
make -C "$DIR" clean >/dev/null 2>&1 || true
rm -rf "$DIR/packages"

echo "== make package (scheme=$SCHEME) =="
if [ "$SCHEME" = "rootless" ]; then
  make -C "$DIR" -j"$(nproc)" package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
else
  make -C "$DIR" -j"$(nproc)" package FINALPACKAGE=1
fi
echo "MAKE_EXIT=$?"

echo "== artifacts =="
ls -l --time-style=+%H:%M:%S "$DIR/packages" 2>&1 || true
DYL="$DIR/.theos/obj/SpCnEmbedded.dylib"
if [ -f "$DYL" ]; then
  ls -l --time-style=+%H:%M:%S "$DYL"
  echo "-- symbol/string probes (expect node_start=1 SpCnNodeFramework=1 backendTapped=1) --"
  for s in node_start SpCnNodeFramework backendTapped NodeMobile.framework; do
    printf '   %-22s %s\n' "$s" "$(strings -a "$DYL" | grep -c -- "$s")"
  done
else
  echo "  no dylib at $DYL"
fi
echo "== log tail =="
tail -30 "$LOG"
