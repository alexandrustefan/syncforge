#!/bin/bash
# Builds SyncForge.app from source.
#
#   scripts/build.sh              Release build -> build/SyncForge.app
#   scripts/build.sh --debug      Debug build
#   scripts/build.sh --install    Release build, then copy to ~/Applications
#   scripts/build.sh --test       Run the automated test suite first
#
# Signing: uses $SYNCFORGE_SIGN_IDENTITY, else the "SyncForge Local Signing" certificate if it
# exists (see scripts/create-signing-identity.sh), else ad-hoc. A stable identity keeps macOS
# privacy permissions (System Audio Recording, Microphone) across rebuilds; with ad-hoc signing
# macOS may ask again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=Release
INSTALL=0
TEST=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=Debug ;;
    --install) INSTALL=1 ;;
    --test) TEST=1 ;;
    *) echo "unknown option $arg"; exit 2 ;;
  esac
done

IDENTITY="${SYNCFORGE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-certificate -c "SyncForge Local Signing" >/dev/null 2>&1; then
  IDENTITY="SyncForge Local Signing"
fi
IDENTITY="${IDENTITY:--}"

command -v xcodegen >/dev/null || { echo "XcodeGen is required: brew install xcodegen"; exit 1; }

if [[ $TEST == 1 ]]; then
  (cd SyncForgeKit && swift test -c release)
fi

xcodegen generate --quiet
mkdir -p build
echo "Building $CONFIG (signing identity: $IDENTITY)…"
xcodebuild -project SyncForge.xcodeproj -scheme SyncForge -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
  build > build/xcodebuild.log 2>&1 || { grep -E "error:" build/xcodebuild.log | sort -u; echo "Build failed — see build/xcodebuild.log"; exit 1; }

APP="build/DerivedData/Build/Products/$CONFIG/SyncForge.app"
rm -rf build/SyncForge.app
cp -R "$APP" build/SyncForge.app
if [[ "$IDENTITY" != "-" ]]; then
  # Re-sign with the hardened runtime and entitlements (Xcode disables the runtime for ad-hoc).
  codesign --force --deep --options runtime --timestamp=none \
    --entitlements App/SyncForge/Support/SyncForge.entitlements -s "$IDENTITY" build/SyncForge.app
fi
codesign --verify --verbose=1 build/SyncForge.app 2>&1 | tail -1
echo "Built build/SyncForge.app"

if [[ $INSTALL == 1 ]]; then
  mkdir -p "$HOME/Applications"
  osascript -e 'tell application "SyncForge" to quit' >/dev/null 2>&1 || true
  rm -rf "$HOME/Applications/SyncForge.app"
  cp -R build/SyncForge.app "$HOME/Applications/SyncForge.app"
  echo "Installed to ~/Applications/SyncForge.app"
fi
