#!/bin/zsh
# Shows whether Sound Control is installed cleanly and which platform versions are currently running.
# Compares with the last tested state in docs/PLATFORM.md. Changes nothing.
set -uo pipefail
cd "${0:A:h}/.."
TARGET=/Applications/SoundControl.app
want=$(grep -E 'MARKETING_VERSION' project.yml | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
have=$(defaults read $TARGET/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || print "missing")
print "Version project $want · installed $have $([[ $want == $have ]] && print ✅ || print '❌ → ./scripts/deploy.sh')"
pgrep -qf "$TARGET/Contents/MacOS/SoundControl" && print "Running ✅" || print "Not running ❌ → open $TARGET"
codesign --verify --strict $TARGET 2>/dev/null && print "Signature valid ✅" || print "Signature invalid ❌"
sfltool dumpbtm 2>/dev/null | grep -B4 "Identifier: .*io.github.ape97.soundcontrol$" | grep -q "Disposition: \[enabled" \
  && print "Login item active ✅" || print "Login item not found ⚠️ (Settings → Open at Login)"
expiry=$(security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
print "Signing certificate valid until: ${expiry:-not found} (only relevant if you sign with your own certificate)"

now="macOS=$(sw_vers -productVersion) ($(sw_vers -buildVersion)) Xcode=$(xcodebuild -version | head -1 | awk '{print $2}') SDK=$(xcrun --show-sdk-version)"
last=$(grep -E '^tested:' docs/PLATFORM.md | tail -1 | sed 's/^tested: //; s/ date=.*//')
print "Platform now:    $now"
print "Last tested:     $last"
[[ $now == $last ]] && print "Platform unchanged ✅" || print "Platform changed ⚠️ → re-run ./scripts/check.sh and update docs/PLATFORM.md"
