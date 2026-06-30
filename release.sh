#!/bin/zsh
set -euo pipefail
DEVICE_TARGET="iphone:clang:16.5:14.0"
MODE="${1:-}"

PKG_VERSION=$(sed -n 's/^Version: //p' control | head -n 1)
echo "==> Building Liquid (Gl)ass v${PKG_VERSION}"
echo "==> Target: ${DEVICE_TARGET}"

BUILT=()

if [[ "$MODE" == "rootless" || -z "$MODE" ]]; then
    echo "==> Building rootless package..."
    make clean
    make package ARCHS="arm64 arm64e" TARGET="$DEVICE_TARGET" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
    BUILT+=("rootless")
fi

if [[ "$MODE" == "rootful" || -z "$MODE" ]]; then
    echo "==> Building rootful package..."
    make clean
    make package ARCHS="arm64 arm64e" TARGET="$DEVICE_TARGET" FINALPACKAGE=1
    BUILT+=("rootful")
fi

# this only works if you got the roothide theos fork: https://github.com/roothide/theos
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"
if [[ "$MODE" == "roothide" || -z "$MODE" ]]; then
    echo "==> Building roothide package..."
    make clean
    make package ARCHS="arm64 arm64e" TARGET="$DEVICE_TARGET" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
    BUILT+=("roothide")
fi

echo ""
echo "==> Done! Built ${#BUILT[@]} package(s): ${BUILT[*]}"
ls -lh packages/*.deb 2>/dev/null || echo "  (no packages found)"
