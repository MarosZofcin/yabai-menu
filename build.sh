#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_ROOT=${1:-"$PROJECT_DIR/dist"}
APP_NAME="Yabai Menu.app"
APP_DIR="$OUTPUT_ROOT/$APP_NAME"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")
ZIP_PATH="$OUTPUT_ROOT/Yabai-Menu-$VERSION.zip"

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

# Finder and some copy tools can attach metadata that macOS code signing
# explicitly rejects. Remove it before signing and never include it in the
# distributable archive.
xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

if xattr -lr "$APP_DIR" | grep -Eq 'com\.apple\.(FinderInfo|ResourceFork)'; then
    echo "Forbidden Finder metadata remains in $APP_DIR" >&2
    exit 1
fi

rm -f "$ZIP_PATH"
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
    "$APP_DIR" "$ZIP_PATH"

if unzip -Z1 "$ZIP_PATH" | grep -q '^__MACOSX/'; then
    echo "Unexpected resource metadata directory found in $ZIP_PATH" >&2
    exit 1
fi

# Verify the artifact users actually download, not only the source bundle.
VERIFY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yabai-menu-verify.XXXXXX")
cleanup() {
    rm -rf "$VERIFY_DIR"
}
trap cleanup EXIT HUP INT TERM

# Extract with normal macOS behavior so the test catches metadata that would be
# restored on a user's machine.
ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
VERIFIED_APP="$VERIFY_DIR/$APP_NAME"

test -x "$VERIFIED_APP/Contents/MacOS/YabaiMenu"
codesign --verify --deep --strict "$VERIFIED_APP"
plutil -lint "$VERIFIED_APP/Contents/Info.plist" >/dev/null
"$VERIFIED_APP/Contents/MacOS/YabaiMenu" --self-test

if xattr -lr "$VERIFIED_APP" | grep -Eq 'com\.apple\.(FinderInfo|ResourceFork)'; then
    echo "Forbidden Finder metadata was restored from $ZIP_PATH" >&2
    exit 1
fi

echo "$APP_DIR"
echo "$ZIP_PATH"
