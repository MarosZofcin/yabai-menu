#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_ROOT=${1:-"$PROJECT_DIR/dist"}
APP_NAME="Yabai Menu.app"
APP_DIR="$OUTPUT_ROOT/$APP_NAME"

cd "$PROJECT_DIR"

# Prefer the stable compatibility SDK when Command Line Tools contains a
# newer compiler paired with a slightly older preview SDK.
if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]; then
    SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
    export SDKROOT
fi
CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-cache"
SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swiftpm-cache"
export CLANG_MODULE_CACHE_PATH SWIFTPM_MODULECACHE_OVERRIDE

swift build -c release --disable-sandbox

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/release/YabaiMenu" "$APP_DIR/Contents/MacOS/YabaiMenu"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod 755 "$APP_DIR/Contents/MacOS/YabaiMenu"

codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "$APP_DIR"
