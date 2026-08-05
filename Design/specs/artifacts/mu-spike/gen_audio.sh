#!/bin/bash
set -euo pipefail
cd /Users/afr/.claude/jobs/3fc7cb5a/tmp/mu-spike/audio

SR=44100

# 1. Pure click track, exact 128.000 BPM, 60s. Ground truth: beats at
#    k * (60/128) seconds, k=0,1,2,...
EXPR_CLICK="if(lt(mod(t\,60/128)\,0.015)\,0.9*sin(2*PI*1800*t)*exp(-80*mod(t\,60/128))\,0)"
ffmpeg -y -f lavfi -i "aevalsrc=exprs='${EXPR_CLICK}|${EXPR_CLICK}':s=${SR}:d=60" \
  -c:a pcm_s16le click_128.wav -loglevel error

# 2. More musical 4/4 loop at exact 120.000 BPM: kick + hihat + sustained bass.
#    Beat period = 0.5s, eighth-note period = 0.25s.
EXPR_LOOP="0.6*sin(2*PI*60*t)*exp(-40*mod(t\,0.5)) + 0.25*sin(2*PI*8000*t)*exp(-150*mod(t\,0.25)) + 0.2*sin(2*PI*55*t)"
ffmpeg -y -f lavfi -i "aevalsrc=exprs='${EXPR_LOOP}|${EXPR_LOOP}':s=${SR}:d=60" \
  -c:a pcm_s16le loop_120_musical.wav -loglevel error

# 3. Key test: sustained C major chord (C4 E4 G4), 30s. Ground truth: C major.
EXPR_CMAJ="0.3*sin(2*PI*261.63*t) + 0.3*sin(2*PI*329.63*t) + 0.3*sin(2*PI*392.00*t)"
ffmpeg -y -f lavfi -i "aevalsrc=exprs='${EXPR_CMAJ}|${EXPR_CMAJ}':s=${SR}:d=30" \
  -c:a pcm_s16le key_cmajor.wav -loglevel error

# 4. Key test: sustained A minor chord (A3 C4 E4), 30s. Ground truth: A minor.
EXPR_AMIN="0.3*sin(2*PI*220.00*t) + 0.3*sin(2*PI*261.63*t) + 0.3*sin(2*PI*329.63*t)"
ffmpeg -y -f lavfi -i "aevalsrc=exprs='${EXPR_AMIN}|${EXPR_AMIN}':s=${SR}:d=30" \
  -c:a pcm_s16le key_aminor.wav -loglevel error

# 5. Structured 4-minute track at exact 128.000 BPM with 6 sections that have
#    clearly different instrumentation/energy, for structure/phrase/cost tests.
#    Bar = 4 beats = 1.875s @128bpm. Sections chosen to land on bar boundaries.
BEAT="60/128"
EIGHTH="60/128/2"
KICK="0.6*sin(2*PI*60*t)*exp(-40*mod(t\,${BEAT}))"
HAT="0.2*sin(2*PI*8000*t)*exp(-150*mod(t\,${EIGHTH}))"
BASS="0.2*sin(2*PI*55*t)"
LEAD="0.15*sin(2*PI*440*t)*(0.5+0.5*sin(2*PI*2*t))"

# intro: 8 bars = 15s. Kick only, low amplitude. Sparse/low energy.
E="0.5*(${KICK})"
ffmpeg -y -f lavfi -i "aevalsrc=exprs='${E}|${E}':s=${SR}:d=15" -c:a pcm_s16le sec_intro.wav -loglevel error

# loopA (build): 32 bars = 60s. Kick + hat + bass. Moderate energy.
E="${KICK} + ${HAT} + ${BASS}"
ffmpeg -y -f lavfi -i "aevalsrc=exprs='${E}|${E}':s=${SR}:d=60" -c:a pcm_s16le sec_loopa.wav -loglevel error

# drop1: 32 bars = 60s. Kick + hat + bass + lead. High energy, all layers.
E="${KICK} + ${HAT} + ${BASS} + ${LEAD}"
ffmpeg -y -f lavfi -i "aevalsrc=exprs='${E}|${E}':s=${SR}:d=60" -c:a pcm_s16le sec_drop1.wav -loglevel error

# breakdown: 16 bars = 30s. Bass + hat only, no kick. Thin/different texture.
E="${HAT} + ${BASS}"
ffmpeg -y -f lavfi -i "aevalsrc=exprs='${E}|${E}':s=${SR}:d=30" -c:a pcm_s16le sec_breakdown.wav -loglevel error

# drop2: 32 bars = 60s. Same as drop1.
E="${KICK} + ${HAT} + ${BASS} + ${LEAD}"
ffmpeg -y -f lavfi -i "aevalsrc=exprs='${E}|${E}':s=${SR}:d=60" -c:a pcm_s16le sec_drop2.wav -loglevel error

# outro: 8 bars = 15s. Kick only, fading out.
E="0.5*(${KICK})"
ffmpeg -y -f lavfi -i "aevalsrc=exprs='${E}|${E}':s=${SR}:d=15" -c:a pcm_s16le sec_outro_raw.wav -loglevel error
ffmpeg -y -i sec_outro_raw.wav -af "afade=t=out:st=0:d=15" -c:a pcm_s16le sec_outro.wav -loglevel error

cat > concat_list.txt <<EOF
file 'sec_intro.wav'
file 'sec_loopa.wav'
file 'sec_drop1.wav'
file 'sec_breakdown.wav'
file 'sec_drop2.wav'
file 'sec_outro.wav'
EOF

ffmpeg -y -f concat -safe 0 -i concat_list.txt -c:a pcm_s16le main_track_128bpm_4min.wav -loglevel error

echo "Done. Section boundaries (seconds): intro=0-15 loopA=15-75 drop1=75-135 breakdown=135-165 drop2=165-225 outro=225-240"
ls -la *.wav
