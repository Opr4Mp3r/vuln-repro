# 资源纪律（精简版）

> 复现也要守宿主安全：这套纪律源自一次真实事故（多会话并发 + 大文件进上下文 → 单 agent 进程 22GB RSS → OOM 连杀 → 整机重启）。

## 1. VM 预算

- 起 VM 前 `lab-up.sh --name <vm> --tier <档>`；预算拿不准先 `--dry-run`；
- 脚本硬预算闸门：`总内存（动态读 /proc/meminfo）− 已分配 VM − 宿主 3G − 8G×agent 会话数`；超限自动降档/拒绝；
- **被裁决就接受**（降档/停旧 VM/等待），禁止手改 qemu 参数绕过；
- 每 VM 自带 cgroup（MemoryMax=1.3×mem、CPUQuota=(vcpu+1)×100%）；无 systemd-run 时降级无 cgroup（脚本告警），此时更要少并发；
- **绝对禁止全局 pkill qemu**（会清掉别人的现场）——只准 `scripts/lab-down.sh --name <vm>`，用 `scripts/lab-ls.sh` 查全部。

## 2. 上下文与大文件

- \>50MB 二进制（dump/安装包/固件）禁止整文件进上下文；只准 `head -c 65536`、`strings | head -n 200`、`grep -m 5 -a`、`hexdump -C -s <off> -n 512`；
- 任何输出预判 >1MB 先截断（`| head -c 200000`）或只取统计摘要；
- VNC 截图单会话 ≤10 张；并发子代理 ≤2。

## 3. 定时自检

- 长会话每 30 分钟跑一次 `scripts/health-check.sh`，输出追加到 `health.log`；
- `cgroup` >8G 或 `mem_avail` <6G → 停止新工具调用，先收尾；
- `mem_avail` <4G 或 `load` >2×核数 → 输出进度与续跑清单，结束会话。

## 4. 收尾

- `scripts/lab-down.sh --name <vm>`（按需 `--rm` 删 overlay；VMDIR 之外的镜像永不被 --rm）；
- 确认 `lab-ls.sh` 无残留 VM；证据已归档（manifest 复核 + verified）；
- 写清"下次继续所需的最小文件集"。

## 附：环境变量

| 变量 | 作用 | 默认 |
|---|---|---|
| `LAB_BASE_IMAGE` | 母盘路径 | /opt/winlab/base-clean.qcow2 |
| `LAB_VM_DIR` | overlay/元数据目录 | /opt/winlab/vms |
| `LAB_SSH_PASSWORD` | 靶机 SSH 密码（勿写进任何文件） | 无 |
| `LAB_AGENT_PROC` | agent/控制器进程名（会话数统计用） | claude |
| `LAB_EXTRA_IMAGES` | VMDIR 之外的镜像（lab-ls 列出/lab-down 定位） | 空 |
| `LAB_ASSUME_YES` | 等价 `lab-reset.sh --yes` | 0 |
