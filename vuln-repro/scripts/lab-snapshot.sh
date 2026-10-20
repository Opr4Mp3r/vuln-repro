#!/bin/bash
# lab-snapshot.sh — create a qcow2 snapshot for a VM.
# Usage: lab-snapshot.sh --name <vm> --tag baseline [--disk PATH] [--socket PATH]
# If the VM is running, use the QEMU monitor (savevm, 60 s timeout, then verify
# the tag actually appears in `info snapshots`); otherwise use qemu-img.
set -eu
NAME=""; TAG=""; DISK=""; SOCK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME=$2; shift 2;;
    --tag) TAG=$2; shift 2;;
    --disk) DISK=$2; shift 2;;
    --socket) SOCK=$2; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$NAME" ] && [ -n "$TAG" ] || { echo "usage: lab-snapshot.sh --name <vm> --tag <tag> [--disk PATH] [--socket PATH]" >&2; exit 2; }
VMDIR=${LAB_VM_DIR:-/opt/winlab/vms}
DISK=${DISK:-$VMDIR/$NAME.qcow2}
SOCK=${SOCK:-/tmp/$NAME-mon.sock}
[ -e "$DISK" ] || { echo "disk not found: $DISK" >&2; exit 1; }
SUDO=""; [ -w "$DISK" ] || SUDO=sudo

MON="$(dirname "$0")/qemu-monitor.py"
monitor_cmd() {
  local cmd="$1" tmo="${2:-30}" rc=0
  set +e
  "$MON" --socket "$SOCK" --command "$cmd" --timeout "$tmo" --quiet
  rc=$?
  set -e
  if [ "$rc" -eq 2 ] && command -v sudo >/dev/null 2>&1; then
    sudo -n "$MON" --socket "$SOCK" --command "$cmd" --timeout "$tmo" --quiet
    return $?
  fi
  return "$rc"
}

if [ -S "$SOCK" ] && pgrep -f "qemu-system.*$DISK" >/dev/null 2>&1; then
  echo "savevm via monitor: $SOCK"
  monitor_cmd "savevm $TAG" 60
  # savevm can time out silently; verify the snapshot really exists.
  SNAPLIST="$(monitor_cmd "info snapshots" 30 || true)"
  if printf '%s\n' "$SNAPLIST" | grep -q -- "$TAG"; then
    echo "verified: snapshot '$TAG' present in info snapshots"
  else
    echo "x FAILED: '$TAG' not found in info snapshots (savevm did not complete)" >&2
    exit 1
  fi
else
  echo "VM not running; qemu-img snapshot -c $TAG $DISK"
  $SUDO qemu-img snapshot -c "$TAG" "$DISK"
fi
echo "snapshot '$TAG' created for $NAME"
