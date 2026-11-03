#!/bin/sh
set -e
cd "$(dirname "$0")/.."
TAG=b11772
SHA=0fb4ff1d80d55b49424d6717e72ccc7a1bd6cfdf3f2b9f67aeec6d21acf47a55
ZIP="llama-$TAG-xcframework.zip"
if [ -d Vendor/llama.xcframework ] && [ "$(cat Vendor/.tag 2>/dev/null)" = "$TAG" ]; then
    echo "llama.xcframework $TAG already present"
    exit 0
fi
mkdir -p Vendor
TMP="$(mktemp -d)"
curl -fL "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/$ZIP" -o "$TMP/$ZIP"
echo "$SHA  $TMP/$ZIP" | shasum -a 256 -c -
unzip -q "$TMP/$ZIP" -d "$TMP"
rm -rf Vendor/llama.xcframework
mv "$TMP/build-apple/llama.xcframework" Vendor/
echo "$TAG" > Vendor/.tag
rm -rf "$TMP"
echo "llama.xcframework $TAG ready"
