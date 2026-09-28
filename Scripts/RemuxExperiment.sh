#!/bin/bash
# Development-only fixture and stream-copy experiment. FFmpeg is never bundled.
set -euo pipefail
remux_ffmpeg="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
remux_ffprobe="${FFPROBE:-/opt/homebrew/bin/ffprobe}"
remux_dir="${1:-$(mktemp -d /tmp/archive-remux-experiment.XXXXXX)}"
mkdir -p "$remux_dir"
"$remux_ffmpeg" -version | head -1
printf 'Output directory: %s\n' "$remux_dir"

# Three-second deterministic synthetic originals, two independently tagged audio tracks.
"$remux_ffmpeg" -hide_banner -loglevel error -nostdin \
  -f lavfi -i 'testsrc2=size=160x96:rate=25:duration=3' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=3' \
  -f lavfi -i 'sine=frequency=660:sample_rate=48000:duration=3' \
  -map 0:v -map 1:a -map 2:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  -g 25 -c:a aac -b:a 96k -metadata:s:a:0 language=eng -metadata:s:a:1 language=hin \
  "$remux_dir/h264-aac.mkv"

"$remux_ffmpeg" -hide_banner -loglevel error -nostdin \
  -f lavfi -i 'testsrc2=size=352x240:rate=30000/1001:duration=3' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=3' \
  -f lavfi -i 'sine=frequency=660:sample_rate=48000:duration=3' \
  -map 0:v -map 1:a -map 2:a -c:v mpeg2video -pix_fmt yuv420p -g 15 -bf 0 -b:v 1500k \
  -c:a ac3 -b:a 192k -metadata:s:a:0 language=eng -metadata:s:a:1 language=hin \
  -f vob "$remux_dir/mpeg2-ac3.vob"

"$remux_ffmpeg" -hide_banner -loglevel error -nostdin -i "$remux_dir/mpeg2-ac3.vob" \
  -map 0:v -map 0:a -c copy -metadata:s:a:0 language=eng -metadata:s:a:1 language=hin \
  -f mpegts "$remux_dir/mpeg2-ac3.ts"

for remux_name in h264-aac.mkv mpeg2-ac3.vob mpeg2-ac3.ts; do
  "$remux_ffprobe" -v error -show_entries 'stream=index,codec_name,codec_type,channels:stream_tags=language:format=size,duration' \
    -of json "$remux_dir/$remux_name" > "$remux_dir/$remux_name.probe.json"
  # /usr/bin/time -l: elapsed/user/system and maximum resident set size (Darwin bytes).
  # No decode or encode occurs in this measured step.
  if /usr/bin/time -l -o "$remux_dir/$remux_name.remux-time.txt" \
    "$remux_ffmpeg" -hide_banner -loglevel warning -nostdin -i "$remux_dir/$remux_name" \
    -map 0:v -map 0:a -c copy -movflags +empty_moov+delay_moov+frag_keyframe+default_base_moof \
    -f mp4 "$remux_dir/$remux_name.fragmented.mp4" \
    2> "$remux_dir/$remux_name.remux-log.txt"; then
    "$remux_ffprobe" -v error -show_entries 'stream=index,codec_name,codec_type,channels:stream_tags=language:format=size,duration' \
      -of json "$remux_dir/$remux_name.fragmented.mp4" > "$remux_dir/$remux_name.fragmented.mp4.probe.json"
    "$remux_ffmpeg" -v error -nostdin -i "$remux_dir/$remux_name" -map 0:v -map 0:a \
      -c copy -f streamhash -hash sha256 "$remux_dir/$remux_name.streamhash"
    "$remux_ffmpeg" -v error -nostdin -i "$remux_dir/$remux_name.fragmented.mp4" -map 0:v -map 0:a \
      -c copy -f streamhash -hash sha256 "$remux_dir/$remux_name.fragmented.mp4.streamhash"
    cmp "$remux_dir/$remux_name.streamhash" "$remux_dir/$remux_name.fragmented.mp4.streamhash"
    printf 'Remux succeeded: %s\n' "$remux_name"
  else
    printf 'Remux failed; inspect log: %s\n' "$remux_name"
  fi
done
printf 'Run AVFoundation probe with REMUX_EXPERIMENT_DIR=%s swift test --package-path ArchivePlayerCore --filter RemuxExperimentTests\n' "$remux_dir"
