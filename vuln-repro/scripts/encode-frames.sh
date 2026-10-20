#!/usr/bin/env bash
# Encode captured frames into a 1920x1080 H.264 30fps MP4.
# Usage: encode-frames.sh --frames frames/ --out repro.mp4 --fps 2.4709 [--ext jpg] [--crf 20] [--timestamp]
# --fps must be the MEASURED frame rate (total frames / wall-clock seconds of the
#   capture, printed by record-vnc.sh). The default 2.4709 is a historical
#   measured value from one host (nominal 2.5); re-measure on each host or
#   playback speed will drift.
# --timestamp burns pts (h:m:s) into the bottom-left corner, like a wall clock:
#   useful as evidence that long waits are real time, not edited.
set -u
set -o pipefail

frames=""
out=""
fps="2.4709"
ext="jpg"
crf="20"
timestamp=0
font=""
usage() {
  echo "usage: $0 --frames <dir> --out <file.mp4> --fps <measured> [--ext jpg|png] [--crf 20] [--timestamp] [--font PATH]" >&2
  exit 2
}
while [ $# -gt 0 ]; do
  case "$1" in
    --frames) frames=${2:?"--frames requires a value"}; shift 2;;
    --out) out=${2:?"--out requires a value"}; shift 2;;
    --fps) fps=${2:?"--fps requires a value"}; shift 2;;
    --ext) ext=${2:?"--ext requires a value"}; shift 2;;
    --crf) crf=${2:?"--crf requires a value"}; shift 2;;
    --font) font=${2:?"--font requires a value"}; shift 2;;
    --timestamp) timestamp=1; shift;;
    -h|--help) usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done
[ -n "$frames" ] && [ -n "$out" ] || usage
[ -d "$frames" ] || { echo "FAIL: frames dir not found: $frames" >&2; exit 2; }
ls "$frames"/frame-*.$ext >/dev/null 2>&1 || { echo "FAIL: no frame-*.$ext in $frames" >&2; exit 2; }

# font candidates cover Debian/Ubuntu (truetype/dejavu) and RHEL/Fedora (dejavu) layouts
if [ -z "$font" ]; then
  for c in /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf /usr/share/fonts/dejavu/DejaVuSans-Bold.ttf; do
    [ -r "$c" ] && font=$c && break
  done
fi

ffmpeg_bin=/usr/bin/ffmpeg
[ -x "$ffmpeg_bin" ] || ffmpeg_bin=$(command -v ffmpeg) || { echo "FAIL: ffmpeg not found" >&2; exit 2; }
"$ffmpeg_bin" -hide_banner -encoders 2>/dev/null | grep -q libx264 || {
  echo "FAIL: ffmpeg has no libx264; use a build with libx264" >&2; exit 2;
}

vf="scale=1920:1080:flags=lanczos,format=yuv420p"
if [ "$timestamp" -eq 1 ]; then
  if [ -n "$font" ] && [ -r "$font" ]; then
    vf="${vf},drawtext=fontfile=${font}:text='%{pts\:hms}':x=10:y=h-44:fontsize=30:fontcolor=white:box=1:boxcolor=black@0.65"
  else
    echo "WARN: no usable bold font found (tried Debian/RHEL dejavu paths); pass --font <path-to-ttf> to get the timestamp overlay" >&2
  fi
fi

# -pattern_type glob needs an ffmpeg built with glob support (glibc builds have
# it; musl/some macOS builds do not). On failure retry with the %06d sequence.
if ! "$ffmpeg_bin" -y -loglevel error -framerate "$fps" -pattern_type glob -i "$frames/frame-*.$ext" \
     -vf "$vf" -r 30 -c:v libx264 -preset veryfast -crf "$crf" -movflags +faststart "$out"; then
  echo "glob pattern failed; retrying with sequence pattern" >&2
  first=$(ls "$frames"/frame-*.$ext | sort | head -1)
  base=${first%*.$ext}
  "$ffmpeg_bin" -y -loglevel error -framerate "$fps" -i "${base}%06d.$ext" \
    -vf "$vf" -r 30 -c:v libx264 -preset veryfast -crf "$crf" -movflags +faststart "$out" || {
      echo "FAIL: ffmpeg encoding failed" >&2; exit 2; }
fi
[ -s "$out" ] || { echo "FAIL: no output written: $out" >&2; exit 2; }
echo "wrote $out"
