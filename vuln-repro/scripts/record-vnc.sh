#!/usr/bin/env bash
# Capture VNC frames at a fixed interval for a bounded duration.
# Usage: record-vnc.sh --display 127.0.0.1:6 --out frames/ --fps 2.5 --duration 180
# --duration is mandatory: an unbounded capture loop can fill the disk.
# Note: nominal fps is the sleep interval target; the achieved frame rate is
# slightly lower (each vncsnapshot call takes ~5-50 ms). When encoding later,
# pass --fps <frames/wall-clock-seconds> (the measured rate) to keep real-time
# playback speed; encode-frames.sh prints the measured rate for you.
set -u

display=""
out=""
fps="2.5"
duration=""
usage() {
  echo "usage: $0 --display <host:display> --out <dir> --duration <seconds> [--fps 2.5]" >&2
  exit 2
}
while [ $# -gt 0 ]; do
  case "$1" in
    --display) display=${2:?"--display requires a value"}; shift 2;;
    --out) out=${2:?"--out requires a value"}; shift 2;;
    --fps) fps=${2:?"--fps requires a value"}; shift 2;;
    --duration) duration=${2:?"--duration requires a value"}; shift 2;;
    -h|--help) usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done
[ -n "$display" ] && [ -n "$out" ] && [ -n "$duration" ] || usage
command -v vncsnapshot >/dev/null 2>&1 || { echo "FAIL: vncsnapshot not found" >&2; exit 2; }
case "$duration" in *[!0-9]*) echo "FAIL: --duration must be seconds (integer)" >&2; exit 2;; esac

mkdir -p "$out"
interval=$(awk -v f="$fps" 'BEGIN{ if (f<=0) f=1; printf "%.6f", 1/f }')
start=$(date +%s)
i=0
failed=0
echo "recording $display -> $out at ${fps}fps (interval ${interval}s) for ${duration}s"
while :; do
  now=$(date +%s)
  [ $((now - start)) -ge "$duration" ] && break
  n=$(printf '%06d' "$i")
  if ! vncsnapshot -allowblank -quiet "$display" "$out/frame-$n.jpg" >/dev/null 2>&1; then
    failed=$((failed+1))
  fi
  i=$((i+1))
  sleep "$interval"
done
elapsed=$(( $(date +%s) - start ))
echo "done: $i attempts, $failed failed, $elapsed s elapsed"
if [ "$i" -gt 0 ]; then
  got=$(ls "$out"/frame-*.jpg 2>/dev/null | wc -l)
  awk -v g="$got" -v e="$elapsed" 'BEGIN{ if (e>0) printf "measured fps: %.4f (use this as encode --fps)\n", g/e }'
  [ "$got" -eq 0 ] && { echo "FAIL: no frames captured (VNC unreachable?)" >&2; exit 2; }
  [ "$failed" -gt 0 ] && echo "WARN: $failed capture attempts failed; timeline may have gaps" >&2
else
  echo "FAIL: no capture attempts completed" >&2
  exit 2
fi
