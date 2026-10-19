#!/usr/bin/env bash
# Build dist/quackShot.app.
#
#   scripts/build.sh [debug|release] [--install] [--open] [--zip]
#
#   --install  copy to /Applications (macOS remembers the Screen Recording
#              grant per app location and signature, so a stable install
#              path avoids re-granting after every build you run from dist/)
#   --open     launch the result
#   --zip      also write dist/quackShot-<version>-macos.zip
#
# The bundle is ad-hoc signed. Each rebuild therefore has a new signature,
# and macOS treats it as a different app for Screen Recording: the first
# launch after a rebuild shows quackShot's permission guide again.
set -euo pipefail

CONFIG=release
INSTALL=0
OPEN=0
ZIP=0
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --install) INSTALL=1 ;;
        --open) OPEN=1 ;;
        --zip) ZIP=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/quackShot"

APP="$ROOT/dist/quackShot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/quackShot"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$APP"

LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
[[ -x "$LSREG" ]] && "$LSREG" -f "$APP" 2>/dev/null || true

if [[ $ZIP -eq 1 ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
    ditto -c -k --keepParent "$APP" "$ROOT/dist/quackShot-$VERSION-macos.zip"
    echo "==> dist/quackShot-$VERSION-macos.zip"
fi

if [[ $INSTALL -eq 1 ]]; then
    DEST=/Applications/quackShot.app
    echo "==> installing to $DEST"
    # A running copy keeps the old binary mapped; quit it first.
    osascript -e 'tell application id "io.github.chengmingbo.quackShot" to quit' >/dev/null 2>&1 || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    [[ -x "$LSREG" ]] && "$LSREG" -f "$DEST" 2>/dev/null || true
    APP="$DEST"
fi

echo "==> built $APP"
echo "    CLI: \"$APP/Contents/MacOS/quackShot\" --help"
[[ $OPEN -eq 1 ]] && open "$APP"
exit 0
