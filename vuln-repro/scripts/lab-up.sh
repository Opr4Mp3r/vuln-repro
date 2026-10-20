#!/bin/bash
# lab-up.sh — create/start a budget-aware campaign VM.
#
# Usage:
#   lab-up.sh --name <vm> --tier S|M|L|XL [--base IMAGE] [--vmdir DIR] [--dry-run]
#   lab-up.sh <vm> --tier M
#
# Budget model (hard gate): total RAM - running qemu allocations - host reserve
# (3G) - 8G per active agent session. Tier requests are downgraded if needed;
# explicit vcpu/mem requests are rejected. Each VM runs in a systemd scope with
# MemoryMax=1.3x and CPUQuota=(vcpu+1)*100% so a runaway VM cannot take the host.
# All forwarded ports (SSH hostfwd, VNC) bind to 127.0.0.1 only: the guest is an
# intentionally vulnerable machine and must not be reachable from the network.
set -eu

NAME=""; TIER=""; VCPU=""; MEM=""; DRY=0
BASE=${LAB_BASE_IMAGE:-/opt/winlab/base-clean.qcow2}
VMDIR=${LAB_VM_DIR:-/opt/winlab/vms}
AGENT_PROC=${LAB_AGENT_PROC:-claude}
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME=$2; shift 2;;
    --tier) TIER=$2; shift 2;;
    --base) BASE=$2; shift 2;;
    --vmdir) VMDIR=$2; shift 2;;
    --dry-run) DRY=1; shift;;
    [0-9]*) if [ -z "$VCPU" ]; then VCPU=$1; elif [ -z "$MEM" ]; then MEM=$1; fi; shift;;
    *) if [ -z "$NAME" ]; then NAME=$1; fi; shift;;
  esac
done
[ -n "$NAME" ] || { echo "usage: lab-up.sh --name <vm> --tier S|M|L|XL [--base IMAGE] [--vmdir DIR] [--dry-run]" >&2; exit 2; }
case "$NAME" in *[!a-z0-9-]*|"") echo "name must be lowercase letters/digits/-" >&2; exit 2;; esac
[ -r /proc/meminfo ] || { echo "this script requires a Linux host (/proc/meminfo missing)" >&2; exit 2; }
[ -r "$BASE" ] || { echo "base image not readable: $BASE" >&2; exit 2; }

case "${TIER:-}" in
  S) VCPU=${VCPU:-1};  MEM=${MEM:-2};;
  M) VCPU=${VCPU:-2};  MEM=${MEM:-3};;
  L) VCPU=${VCPU:-4};  MEM=${MEM:-5};;
  XL) VCPU=${VCPU:-6}; MEM=${MEM:-6};;
  "") VCPU=${VCPU:-2}; MEM=${MEM:-3};;
  *) echo "unknown tier $TIER (S|M|L|XL)" >&2; exit 2;;
esac
[ "$MEM" -lt 2 ] && { echo "memory must be >= 2G" >&2; exit 2; }

TOTAL=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
AVAIL=$(awk '/MemAvailable/{printf "%d", $2/1048576}' /proc/meminfo)
COMMITTED=0
for p in $(pgrep -f "qemu-system.*-m " 2>/dev/null || true); do
  raw=$(ps -o args= -p "$p" 2>/dev/null | grep -oE '\-m [0-9]+[GgMm]?' | head -1 | grep -oE '[0-9]+[GgMm]?' || true)
  num=${raw//[GgMm]/}
  case "$raw" in
    *[Mm]) g=$(( (num + 1023) / 1024 ));;
    [0-9]*) if [ "$num" -ge 64 ]; then g=$(( (num + 1023) / 1024 )); else g=$num; fi;;
    *) g=0;;
  esac
  COMMITTED=$((COMMITTED + g))
done
SESS=$(pgrep -cx "$AGENT_PROC" 2>/dev/null || true); SESS=${SESS:-0}
case "$SESS" in ''|*[!0-9]*) SESS=0;; esac
[ "$SESS" -lt 1 ] && SESS=1
AGENT_NEED=$((SESS * 8))
HOST_RES=3
BUDGET=$((TOTAL - COMMITTED - HOST_RES - AGENT_NEED))
[ "$BUDGET" -lt 0 ] && BUDGET=0

echo "== budget =="
echo "  total=${TOTAL}G committed=${COMMITTED}G agent_sessions=${SESS} [${AGENT_PROC}] (${AGENT_NEED}G) host_reserve=${HOST_RES}G"
echo "  MemAvailable=${AVAIL}G budget=${BUDGET}G request=${VCPU}vCPU/${MEM}G${TIER:+ (tier $TIER)}"

if [ "$MEM" -gt "$BUDGET" ]; then
  if [ "$DRY" -eq 1 ]; then
    echo "  ! dry-run: a real run would be refused (budget ${BUDGET}G < ${MEM}G)"
  elif [ -n "$TIER" ]; then
    NEW=$(( BUDGET > 2 ? BUDGET : 0 ))
    if [ "$NEW" -ge 2 ]; then
      echo "  ! budget low, downgrading memory to ${NEW}G (requested ${MEM}G)"
      MEM=$NEW
    else
      echo "  x refused: budget ${BUDGET}G < 2G; stop another VM (lab-ls.sh) or wait" >&2; exit 3
    fi
  else
    echo "  x refused: explicit ${MEM}G > budget ${BUDGET}G" >&2; exit 3
  fi
