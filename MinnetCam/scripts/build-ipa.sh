#!/bin/sh
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodegen generate
xcodebuild -project MinnetCam.xcodeproj -scheme MinnetCam -configuration Release -sdk iphoneos \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO -quiet
rm -rf build/ipa && mkdir -p build/ipa/Payload
cp -R build/Build/Products/Release-iphoneos/MinnetCam.app build/ipa/Payload/
(cd build/ipa && zip -qr ../MinnetCam.ipa Payload)
echo "build/MinnetCam.ipa"
