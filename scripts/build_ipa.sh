#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1
cd "$(dirname "$0")/.."

xcodegen generate
rm -rf build Payload MoeReader.ipa

xcodebuild build \
  -project MoeReader.xcodeproj \
  -scheme MoeReader \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM=""

APP="build/Build/Products/Release-iphoneos/MoeReader.app"
test -d "$APP"
lipo -info "$APP/MoeReader"

mkdir -p Payload
cp -R "$APP" Payload/
zip -qry MoeReader.ipa Payload
rm -rf Payload

unzip -l MoeReader.ipa | grep -q "Payload/MoeReader.app/MoeReader"
ls -lh MoeReader.ipa
