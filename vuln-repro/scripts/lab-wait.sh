#!/bin/bash
# lab-wait.sh — wait until a VM's SSH port answers, optionally verify login.
# Usage: lab-wait.sh --name <vm> --port 2224 [--timeout 180] [--ssh-user user]
# Password, if needed, comes from LAB_SSH_PASSWORD (never hardcode it here).
set -u
NAME=""; PORT=""; TIMEOUT=180; USER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME=$2; shift 2;;
    --port) PORT=$2; shift 2;;
    --timeout) TIMEOUT=$2; shift 2;;
    --ssh-user) USER=$2; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$PORT" ] || { echo "usage: lab-wait.sh --name <vm> --port <ssh-port> [--timeout 180] [--ssh-user user]" >&2; exit 2; }
start=$(date +%s)
while :; do
  if (echo >/dev/tcp/127.0.0.1/"$PORT") >/dev/null 2>&1; then
    echo "SSH port $PORT is open${NAME:+ for $NAME}"
    break
  fi
  now=$(date +%s)
  if [ $((now - start)) -ge "$TIMEOUT" ]; then
    echo "timeout after ${TIMEOUT}s waiting for 127.0.0.1:$PORT" >&2
    exit 1
  fi
  sleep 2
done

if [ -n "$USER" ]; then
  if [ -n "${LAB_SSH_PASSWORD:-}" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$LAB_SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      -p "$PORT" "$USER@127.0.0.1" 'whoami' || { echo "SSH login failed" >&2; exit 1; }
  else
    echo "SSH port open; set LAB_SSH_PASSWORD and install sshpass to verify login" >&2
  fi
fi
