#!/bin/sh
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
scripts/fetch-deps.sh
xcodegen generate
xcodebuild -project iFuckAI.xcodeproj -scheme iFuckAI -configuration Release -sdk iphoneos \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO -quiet
rm -rf build/ipa && mkdir -p build/ipa/Payload
cp -R build/Build/Products/Release-iphoneos/iFuckAI.app build/ipa/Payload/
(cd build/ipa && zip -qr ../iFuckAI.ipa Payload)
echo "build/iFuckAI.ipa"
