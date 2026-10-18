#!/bin/sh
# dash, vim and lg2 are only published for devices (arm64) and Intel
# simulators, so an Apple-silicon simulator can't load them. The code is the
# same; only the platform in the Mach-O header differs. This copies the
# device builds into ios/Frameworks-sim/ with the platform changed to the
# iOS simulator, and signs them ad hoc. For local testing only: the result
# is never shipped. Run scripts/fetch-ios-system.sh first, then
# `xcodegen generate`; simulator builds embed these when they exist.
set -eu

cd "$(dirname "$0")/.."
out=Frameworks-sim
rm -rf "$out"
mkdir -p "$out"

for name in dash dashA dashB dashC dashD dashE vim lg2; do
    src="Frameworks/$name.xcframework/ios-arm64/$name.framework"
    if [ ! -d "$src" ]; then
        echo "missing $src; run scripts/fetch-ios-system.sh first" >&2
        exit 1
    fi
    dst="$out/$name.framework"
    ditto "$src" "$dst"
    rm -rf "$dst/_CodeSignature"

    bin="$dst/$name"
    # Keep the deployment target and SDK the binary was built with.
    set -- $(vtool -show-build "$bin" | awk '/minos/ { m = $2 } /sdk/ { s = $2 } END { print m, s }')
    vtool -set-build-version iossim "$1" "$2" -replace -output "$bin.tmp" "$bin"
    mv "$bin.tmp" "$bin"

    plutil -replace CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' "$dst/Info.plist"
    codesign --force --sign - "$dst"
    echo "retagged $name"
done
