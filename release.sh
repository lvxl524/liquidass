#!/bin/zsh
set -e
DEVICE_TARGET="iphone:clang:16.5:14.0"
if [[ "$1" == "rootless" || -z "$1" ]]; then
    make clean
    make package ARCHS="arm64 arm64e" TARGET="$DEVICE_TARGET" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
fi
if [[ "$1" == "rootful" || -z "$1" ]]; then
    make clean
    make package ARCHS="arm64 arm64e" TARGET="$DEVICE_TARGET" FINALPACKAGE=1
fi
# this only works if you got the roothide theos fork: https://github.com/roothide/theos
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"
if [[ "$1" == "roothide" || -z "$1" ]]; then
    make clean
    make package ARCHS="arm64 arm64e" TARGET="$DEVICE_TARGET" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
fi
