#!/bin/zsh
set -euo pipefail
here=${0:A:h:h}
fixtures=/tmp/vollage-native-parity-fixtures
mkdir -p "$fixtures"
ffmpeg=${FFMPEG:-$(command -v ffmpeg)}
"$ffmpeg" -hide_banner -loglevel error -f lavfi -i color=c=red:size=640x360:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac -y "$fixtures/red.mp4"
"$ffmpeg" -hide_banner -loglevel error -f lavfi -i color=c=blue:size=640x360:rate=30 -f lavfi -i sine=frequency=660:sample_rate=48000 -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac -y "$fixtures/blue.mp4"
"$ffmpeg" -hide_banner -loglevel error -f lavfi -i testsrc2=size=360x640:rate=30 -t 2 -c:v libx264 -pix_fmt yuv420p -y "$fixtures/portrait.mp4"
"$ffmpeg" -hide_banner -loglevel error -i "$fixtures/red.mp4" -c:v wmv2 -c:a wmav2 -y "$fixtures/legacy.wmv"
"$ffmpeg" -hide_banner -loglevel error -display_rotation 90 -i "$fixtures/red.mp4" -c copy -y "$fixtures/rotated.mp4"
"$ffmpeg" -hide_banner -loglevel error -f lavfi -i color=c=green:size=320x180:rate=30:duration=2 -f lavfi -i sine=frequency=880:sample_rate=48000:duration=0.5 -c:v libx264 -pix_fmt yuv420p -c:a aac -y "$fixtures/short-audio.mp4"
export VOLLAGE_TEST_MEDIA="$fixtures"
export VOLLAGE_DATA_ROOT=/tmp/vollage-native-parity-data
export VOLLAGE_SNAPSHOTS=/tmp/vollage-native-parity-shots
"$here/build/Vollage.app/Contents/MacOS/Vollage" --selftest
node "$here/tools/portable-test.cjs" "$fixtures"
VOLLAGE_ROUNDTRIP="$fixtures/electron-roundtrip.vollage" "$here/build/Vollage.app/Contents/MacOS/Vollage" --selftest
"$ffmpeg" -hide_banner -i "$fixtures/output.mp4" -af volumedetect -vn -f null - 2> "$fixtures/audio-check.log"
if rg -q 'mean_volume: -inf' "$fixtures/audio-check.log"; then print 'FAIL output audio is silent'; exit 1; fi
print 'PASS output audio is non-silent'
"$ffmpeg" -v error -i "$fixtures/output.mp4" -vn -ar 48000 -ac 1 -f f32le -y "$fixtures/mix.f32"
python3 - "$fixtures/mix.f32" <<'PY'
import sys,struct,math
b=open(sys.argv[1],'rb').read(); samples=struct.unpack('<%df'%(len(b)//4),b)
for frequency in (440,660):
    # Check short windows: avoid cancellation from real-time phase changes at loop boundaries.
    strengths=[]
    for start in range(4800,min(len(samples)-4800,48000),4800):
        part=samples[start:start+4800]
        real=sum(x*math.cos(2*math.pi*frequency*i/48000) for i,x in enumerate(part))
        imag=sum(x*math.sin(2*math.pi*frequency*i/48000) for i,x in enumerate(part))
        strengths.append(2*math.hypot(real,imag)/len(part))
    assert strengths and max(strengths)>.02, f'Missing {frequency} Hz source in mix'
    print(f'PASS recorded audio contains {frequency} Hz source')
PY
