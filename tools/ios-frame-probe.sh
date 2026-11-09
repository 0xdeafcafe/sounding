#!/bin/zsh
set -u

ROOT=${0:A:h:h}
SIM=${SIM:-3E6A3345-242A-43CD-96AC-95DC74A8AD62}
DD=${DERIVED_DATA:-${TMPDIR:-/tmp}/ios-frame-probe-dd}
BUNDLE=red.forbes.sounding
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

typeset -A drive environment seconds
drive[home]="wait:3,scroll:3,wait:1,scroll:3"
environment[home]="SOUNDING_TV_UI_FIXTURE=1 SOUNDING_TV_PHONE_TAB=home"
drive[likes]="wait:3,tap:0,wait:2,scroll:3,back,wait:2,tap:0,wait:2"
environment[likes]="SOUNDING_TV_UI_FIXTURE=1 SOUNDING_TV_PHONE_TAB=library"
drive[search]="wait:3,search:night tapes,wait:2,scroll:3,wait:1,scroll:3"
environment[search]="SOUNDING_TV_UI_FIXTURE=1 SOUNDING_TV_PHONE_TAB=search"
drive[artist]="wait:3,scroll:3,wait:1,scroll:3"
environment[artist]="SOUNDING_TV_UI_FIXTURE=1 SOUNDING_TV_UI_DESTINATION=artist"
drive[playlist]="wait:3,scroll:3,wait:1,scroll:3"
environment[playlist]="SOUNDING_TV_UI_FIXTURE=1 SOUNDING_TV_UI_DESTINATION=playlist"
drive[mocklikes]="wait:5,tap:0,wait:3,scroll:3,wait:1,scroll:3"
environment[mocklikes]="SOUNDING_TV_UI_FIXTURE=0 SOUNDING_TV_SC_MOCK=1 SOUNDING_TV_PHONE_TAB=library"
seconds[mocklikes]=50

if [[ ${SKIP_BUILD:-0} != 1 ]]; then
  xcodebuild build -project "$ROOT/SoundingTV.xcodeproj" -scheme "SoundingTV iOS" -configuration Debug \
    -destination "id=$SIM" -derivedDataPath "$DD" \
    SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s ENABLE_DEBUG_DYLIB=NO \
    > "$DD.build.log" 2>&1 || { grep -E "error:" "$DD.build.log" | head -20; exit 1; }
  xcrun simctl install "$SIM" "$DD/Build/Products/Debug-iphonesimulator/Sounding.app" || exit 1
fi

scenarios=("$@")
[[ ${#scenarios} -eq 0 ]] && scenarios=(home likes search artist playlist mocklikes)
runs=${RUNS:-1}

for scenario in $scenarios; do
  launchEnvironment=(SIMCTL_CHILD_SOUNDING_TV_DISMISS_WELCOME=1)
  for pair in ${(s: :)environment[$scenario]}; do launchEnvironment+=("SIMCTL_CHILD_$pair"); done
  for run in $(seq 1 $runs); do
    xcrun simctl terminate "$SIM" "$BUNDLE" > /dev/null 2>&1
    start=$(date "+%Y-%m-%d %H:%M:%S")
    env $launchEnvironment \
      SIMCTL_CHILD_SOUNDING_TV_FRAME_PROBE="$scenario" SIMCTL_CHILD_SOUNDING_TV_FRAME_PROBE_DRIVE="${drive[$scenario]}" \
      xcrun simctl launch "$SIM" "$BUNDLE" > /dev/null || exit 1
    sleep ${seconds[$scenario]:-${DURATION:-32}}
    xcrun simctl terminate "$SIM" "$BUNDLE" > /dev/null 2>&1
    xcrun simctl spawn "$SIM" log show --start "$start" --style compact \
      --predicate 'subsystem == "red.forbes.sounding" AND category == "frameprobe"' 2>/dev/null \
      | grep -o "probe $scenario phase=.*" \
      | grep -v "phase=wait" \
      | sed -E 's/^probe ([a-z]+) phase=([^ ]+) seconds=([0-9.]+) frames=([0-9]+) hitchMsPerSec=([0-9.]+) worstMs=([0-9.]+)/\1 \2 \5 ms\/s, worst \6 ms (\4 frames, \3 s)/'
  done
done
