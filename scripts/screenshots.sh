#!/bin/zsh
# Renders every menu page with invented demo data and composes the README images into docs/images/.
# Invisible: no windows; nothing is read from or written to your settings.
set -euo pipefail
cd "${0:A:h}/.."
BIN=SoundControl
COLORS=(4D9EFF 4D29B3)   # the icon's gradient colours, see scripts/icon.swift
# page:snapshot arguments (the first page also provides the menu bar icon)
PAGES=("main:" "apps:--others" "advanced:--advanced" "output:--devices" "airplay:--devices --airplay" "hidden:--devices --hidden Studio"
       "input:--inputs" "sample-rate:--devices --advanced" "settings:--settings" "confirm:--settings --confirm")

mkdir -p build
xcodegen generate -q
xcodebuild -project $BIN.xcodeproj -scheme $BIN -configuration Release -derivedDataPath build build > build/screenshots-build.log 2>&1 \
  || { tail -20 build/screenshots-build.log; exit 1 }
RAW=build/screenshots/raw
rm -rf $RAW; mkdir -p $RAW docs/images
for page in $PAGES; do
  build/Build/Products/Release/$BIN.app/Contents/MacOS/$BIN --snapshot $RAW/${page%%:*} ${=page#*:} --demo >/dev/null 2>&1
done
swift scripts/compose.swift $RAW docs/images $COLORS ${PAGES%%:*}
