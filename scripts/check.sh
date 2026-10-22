#!/bin/zsh
# Checks Sound Control completely and invisibly: build (no errors/warnings), snapshots, self-test with and without "Advanced".
# Changes nothing on the system, opens no windows. Result: summary + exit code (0 = green).
set -uo pipefail
cd "${0:A:h}/.."
OUT=build/check
rm -rf $OUT; mkdir -p $OUT
failed=0
ok()   { print "✅ $1" }
fail() { print "❌ $1"; failed=1 }

xcodegen generate -q || { fail "xcodegen"; exit 1 }
xcodebuild -project SoundControl.xcodeproj -scheme SoundControl -configuration Release \
  -derivedDataPath build build > build/log.txt 2>&1
grep -q "BUILD SUCCEEDED" build/log.txt && ok "Build" || { fail "Build (build/log.txt)"; grep -E "error:" build/log.txt | head -20; exit 1 }
warn=$(grep -E "warning:" build/log.txt | grep -v appintents | sort -u)
[[ -z $warn ]] && ok "no warnings" || { fail "Warnings:"; print -- "$warn" | head -30 }

APP="$PWD/build/Build/Products/Release/SoundControl.app"
BIN="$APP/Contents/MacOS/SoundControl"
for v in "normal:" "demo:--demo" "devices:--demo --devices" "advanced:--demo --advanced" "settings:--demo --settings" "hidden:--devices --hidden Steam" "airplay:--devices --airplay Kitchen"; do
  name=${v%%:*}; args=(${=v#*:})
  "$BIN" --snapshot $OUT/$name $args >/dev/null 2>&1
  [[ -s $OUT/$name-light.png && -s $OUT/$name-dark.png ]] || fail "Snapshot $name"
done
ok "Snapshots in $OUT (take a look!)"

for mode in "" "--advanced"; do
  f=$OUT/selftest${mode:+-advanced}.json
  open -n -g -a "$APP" --args --selftest $PWD/$f $mode
  for i in {1..60}; do [[ -f $f ]] && break; /bin/sleep 1; done
  [[ -f $f ]] || { fail "Self-test $mode: no output"; continue }
  python3 - "$f" "${mode:-normal}" <<'PY' && ok "Self-test ${mode:-normal}" || fail "Self-test ${mode:-normal} ($f)"
import json, sys
d = json.load(open(sys.argv[1])); live = d.get("liveTap"); live = live if isinstance(live, dict) else {"ratio": live}
print(f"   ok={d['ok']} permission={d.get('permission')} live-tap-ratio={live.get('ratio')} limiter={round(d.get('limiter_peak', 0), 3)} failures={d.get('failures')}")
sys.exit(0 if d["ok"] and not d.get("failures") else 1)
PY
done
(( failed )) && print "\nRESULT: RED" || print "\nRESULT: GREEN"
exit $failed
