#!/bin/bash
# auto-repro.sh — one-shot automated reproduce-and-record for a lab VM.
#
# Battle-tested pipeline (generalized from a real driver campaign): host-side vncsnapshot
# loop keeps shooting through guest BSODs; the PoC storyboard is launched as a
# VISIBLE interactive task via schtasks /IT (no keystroke injection needed);
# guest death is detected by the forwarded SSH port dropping; recording
# continues N seconds past death to capture BSOD + auto-reboot; frames are
# encoded with a burned-in wall-clock timestamp.
#
# Usage:
#   auto-repro.sh --display 127.0.0.1:5 --ssh-port 2224 --ssh-user administrator \
#                 --go-cmd 'c:\p\go.cmd' --out repro.mp4 \
#                 [--mode crash|hang] [--watch 600] [--post-death 150] \
#                 [--duration 240] [--fps 5] [--heartbeat] [--vm-disk PATH] \
#                 [--cards cards/] [--no-encode]
#
# --cards: dir from make-cards.py (placement.tsv); passed to encode-frames.sh
#   so title/result/conclusion cards are spliced into the final MP4.
# --no-encode: record only. For crash videos whose result card needs the REAL
#   event-log data (BugCheck code, Event 1001 RecordId): record first, read the
#   event log, run make-cards.py, then encode manually with --cards.
#
# Prereqs: vncsnapshot, sshpass, ffmpeg with libx264 (via encode-frames.sh);
#          LAB_SSH_PASSWORD must hold the guest password;
#          guest prepared per references/recording.md (AutoAdminLogon,
#          monitor timeout off, go.cmd staged, recoveryenabled no).
set -u

display=""; ssh_port=""; ssh_user=""; go_cmd=""; out=""; mode="crash"
watch=600; post_death=150; duration=240; fps=5; heartbeat=0; vm_disk=""
cards=""; no_encode=0
task="repro-$$"
usage() {
  cat >&2 <<EOF
usage: $0 --display host:d --ssh-port N --ssh-user U --go-cmd 'c:\\p\\go.cmd' --out file.mp4
          [--mode crash|hang] [--watch 600] [--post-death 150] [--duration 240]
          [--fps 5] [--heartbeat] [--vm-disk /path/to/vm.qcow2]
          [--cards <dir>] [--no-encode]
  crash mode: trigger, wait for SSH to drop (guest death), keep recording --post-death s
  hang  mode: trigger, record --duration s total (use --heartbeat for the outage evidence)
EOF
  exit 2
}
while [ $# -gt 0 ]; do
  case "$1" in
    --display) display=${2:?"--display requires a value"}; shift 2;;
    --ssh-port) ssh_port=${2:?"--ssh-port requires a value"}; shift 2;;
    --ssh-user) ssh_user=${2:?"--ssh-user requires a value"}; shift 2;;
    --go-cmd) go_cmd=${2:?"--go-cmd requires a value"}; shift 2;;
    --out) out=${2:?"--out requires a value"}; shift 2;;
    --mode) mode=${2:?"--mode requires a value"}; shift 2;;
    --watch) watch=${2:?"--watch requires a value"}; shift 2;;
    --post-death) post_death=${2:?"--post-death requires a value"}; shift 2;;
    --duration) duration=${2:?"--duration requires a value"}; shift 2;;
    --fps) fps=${2:?"--fps requires a value"}; shift 2;;
    --task) task=${2:-}; shift 2;;
    --vm-disk) vm_disk=${2:?"--vm-disk requires a value"}; shift 2;;
    --cards) cards=${2:?"--cards requires a value"}; shift 2;;
    --heartbeat) heartbeat=1; shift;;
    --no-encode) no_encode=1; shift;;
    -h|--help) usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done
[ -n "$display" ] && [ -n "$ssh_port" ] && [ -n "$ssh_user" ] && [ -n "$go_cmd" ] && [ -n "$out" ] || usage
case "$mode" in crash|hang) ;; *) echo "FAIL: --mode must be crash or hang" >&2; exit 2;; esac
command -v vncsnapshot >/dev/null 2>&1 || { echo "FAIL: vncsnapshot not found" >&2; exit 2; }
command -v sshpass >/dev/null 2>&1 || { echo "FAIL: sshpass not found" >&2; exit 2; }
[ -n "${LAB_SSH_PASSWORD:-}" ] || { echo "FAIL: LAB_SSH_PASSWORD not set (guest password)" >&2; exit 2; }
ENC="$(dirname "$0")/encode-frames.sh"
[ -x "$ENC" ] || { echo "FAIL: encode-frames.sh not found next to this script" >&2; exit 2; }

WORK="$(dirname "$out")"; BASE="$(basename "$out" .mp4)"
F="$WORK/frames-$BASE"; STOP="$WORK/STOP-$BASE"; HBLOG="$WORK/heartbeat-$BASE.log"
interval=$(awk -v f="$fps" 'BEGIN{ if (f<=0) f=1; printf "%.3f", 1/f }')
mkdir -p "$F"; rm -f "$STOP" "$F"/frame-*.jpg "$HBLOG"

