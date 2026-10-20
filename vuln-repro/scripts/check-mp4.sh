#!/usr/bin/env bash
# Check a reproduction MP4: H.264, 1920x1080, 20-60 fps, sane duration.
# Duration policy: FAIL outside 60-600 s (clearly broken); WARN outside 90-300 s
# (references/recording.md spec is 1.5-5 minutes; review before sharing).
set -u

usage() {
  echo "usage: $0 <video.mp4>" >&2
  exit 2
}

[ $# -eq 1 ] || usage
f=$1
[ -s "$f" ] || { echo "FAIL: missing or empty: $f" >&2; exit 2; }
command -v ffprobe >/dev/null 2>&1 || { echo "FAIL: ffprobe not found" >&2; exit 2; }

read -r codec width height fps duration < <(
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height,r_frame_rate \
    -show_entries format=duration -of default=nw=1:nk=1 "$f" 2>/dev/null |
    awk 'NR==1{c=$0} NR==2{w=$0} NR==3{h=$0} NR==4{split($0,a,"/"); if(a[2]>0) f=a[1]/a[2]; else f=0} NR==5{d=$0} END{printf "%s %s %s %.3f %.3f\n", c,w,h,f,d}'
)
[ -n "${codec:-}" ] || { echo "FAIL: could not probe video stream (corrupt file or not a video?)" >&2; exit 2; }

fail=0
[ "$codec" = "h264" ] || { echo "FAIL: codec=$codec, expected h264" >&2; fail=1; }
[ "${width:-}" = "1920" ] && [ "${height:-}" = "1080" ] || { echo "FAIL: ${width}x${height}, expected 1920x1080" >&2; fail=1; }
awk -v f="$fps" 'BEGIN{exit !(f>=20 && f<=60)}' || { echo "FAIL: fps=$fps outside 20-60" >&2; fail=1; }
awk -v d="$duration" 'BEGIN{exit !(d>=60 && d<=600)}' || { echo "FAIL: duration=${duration}s outside 60-600s" >&2; fail=1; }
awk -v d="$duration" 'BEGIN{exit !(d>=90 && d<=300)}' || echo "WARN: duration=${duration}s outside the 1.5-5 min spec (SKILL.md §5); review before submitting" >&2

if [ "$fail" -ne 0 ]; then exit 2; fi
echo "OK: $f codec=$codec ${width}x${height} fps=$fps duration=${duration}s"
sha256sum "$f"
