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
# animation frames: rendered into $RAW only (scripts/scenes/*.json), never composed into README images
EXTRA=("devices-150:--devices --safari 150" "airpods:--output 1 --safari 150")
for v in 45 30 20 60 100 125 150; do EXTRA+=("safari-$v:--safari $v"); done

mkdir -p build
xcodegen generate -q
xcodebuild -project $BIN.xcodeproj -scheme $BIN -configuration Release -derivedDataPath build build > build/screenshots-build.log 2>&1 \
  || { tail -20 build/screenshots-build.log; exit 1 }
RAW=build/screenshots/raw
rm -rf $RAW; mkdir -p $RAW docs/images
for page in $PAGES $EXTRA; do
  build/Build/Products/Release/$BIN.app/Contents/MacOS/$BIN --snapshot $RAW/${page%%:*} ${=page#*:} --demo >/dev/null 2>&1
done
swift scripts/compose.swift $RAW docs/images $COLORS ${PAGES%%:*}
cp SoundControl/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png docs/images/icon.png   # README header

# Animations: every scripts/scenes/<name>.json plays over the pages above (see compose.swift --scene); ffmpeg joins the
# frames into docs/images/<name>.gif with one shared palette, writing only the changed area of each frame
# (15 fps and at most 1200 px wide keep a 20-second walkthrough near 2–3 MB).
if command -v ffmpeg >/dev/null; then
  for scene in scripts/scenes/*.json(N); do
    out=build/screenshots/scene-${scene:t:r}
    rm -rf $out; mkdir -p $out
    swift scripts/compose.swift --scene $scene $RAW $out $COLORS
    ffmpeg -v error -y -f concat -i $out/frames.txt \
      -vf "fps=15,scale='min(iw,1200)':-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
      -loop 0 docs/images/${scene:t:r}.gif
    print docs/images/${scene:t:r}.gif
  done
else
  print "ffmpeg not found: animations not updated (brew install ffmpeg)"
fi
