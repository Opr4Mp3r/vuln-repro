#!/bin/bash
# lab-ls.sh — list campaign VMs, their state, resources and ports.
# VM overlays live in LAB_VM_DIR (default /opt/winlab/vms). Images outside that
# dir (e.g. legacy masters) can be listed via LAB_EXTRA_IMAGES (space-separated).
set -u
VMDIR=${LAB_VM_DIR:-/opt/winlab/vms}
EXTRA_IMAGES=${LAB_EXTRA_IMAGES:-}
printf "%-24s %-8s %-7s %-6s %-10s %s\n" "NAME" "STATE" "VCPU" "MEM" "SSH_PORT" "DISK"
for d in "$VMDIR"/*.qcow2 $EXTRA_IMAGES; do
  [ -e "$d" ] || continue
  name=$(basename "$d" .qcow2)
  pid=""
  for p in $(pgrep -f "qemu-system.*$d" 2>/dev/null); do pid=$p; break; done
  if [ -n "$pid" ]; then
    state=running
    vcpu=$(ps -o args= -p "$pid" | grep -oE "\-smp [0-9]+" | awk '{print $2}')
    rawm=$(ps -o args= -p "$pid" | grep -oE "\-m [0-9]+[GgMm]?" | awk '{print $2}')
    numm=${rawm//[GgMm]/}
    case "$rawm" in
      *[Mm]) mem=$(( (numm + 1023) / 1024 ));;
      [0-9]*) if [ "$numm" -ge 64 ]; then mem=$(( (numm + 1023) / 1024 )); else mem=$numm; fi;;
      *) mem=0;;
    esac
    sshp=$(ps -o args= -p "$pid" | grep -oE "hostfwd=tcp:[0-9.]+:[0-9]+" | grep -oE "[0-9]+$")
  else
    state=stopped; vcpu=-; mem=-; sshp=-
  fi
  printf "%-24s %-8s %-7s %-6s %-10s %s\n" "$name" "$state" "$vcpu" "${mem}G" "$sshp" "$d"
done
echo
awk '/MemAvailable/{printf "memory: %dG available  ", $2/1048576}' /proc/meminfo
awk '{printf "load: %s\n", $1}' /proc/loadavg
