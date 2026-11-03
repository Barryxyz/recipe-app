#!/bin/bash
# Builds the app, installs it on the connected iPhone and launches it.
#
# Why not Xcode's Run button: Xcode 16.4 can't read iOS 27's debug symbols
# ("dyld_shared_cache_extract_dylibs failed"), so Run fails before installing.
# Installing with devicectl skips the symbol step. No debugger, but the app runs.
#
# Usage: ./scripts/run-on-iphone.sh   (iPhone plugged in and unlocked)

set -euo pipefail
cd "$(dirname "$0")/../ios"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

DEVICE=$(xcrun devicectl list devices 2>/dev/null | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | sed -n 1p)
[ -n "$DEVICE" ] || { echo "No iPhone found. Plug it in and unlock it."; exit 1; }
UDID=$(xcrun devicectl device info details --device "$DEVICE" 2>/dev/null | awk '/udid:/ && !u {u=$NF} END {print u}')

xcodegen --quiet
xcodebuild -project Fridge.xcodeproj -scheme Fridge -destination "id=$UDID" \
  -derivedDataPath build/dd -allowProvisioningUpdates -quiet build

xcrun devicectl device install app --device "$DEVICE" build/dd/Build/Products/Debug-iphoneos/Fridge.app >/dev/null
xcrun devicectl device process launch --device "$DEVICE" com.barryxyz.fridge
