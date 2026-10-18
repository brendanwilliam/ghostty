#!/bin/sh
# Downloads BeeWare's Python-Apple-support (CPython 3.14 for iOS) into
# Frameworks/, checking its SHA-256. Run once, then `xcodegen generate`.
set -eu
cd "$(dirname "$0")"
mkdir -p Frameworks
cd Frameworks
[ -d Python.xcframework ] && exit 0
file=Python-3.14-iOS-support.b12.tar.gz
curl -fsSL -o "$file" "https://github.com/beeware/Python-Apple-support/releases/download/3.14-b12/$file"
echo "157a6b956f47a12f005ad1e23e3e264536ef06dd35e1366acb48edbaa128e0a3  $file" | shasum -a 256 -c - >/dev/null
tar xzf "$file"
rm "$file"
echo "fetched Python.xcframework"
