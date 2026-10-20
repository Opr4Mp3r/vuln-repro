#!/bin/bash
# lab-down.sh — stop one named campaign VM (never a global pkill).
# Usage: lab-down.sh --name <vm> [--rm]
# The disk is resolved as $LAB_VM_DIR/<vm>.qcow2; if absent there, the name is
# matched against LAB_EXTRA_IMAGES (space-separated paths of images kept outside
# the VM dir, e.g. a legacy master). --rm only ever deletes overlays inside
# LAB_VM_DIR — masters found via LAB_EXTRA_IMAGES are never removed.
set -eu
NAME=""; RM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME=${2:?"--name requires a value"}; shift 2;;
    --rm) RM=1; shift;;
    *) [ -z "$NAME" ] && NAME=$1; shift;;
  esac
done
[ -n "$NAME" ] || { echo "usage: lab-down.sh --name <vm> [--rm]" >&2; exit 2; }
VMDIR=${LAB_VM_DIR:-/opt/winlab/vms}
DISK=""
if [ -e "$VMDIR/$NAME.qcow2" ]; then
  DISK=$VMDIR/$NAME.qcow2
else
  for d in ${LAB_EXTRA_IMAGES:-}; do
    if [ "$(basename "$d" .qcow2)" = "$NAME" ]; then DISK=$d; break; fi
  done
fi
[ -n "$DISK" ] && [ -e "$DISK" ] || { echo "no such VM: $NAME (looked in $VMDIR and LAB_EXTRA_IMAGES)" >&2; exit 1; }
PIDS=$(pgrep -f "qemu-system.*$DISK" || true)
if [ -n "$PIDS" ]; then
  if ! echo "$PIDS" | xargs kill -9 2>/dev/null; then
    echo "$PIDS" | xargs sudo kill -9
  fi
  echo "stopped VM [$NAME] (pid: $(echo "$PIDS" | tr '\n' ' '))"
else
  echo "VM [$NAME] was not running"
fi
rm -f "/tmp/$NAME-mon.sock" "/tmp/$NAME.pid"
if [ "$RM" -eq 1 ]; then
  case "$DISK" in
    "$VMDIR"/*) rm -f "$DISK" 2>/dev/null || sudo rm -f "$DISK"; echo "removed overlay: $DISK";;
    *) echo "refusing --rm: $DISK is outside $VMDIR (master image?)" >&2; exit 2;;
  esac
fi