fi
if [ "$AVAIL" -lt $((MEM + 4)) ]; then
  if [ "$DRY" -eq 1 ]; then
    echo "  ! dry-run: MemAvailable ${AVAIL}G < request+4G (real run would be refused)"
  else
    echo "  x refused: MemAvailable ${AVAIL}G < request+4G" >&2; exit 3
  fi
fi

# Pick free SSH/VNC ports unless already recorded in meta.
SLOT=2; SLOT_MAX=20
port_busy() { ss -ltn 2>/dev/null | grep -q " $1 " || ss -ltn 2>/dev/null | grep -q ":$1 "; }
while port_busy $((2221+SLOT)) || port_busy $((5903+SLOT+1)); do
  SLOT=$((SLOT+1))
  [ "$SLOT" -gt "$SLOT_MAX" ] && { echo "x refused: no free port slot below $((2221+SLOT_MAX)) (stale VMs? lab-ls.sh)" >&2; exit 3; }
done
SSHP=$((2221+SLOT)); VNCD=$((3+SLOT)); VNCP=$((5900+VNCD))

DISK=$VMDIR/$NAME.qcow2
SOCK=/tmp/$NAME-mon.sock; PIDF=/tmp/$NAME.pid
if pgrep -f "qemu-system.*$DISK" >/dev/null 2>&1; then
  echo "VM $NAME is already running (disk $DISK)" >&2
  exit 2
fi
if [ "$DRY" -eq 1 ]; then
  echo "dry-run: name=$NAME disk=$DISK ssh_port=$SSHP vnc=:$VNCD cgroup=vm-$NAME"
  echo "dry-run: qemu-system-x86_64 -enable-kvm -cpu host -smp $VCPU -m ${MEM}G \\"
  echo "  -drive id=d0,file=$DISK,format=qcow2,if=none -device ide-hd,drive=d0,bus=ide.0 \\"
  echo "  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$SSHP-:22 -device e1000,netdev=n0 \\"
  echo "  -device usb-ehci,id=ehci -device usb-tablet -display vnc=127.0.0.1:$VNCD \\"
  echo "  -monitor unix:$SOCK,server,nowait -daemonize -pidfile $PIDF"
  exit 0
fi
SUDO=""
if [ ! -d "$VMDIR" ] || [ ! -w "$VMDIR" ]; then
  if command -v sudo >/dev/null 2>&1; then SUDO=sudo
  else echo "VM dir not writable and sudo unavailable: $VMDIR" >&2; exit 2; fi
fi
if [ -e "$DISK" ] && [ ! -w "$DISK" ]; then SUDO=sudo; fi
$SUDO mkdir -p "$VMDIR"
if [ -e "$DISK" ]; then
  echo "reuse overlay: $DISK"
else
  $SUDO qemu-img create -f qcow2 -b "$BASE" -F qcow2 "$DISK" >/dev/null
  echo "created overlay: $DISK"
fi

MEMMAX=$(( MEM * 13 / 10 ))
CPUQ=$(( (VCPU + 1) * 100 ))
QEMU=(qemu-system-x86_64 -enable-kvm -cpu host -smp "$VCPU" -m "${MEM}G" \
  -drive id=d0,file="$DISK",format=qcow2,if=none \
  -device ide-hd,drive=d0,bus=ide.0 \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${SSHP}-:22 \
  -device e1000,netdev=n0 \
  -device usb-ehci,id=ehci -device usb-tablet \
  -display vnc=127.0.0.1:$VNCD \
  -monitor unix:$SOCK,server,nowait \
  -daemonize -pidfile "$PIDF")
if command -v systemd-run >/dev/null 2>&1; then
  $SUDO systemd-run --scope -q --unit="vm-$NAME" \
    -p MemoryMax=${MEMMAX}G -p CPUQuota=${CPUQ}% "${QEMU[@]}"
else
  echo "warn: systemd-run not found; starting without cgroup limits" >&2
  $SUDO "${QEMU[@]}"
fi

printf 'name=%s\ntier=%s\nvcpu=%s\nmem=%sG\ncgroup=vm-%s (MemoryMax=%sG, CPUQuota=%s%%)\nssh_port=%s\nvnc=:%s (%s)\nbase=%s\ncreated=%s\n' \
  "$NAME" "${TIER:-custom}" "$VCPU" "$MEM" "$NAME" "$MEMMAX" "$CPUQ" "$SSHP" "$VNCD" "$VNCP" "$BASE" "$(date '+%F %T')" \
  | $SUDO tee "$VMDIR/$NAME.meta" >/dev/null

sleep 2
echo "== VM [$NAME] started =="
echo "  SSH : ssh -p $SSHP <user>@127.0.0.1   (password from your lab profile / LAB_SSH_PASSWORD)"
echo "  VNC : :$VNCD (port $VNCP, localhost only) | monitor: $SOCK | meta: $VMDIR/$NAME.meta"
echo "  next: scripts/lab-wait.sh --name $NAME --port $SSHP"