ssh_ok() { sshpass -p "$LAB_SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=4 -p "$ssh_port" "$ssh_user@127.0.0.1" "$@" >/dev/null 2>&1; }
port_open() { timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$ssh_port" >/dev/null 2>&1; }

echo "[$(date +%T)] auto-repro: mode=$mode display=$display ssh=127.0.0.1:$ssh_port go=$go_cmd"

# 1) recorder: host-side, survives guest BSOD
i=0; failed=0
( while [ ! -f "$STOP" ]; do
    vncsnapshot -allowblank -quiet -quality 82 "$display" "$(printf '%s/frame-%06d.jpg' "$F" "$i")" >/dev/null 2>&1 || :
    i=$((i+1)); sleep "$interval"
  done; echo "$i" > "$F.count" ) &
REC=$!
echo "[$(date +%T)] recorder started pid=$REC -> $F"

# 2) optional external heartbeat (hang/DoS outage evidence, from the host)
if [ "$heartbeat" -eq 1 ]; then
  ( while [ ! -f "$STOP" ]; do
      T=$(date +%H:%M:%S)
      if port_open && ssh_ok 'echo HB'; then R=OK; else R=TIMEOUT; fi
      echo "$T $R" >> "$HBLOG"
      sleep 2
    done ) &
  HB=$!
  echo "[$(date +%T)] heartbeat started pid=$HB -> $HBLOG"
fi

# 3) trigger: visible interactive task on the unlocked console
ssh_ok "schtasks /create /tn $task /tr \"cmd /c $go_cmd\" /sc once /st 23:59 /ru $ssh_user /rp $LAB_SSH_PASSWORD /it /f" \
  || { echo "FAIL: schtasks /create failed (guest reachable? go.cmd path?)" >&2; touch "$STOP"; exit 2; }
ssh_ok "schtasks /run /tn $task" || { echo "FAIL: schtasks /run failed" >&2; touch "$STOP"; exit 2; }
echo "[$(date +%T)] triggered: $go_cmd (task $task)"

start=$(date +%s)
died=0; qemu_alive=""
if [ "$mode" = "crash" ]; then
  # 4) wait for guest death: forwarded SSH port drops
  while [ $(( $(date +%s) - start )) -lt "$watch" ]; do
    if ! port_open; then
      if [ -n "$vm_disk" ]; then Q=$(pgrep -fc "qemu-system.*$vm_disk" 2>/dev/null || echo 0)
      else Q=$(pgrep -c '^qemu-system' 2>/dev/null || echo 0); fi
      qemu_alive=$Q
      echo "[$(date +%T)] guest DOWN after $(( $(date +%s) - start ))s (qemu_alive=$Q; >0=real guest death, 0=VM process gone)"
      died=1
      break
    fi
    sleep 3
  done
  [ "$died" -eq 1 ] || echo "WARN: guest survived ${watch}s watch window; encoding what was recorded" >&2
  # 5) keep recording through BSOD + auto-reboot
  sleep "$post_death"
else
  sleep "$duration"
fi

# 6) stop everything, best-effort cleanup
touch "$STOP"; wait "$REC" 2>/dev/null
[ -n "${HB:-}" ] && wait "$HB" 2>/dev/null
ssh_ok "schtasks /end /tn $task" 2>/dev/null; ssh_ok "schtasks /delete /tn $task /f" 2>/dev/null

elapsed=$(( $(date +%s) - start ))
frames=$(ls "$F"/frame-*.jpg 2>/dev/null | wc -l)
measured=$(awk -v g="$frames" -v e="$elapsed" 'BEGIN{ if (e>0) printf "%.4f", g/e; else print 0 }')
echo "[$(date +%T)] frames=$frames elapsed=${elapsed}s measured_fps=$measured"

# 7) encode with wall-clock timestamp burned in
if [ "$no_encode" -eq 1 ]; then
  echo "[$(date +%T)] --no-encode: frames kept in $F ($frames frames, measured_fps=$measured)"
  echo "next: read the real event log, run make-cards.py, then e.g.:"
  echo "  $(dirname "$0")/encode-frames.sh --frames '$F' --out '$out' --fps $measured --timestamp --preset medium --crf 19 --cards <cards-dir>"
  [ "$mode" != "crash" ] || [ "$died" -eq 1 ] || exit 3
  exit 0
fi
enc_args=(--frames "$F" --out "$out" --fps "$measured" --timestamp --preset medium --crf 19)
[ -n "$cards" ] && enc_args+=(--cards "$cards")
"$ENC" "${enc_args[@]}" || exit 2
echo "[$(date +%T)] heartbeat summary: $(awk '{c[$2]++} END {for (k in c) printf "%s=%d ", k, c[k]}' "$HBLOG" 2>/dev/null || echo n/a)"

"$(dirname "$0")/check-mp4.sh" "$out" || exit 2
[ "$mode" != "crash" ] || [ "$died" -eq 1 ] || exit 3
exit 0
