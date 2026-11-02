#!/bin/zsh
# Build the daemon binary and the menu bar app into ./build.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
SHARED=(Sources/Shared/*.swift)
FLAGS=(-O -swift-version 5)

echo "==> daemon"
swiftc "${FLAGS[@]}" -o build/fence-daemon "${SHARED[@]}" Sources/Daemon/*.swift \
    -framework Network -framework SystemConfiguration

APP="build/Fence.app"
echo "==> app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc "${FLAGS[@]}" -o "$APP/Contents/MacOS/Fence" "${SHARED[@]}" Sources/App/*.swift \
    -framework AppKit
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "==> done: build/fence-daemon, $APP"
