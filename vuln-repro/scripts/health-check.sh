#!/bin/bash
# health-check.sh — agent 每 30 分钟的必做自检
# 输出: mem_avail=<可用内存> cgroup=<当前会话已用> load=<1分钟负载> procs=<agent进程数>
# agent 进程名用 LAB_AGENT_PROC 覆盖（默认 claude；ZCode 等控制器请设为对应进程名）
AGENT_PROC=${LAB_AGENT_PROC:-claude}
awk '/MemAvailable/{printf "mem_avail=%.1fG ", $2/1048576}' /proc/meminfo 2>/dev/null || { echo "FAIL: requires Linux (/proc/meminfo)" >&2; exit 2; }
cg=$(awk -F: '/^0::/{print $3}' /proc/self/cgroup)
if [ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/memory.current" ]; then
  awk '{printf "cgroup=%.2fG ", $1/1073741824}' "/sys/fs/cgroup$cg/memory.current"
fi
awk '{printf "load=%s ", $1}' /proc/loadavg
p=$(pgrep -cx "$AGENT_PROC" 2>/dev/null | head -1)
printf "procs=%s [agent=%s]\n" "${p:-0}" "$AGENT_PROC"
