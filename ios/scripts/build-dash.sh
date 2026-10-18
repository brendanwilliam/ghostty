#!/bin/sh
# Builds dash (and its copies dashA to dashE) from source with Patches/
# dash-ios.patch, which lets the app stop a loop that never calls a
# command (`while true; do :; done`), and avoids `strchrnul`, which only
# exists from iOS 18.4. The result replaces the prebuilt
# dash*.xcframework in ios/Frameworks/ and has a native arm64 simulator
# slice, so no re-tagging is needed for dash.
#
# Source: holzschu/dash_iOS (BSD licensed), fetched into a scratch directory
# and checked out at the pinned commit. Run scripts/fetch-ios-system.sh
# first (it provides ios_system, which dash links), then `xcodegen generate`.
#
# Usage: scripts/build-dash.sh [work-dir]   (default: a new temp directory)
set -eu

commit=3da49bb7ac15458ea4f554b589dde5197816f6ba

root="$(cd "$(dirname "$0")/.." && pwd)"
work="${1:-$(mktemp -d)}"
if [ -e "$work" ] && [ -n "$(ls -A "$work")" ]; then
    echo "$work isn't empty; pass a new directory" >&2
    exit 1
fi
mkdir -p "$work"
src="$work/dash_iOS"

git clone -q https://github.com/holzschu/dash_iOS "$src"
git -C "$src" checkout -q "$commit"
git -C "$src" apply "$root/Patches/dash-ios.patch"
ln -s "$root/Frameworks/ios_system.xcframework" "$src/ios_system.xcframework"

cd "$src"
# configure checks for these automake helpers, which the repo doesn't ship
# and which this build never uses (no `make install`, no MSVC).
for helper in compile install-sh; do
    [ -e "$helper" ] || printf '#!/bin/sh\nexec "$@"\n' > "$helper"
    chmod +x "$helper"
done
# `missing` stands in for autotools when a generated file looks stale.
rm -f missing
printf '#!/bin/sh\nexit 0\n' > missing
chmod +x missing
mac_sdk=$(xcrun --sdk macosx --show-sdk-path)
ios_sdk=$(xcrun --sdk iphoneos --show-sdk-path)
sim_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)

# build <name> <clang target> <sdk> <ios_system slice> <output directory>
build() {
    target="$1" sdk="$2" slice="$3" out="$4"
    flags="-target $target -isysroot $sdk -DJOBS=0 -Dstat64=stat -Dlstat64=lstat -Dfstat64=fstat -DUSE_GLIBC_STDIO=1 -DFLUSHERR=1 -I$PWD"
    make distclean >/dev/null 2>&1 || true
    ./configure CC=clang CXX=clang++ \
        CC_FOR_BUILD="clang -isysroot $mac_sdk -DJOBS=0" \
        CFLAGS="$flags" CPPFLAGS="$flags" CXXFLAGS="$flags" \
        LDFLAGS="-target $target -isysroot $sdk -dynamiclib -F $PWD/ios_system.xcframework/$slice -framework ios_system" \
        --build=x86_64-apple-darwin --host=aarch64-apple-darwin cross_compiling=yes --with-libedit --disable-dependency-tracking >/dev/null
    make -j4 --quiet
    for name in dash dashA dashB dashC dashD dashE; do
        fw="$out/$name.framework"
        rm -rf "$fw"
        mkdir -p "$fw"
        cp src/dash "$fw/$name"
        cp "$plist" "$fw/Info.plist"
        plutil -replace CFBundleExecutable -string "$name" "$fw/Info.plist"
        plutil -replace CFBundleName -string "$name" "$fw/Info.plist"
        plutil -replace CFBundleIdentifier -string "Nicolas-Holzschuch.$name" "$fw/Info.plist"
        install_name_tool -id "@rpath/$name.framework/$name" "$fw/$name"
    done
}

plist="$PWD/basic_Info.plist"
build arm64-apple-ios14.0 "$ios_sdk" ios-arm64 "$work/device"
plist="$PWD/basic_Info_Simulator.plist"
build arm64-apple-ios14.0-simulator "$sim_sdk" ios-arm64_x86_64-simulator "$work/simulator"

for name in dash dashA dashB dashC dashD dashE; do
    rm -rf "$root/Frameworks/$name.xcframework"
    xcodebuild -create-xcframework \
        -framework "$work/device/$name.framework" \
        -framework "$work/simulator/$name.framework" \
        -output "$root/Frameworks/$name.xcframework" >/dev/null
    echo "built $name"
done
