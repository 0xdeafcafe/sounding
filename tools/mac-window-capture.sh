#!/bin/zsh
set -eu

usage() {
  print -u2 "usage: mac-window-capture.sh <Sounding.app> <out-dir> <light|dark> <active|inactive> <step,step,...> [interval-seconds]"
  exit 64
}

[[ $# -ge 5 ]] || usage
app=$1
out=$2
scheme=$3
mode=$4
steps=$5
interval=${6:-4}

mkdir -p "$out"
log="$out/.run-$scheme-$mode.log"
: > "$log"

export SOUNDING_TV_UI_FIXTURE=1
export SOUNDING_TV_MAC_NO_ACTIVATE=1
export SOUNDING_TV_MAC_SIGNIN_STUB=1
export SOUNDING_TV_MAC_APPEARANCE=$scheme
export SOUNDING_TV_MAC_WINDOW_SIZE=${SOUNDING_TV_MAC_WINDOW_SIZE:-1360x820}
export SOUNDING_TV_MAC_TOUR=$steps
export SOUNDING_TV_MAC_TOUR_INTERVAL=$interval
[[ $mode == active ]] && export SOUNDING_TV_MAC_FORCE_ACTIVE=1

front_before=$(lsappinfo front)
nohup "$app/Contents/MacOS/Sounding" > "$log" 2>&1 &
pid=$!

handled=0
for _ in {1..2400}; do
  ready=("${(@f)$(grep '^\[TOUR\] ready' "$log" || true)}")
  while (( handled < ${#ready[@]} )) && [[ -n ${ready[handled+1]} ]]; do
    line=${ready[handled+1]}
    step=${${line#\[TOUR\] ready }% window=*}
    window=${line##*window=}
    name=${step//[@:]/-}
    screencapture -x -o -l"$window" "$out/$name-$scheme-$mode.png" && print "captured $name"
    handled=$((handled + 1))
  done
  grep -q '^\[TOUR\] done' "$log" && break
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.25
done

kill -0 "$pid" 2>/dev/null && kill "$pid"
front_after=$(lsappinfo front)
print "front before=$front_before after=$front_after"
