#!/bin/zsh
# Builds and runs the SenseVoiceEngine engine-level probe.
#
# This compiles Sources/FocusVoice/SenseVoiceEngine.swift together with
# scripts/sensevoice-engine-probe/ProbeMain.swift (the app's main.swift cannot
# be reused for a CLI test). Only `swiftc` + `clang` are used, so the SwiftPM
# build directory is never touched and no `swift build` lock is taken.
#
#   scripts/build-engine-probe.sh [audio.wav]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD_DIR="${FOCUSVOICE_PROBE_BUILD_DIR:-/tmp/focusvoice-engine-probe}"
mkdir -p "$BUILD_DIR/module/CSherpa"

HEADER="$ROOT/Sources/CSherpa/include/FocusVoiceSherpa.h"
cat > "$BUILD_DIR/module/CSherpa/module.modulemap" <<MODULEMAP
module CSherpa {
    header "$HEADER"
    export *
}
MODULEMAP

echo "== compiling C shim =="
clang -O2 -I "$ROOT/Sources/CSherpa/include" -c "$ROOT/Sources/CSherpa/FocusVoiceSherpa.c" -o "$BUILD_DIR/FocusVoiceSherpa.o"

echo "== compiling engine probe =="
# The DSH sandbox blocks the default clang module cache under /var/folders.
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swiftc -O -swift-version 5 -parse-as-library \
  "$ROOT/Sources/FocusVoice/SenseVoiceEngine.swift" \
  "$ROOT/scripts/sensevoice-engine-probe/ProbeMain.swift" \
  "$BUILD_DIR/FocusVoiceSherpa.o" \
  -I "$BUILD_DIR/module" \
  -L "$ROOT/Vendor/sherpa" -lsherpa-onnx-c-api \
  -Xlinker -rpath -Xlinker "$ROOT/Vendor/sherpa" \
  -o "$BUILD_DIR/sensevoice-engine-probe"

echo "== running =="
"$BUILD_DIR/sensevoice-engine-probe" "$@"
