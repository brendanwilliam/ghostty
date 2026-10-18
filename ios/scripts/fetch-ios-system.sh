#!/bin/sh
# Downloads the prebuilt ios_system command frameworks into ios/Frameworks/,
# checking each zip's SHA-256. URLs and checksums come from
# holzschu/ios_system's Package.swift (v3.0.7 tag) and a-Shell's
# xcfs/Package.swift (dash, vim, lg2). Run once before `xcodegen generate`.
set -eu

cd "$(dirname "$0")/.."
mkdir -p Frameworks
cd Frameworks

base="https://github.com/holzschu/ios_system/releases/download"

fetch() {
    name="$1" url="$2" sum="$3"
    if [ -d "$name.xcframework" ]; then
        return
    fi
    curl -fsSL -o "$name.zip" "$url"
    echo "$sum  $name.zip" | shasum -a 256 -c - >/dev/null
    unzip -q "$name.zip"
    rm "$name.zip"
    echo "fetched $name"
}

fetch ios_system "$base/v3.0.6/ios_system.xcframework.zip" c9c6dc4cde45cc271ccc8bd0553ce4d3149eced1f0ee3d9e0ce01885d93526e6
fetch files "$base/v3.0.6/files.xcframework.zip" 5db63958f686cc79f107bafd0d50feff32fb2b64d0dd976478c5dd405f7600b0
fetch text "$base/v3.0.6/text.xcframework.zip" 9eef16c23ddaa03d5f28ce2183737b1dbdcfb06e6dc46035a404d9e0f3828604
fetch shell "$base/v3.0.6/shell.xcframework.zip" 89da3b8bd7f83e42a2311aeac54c38acc7a2f9c2fc0d0d27f75897b393cdfec2
fetch awk "$base/v3.0.6/awk.xcframework.zip" 675d3b2e3b5ba60ae1a727528b2cf5e11eda262d404c1e9708dc7e061898df86
fetch tar "$base/v3.0.6/tar.xcframework.zip" 74146ae19720d3d885d181bce4be2b6b92f11d306a47aa07486bf0dd35fc8f68
fetch dash "$base/Auxiliary/dash.xcframework.zip" 9a30ac6b3780dd68d2268d10467902214e32333e980c59090faa6099f0d250fc
fetch vim "https://github.com/holzschu/vim/releases/download/ios_1.0/vim.xcframework.zip" 02acb74bec3e6b4ba9c120873a19a770773e3c3e2d141365808a9342ddf41fe7
fetch lg2 "https://github.com/holzschu/libgit2/releases/download/ios_1.0/lg2.xcframework.zip" 7d205a771be8d120a80d2f7281135dfffd21a3713c86eb4f1957638f6b4b365e
# vim links lua_ios; lg2 links libssh2 and openssl.
fetch lua_ios "https://github.com/holzschu/lua_ios/releases/download/1.0/lua_ios.xcframework.zip" 0ccdab671f31c20daf8833452cc36598b49f84441851d7142b305443425bc527
fetch libssh2 "https://github.com/holzschu/libssh2-apple/releases/download/v1.11.0/libssh2-dynamic.xcframework.zip" cacfe1789b197b727119f7e32f561eaf9acc27bf38cd19975b74fce107f868a6
fetch openssl "https://github.com/holzschu/openssl-apple/releases/download/v1.1.1w/openssl-dynamic.xcframework.zip" 329e8317cf9bee8e138da5d032330a7a1bd2473cf44c9c083cb2f0636abb8b80
# ios_system can't run a framework's main() twice (its globals aren't
# reset), so later dash runs load fresh copies, dashA to dashE.
fetch dashA "$base/Auxiliary/dashA.xcframework.zip" a45eb647bf81caf0fd80dba704326842ce03668c60499488d387dce26cf30ee6
fetch dashB "$base/Auxiliary/dashB.xcframework.zip" c0de9fdc7c9cc2386012a1dccdbb112cf4b15243699ffcf49c9dbc6d17163bce
fetch dashC "$base/Auxiliary/dashC.xcframework.zip" 553d98fa8c5705754a9cdd2f4d2f5d3cd5d1dc5f765921f5fb0f3422848e09bf
fetch dashD "$base/Auxiliary/dashD.xcframework.zip" 7aa457e359b3bb215fdd56df5b689b826863f2e96d72a87a3046a3116f2dd30c
fetch dashE "$base/Auxiliary/dashE.xcframework.zip" 9f79675fa3c797257931853ca746337a66f8218157d44736d1c14425030aff3e
