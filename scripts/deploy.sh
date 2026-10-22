#!/bin/zsh
# Runs scripts/check.sh (build, snapshots, self-test), installs to /Applications and restarts the app.
# Installs only if the check is green. Afterwards scripts/status.sh serves as proof.
set -euo pipefail
cd "${0:A:h}/.."

./scripts/check.sh || { print "Not installed: check is red."; exit 1 }

TARGET="/Applications/SoundControl.app"
pkill -x SoundControl 2>/dev/null && sleep 0.5 || true
rm -rf "$TARGET"
ditto build/Build/Products/Release/SoundControl.app "$TARGET"
open -g "$TARGET"
sleep 2
print "\nSound Control installed: $TARGET"
./scripts/status.sh
