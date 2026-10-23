#!/bin/zsh
# Builds the downloadable release: Release configuration, always ad-hoc signed (a personal certificate from
# Config/Local.xcconfig would put the developer's name into the signature) and fully stripped (the debug map
# would otherwise carry the absolute build paths), zipped with ditto.
# Stable designated requirement (bundle identifier), see below.
# Output: build/release/SoundControl-<version>.zip and its SHA-256.
set -euo pipefail
cd "${0:A:h}/.."
OUT=build/release
rm -rf $OUT; mkdir -p $OUT

xcodegen generate -q
xcodebuild -project SoundControl.xcodeproj -scheme SoundControl -configuration Release \
  -derivedDataPath $OUT/derived CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=all DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
  build > $OUT/log.txt 2>&1 || { grep -E "error:" $OUT/log.txt | head -20; print "RESULT: RED (build)"; exit 1 }

APP=$OUT/derived/Build/Products/Release/SoundControl.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" $APP/Contents/Info.plist)
# Ad-hoc signatures default to a designated requirement of "this exact cdhash", which changes with every build: macOS would
# then forget privacy permissions (Accessibility, microphone, …) after each update. Re-sign with a requirement on the bundle
# identifier instead, so permissions carry over from one release to the next.
ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" $APP/Contents/Info.plist)
codesign --force --sign - --preserve-metadata=entitlements,flags,runtime -r="designated => identifier \"$ID\"" $APP
[[ $(codesign -d -r- $APP 2>&1) == *"designated => identifier \"$ID\""* ]] || { print "RESULT: RED (designated requirement)"; exit 1 }
[[ $(codesign -dv $APP 2>&1) == *"Signature=adhoc"* ]] || { print "RESULT: RED (not ad-hoc signed)"; exit 1 }
! LC_ALL=C grep -r -a -q "$HOME" $APP || { print "RESULT: RED (build paths left in the app)"; exit 1 }

ZIP=$OUT/SoundControl-$VERSION.zip
ditto -c -k --sequesterRsrc --keepParent $APP $ZIP
print "$ZIP"
shasum -a 256 $ZIP
print "RESULT: GREEN"
