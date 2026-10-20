#!/bin/sh
# Builds the Cherri compiler (https://github.com/electrikmilk/cherri, GPL-2.0)
# as the `cherri` command: Frameworks/cherri.xcframework, with device and
# arm64 simulator slices. Needs Go (brew install go) and the Xcode SDKs.
#
# Cherri is a command-line program with global state and os.Exit calls, so
# the build copies it to a scratch directory and (see Cherri/):
#   - rewrites os.Exit to iosExit and main to cherriMain,
#   - adds cherri_entry.go (a C-callable cherri_run with the command's
#     streams, one run at a time, output left unsigned),
#   - generates reset_state.go, which restores every package variable before
#     each run (Cherri/genreset).
# cherri_cmd.c is the ios_system entry point (cherri_main).
#
# Usage: scripts/build-cherri.sh [work-dir]   (default: a new temp directory)
set -eu

commit=bcc0095754e2cc0baaeb4d93dae172b8153b4716

root="$(cd "$(dirname "$0")/.." && pwd)"
work="${1:-$(mktemp -d)}"
if [ -e "$work" ] && [ -n "$(ls -A "$work")" ]; then
    echo "$work isn't empty; pass a new directory" >&2
    exit 1
fi
mkdir -p "$work"
src="$work/cherri"

git clone -q https://github.com/electrikmilk/cherri "$src"
git -C "$src" checkout -q "$commit"

(cd "$root/Cherri" && go build -o "$work/genreset" ./genreset)
go install golang.org/x/tools/cmd/goimports@v0.28.0
goimports="$(go env GOPATH)/bin/goimports"

cd "$src"
files=$(ls *.go | grep -v '_test.go$')
sed -i '' -e 's/os\.Exit(/iosExit(/g' $files
sed -i '' 's/^func main() {/func cherriMain() {/' main.go
cp "$root/Cherri/cherri_entry.go" .
"$work/genreset" .
"$goimports" -w *.go
go mod download

# build <clang target> <sdk> <ios_system slice> <output directory>
build() {
    target="$1" sdk="$2" slice="$3" out="$4"
    mkdir -p "$out/cherri.framework"
    clang_cc="$(xcrun -f clang) -target $target -isysroot $sdk"
    CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$clang_cc" \
        CGO_CFLAGS="-target $target -isysroot $sdk" \
        CGO_LDFLAGS="-target $target -isysroot $sdk" \
        go build -buildmode=c-archive -ldflags="-s -w" -o "$out/libcherri.a" .
    $clang_cc -dynamiclib -I"$out" \
        -install_name "@rpath/cherri.framework/cherri" \
        -o "$out/cherri.framework/cherri" "$root/Cherri/cherri_cmd.c" \
        -Wl,-force_load,"$out/libcherri.a" \
        -F "$root/Frameworks/ios_system.xcframework/$slice" -framework ios_system \
        -framework CoreFoundation -framework Security -lresolv
    cat > "$out/cherri.framework/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>cherri</string>
<key>CFBundleIdentifier</key><string>com.example.ghostty-ios.cherri</string>
<key>CFBundleName</key><string>cherri</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>14.0</string>
</dict></plist>
PLIST
}

build arm64-apple-ios14.0 "$(xcrun --sdk iphoneos --show-sdk-path)" ios-arm64 "$work/device"
build arm64-apple-ios14.0-simulator "$(xcrun --sdk iphonesimulator --show-sdk-path)" ios-arm64_x86_64-simulator "$work/simulator"

rm -rf "$root/Frameworks/cherri.xcframework"
xcodebuild -create-xcframework \
    -framework "$work/device/cherri.framework" \
    -framework "$work/simulator/cherri.framework" \
    -output "$root/Frameworks/cherri.xcframework" >/dev/null
echo "built cherri"
