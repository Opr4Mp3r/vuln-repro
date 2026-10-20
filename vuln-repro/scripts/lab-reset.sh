#!/bin/bash
# lab-reset.sh — revert a VM to a qcow2 snapshot.
# Usage: lab-reset.sh --name <vm> --tag baseline --yes [--disk PATH] [--socket PATH]
# Reverting discards current VM state; --yes is required (or LAB_ASSUME_YES=1).
set -eu
NAME=""; TAG=""; DISK=""; SOCK=""; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME=$2; shift 2;;
    --tag) TAG=$2; shift 2;;
    --disk) DISK=$2; shift 2;;
    --socket) SOCK=$2; shift 2;;
    --yes) YES=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$NAME" ] && [ -n "$TAG" ] || { echo "usage: lab-reset.sh --name <vm> --tag <tag> --yes [--disk PATH] [--socket PATH]" >&2; exit 2; }
if [ "$YES" -ne 1 ] && [ "${LAB_ASSUME_YES:-0}" != "1" ]; then
  echo "refusing to reset without --yes (or LAB_ASSUME_YES=1)" >&2
  exit 2
fi
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
  echo "loadvm via monitor: $SOCK"
  monitor_cmd "loadvm $TAG" 60
else
  echo "VM not running; qemu-img snapshot -a $TAG $DISK"
  $SUDO qemu-img snapshot -a "$TAG" "$DISK"
fi
echo "VM $NAME reverted to snapshot '$TAG'"
