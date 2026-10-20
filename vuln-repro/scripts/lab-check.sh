#!/usr/bin/env bash
# Check host capabilities for the vulnerability reproduction lab.
# Usage: lab-check.sh [--json]
set -u

json=0
[ "${1:-}" = "--json" ] && json=1

declare -a names=()
declare -a oks=()
declare -a details=()
missing=0

add() {
  names+=("$1"); oks+=("$2"); details+=("$3")
}

need_cmd() {
  local name=$1; shift
  if command -v "$name" >/dev/null 2>&1; then
    add "$name" 1 "$(command -v "$name")"
  else
    add "$name" 0 "not found"
    missing=$((missing+1))
  fi
}

opt_cmd() {
  local name=$1; shift
  if command -v "$name" >/dev/null 2>&1; then
    add "$name" 1 "$(command -v "$name")"
  else
    add "$name" 0 "not found (optional)"
  fi
}

need_cmd qemu-system-x86_64
need_cmd qemu-img
need_cmd ssh
need_cmd sshpass
need_cmd vncsnapshot
need_cmd vncdo
need_cmd ffmpeg
need_cmd ffprobe
need_cmd python3
need_cmd ss
opt_cmd systemd-run
opt_cmd sudo

[ -r /proc/meminfo ] || { echo "FAIL: this lab requires a Linux host (/proc/meminfo missing)" >&2; exit 2; }

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  add kvm 1 "/dev/kvm readable/writable"
else
  add kvm 0 "/dev/kvm not readable/writable"
  missing=$((missing+1))
fi

ffmpeg_libx264=""
for candidate in /usr/bin/ffmpeg "$(command -v ffmpeg 2>/dev/null || true)"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] || continue
  if "$candidate" -hide_banner -encoders 2>/dev/null | grep -q libx264; then
    ffmpeg_libx264=$candidate
    break
  fi
done
if [ -n "$ffmpeg_libx264" ]; then
  add ffmpeg-libx264 1 "$ffmpeg_libx264"
else
  add ffmpeg-libx264 0 "libx264 encoder missing (try /usr/bin/ffmpeg)"
  missing=$((missing+1))
fi

if command -v python3 >/dev/null 2>&1; then
  if python3 -I -c 'import docx, PIL' >/dev/null 2>&1; then
    add python-docx-Pillow 1 "available"
  else
    add python-docx-Pillow 0 "python-docx and/or Pillow missing"
    missing=$((missing+1))
  fi
fi

mem_avail=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
mem_avail=${mem_avail:-0}
disk_dir=${LAB_VM_DIR:-/opt/winlab/vms}
disk_avail=$(df -m "$disk_dir" 2>/dev/null | awk 'NR==2{print $4}')
disk_avail=${disk_avail:-0}
add mem_available_mb 1 "$mem_avail"
add disk_available_mb 1 "$disk_avail (on $disk_dir)"

if [ "$json" -eq 1 ]; then
  printf '{"ok":%s,"missing":%d,"checks":[' "$([ "$missing" -eq 0 ] && echo true || echo false)" "$missing"
  first=1
  for i in "${!names[@]}"; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"name":"%s","ok":%s,"detail":"%s"}' "${names[$i]}" \
      "$([ "${oks[$i]}" -eq 1 ] && echo true || echo false)" "${details[$i]}"
  done
  printf ']}\n'
else
  printf '%-24s %-6s %s\n' NAME OK DETAIL
  for i in "${!names[@]}"; do
    printf '%-24s %-6s %s\n' "${names[$i]}" "$([ "${oks[$i]}" -eq 1 ] && echo yes || echo NO)" "${details[$i]}"
  done
  printf '\nmemory available: %s MB, disk available on %s: %s MB\n' "$mem_avail" "$disk_dir" "$disk_avail"
  [ "$missing" -eq 0 ] && echo "RESULT: OK" || echo "RESULT: MISSING $missing required capability(ies)"
fi

[ "$missing" -eq 0 ] || exit 2
