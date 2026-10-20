# 宿主机环境搭建

## 1. 基础包（Debian/Ubuntu）

```bash
sudo apt update
sudo apt install -y qemu-system-x86 qemu-utils openssh-client sshpass \
  vncsnapshot vncdo ffmpeg python3 python3-pip fonts-noto-cjk
python3 -m pip install python-docx Pillow
```

确认：

```bash
scripts/lab-check.sh
```

## 2. KVM

```bash
ls -l /dev/kvm
sudo usermod -aG kvm "$USER"   # 重新登录生效
```

## 3. 镜像与 overlay

母盘（按 §5 安装好的基线系统）保存为 `/opt/winlab/base-clean.qcow2`——这是 `lab-up.sh` 的默认值（`LAB_BASE_IMAGE` 可覆盖）；改名就要每次传 `--base`，建议保持默认名。

```bash
# 手动创建 overlay（日常不用手敲：lab-up.sh 会自动创建）
qemu-img create -f qcow2 -F qcow2 -b /opt/winlab/base-clean.qcow2 /opt/winlab/vms/<vm>.qcow2
```

母盘只读；每次复现用独立 overlay。记录母盘与 overlay 的 SHA-256/大小。

## 4. 启动参数（手动示例）

日常一律用 `scripts/lab-up.sh`（端口与 VNC display **动态分配**、SSH/VNC 只绑 127.0.0.1、自动 cgroup）；以下仅为手动救援时的参数参考，勿照抄端口/-display 号：

```bash
qemu-system-x86_64 -enable-kvm -m 3072 -smp 2 \
  -drive file=/opt/winlab/vms/<vm>.qcow2,if=virtio \
  -netdev user,id=n1,hostfwd=tcp:127.0.0.1:<port>-:22 \
  -device virtio-net-pci,netdev=n1 \
  -vnc 127.0.0.1:<display> \
  -monitor unix:/tmp/<vm>-mon.sock,server,nowait \
  -display none
```

## 5. Windows 基线（多数复现目标的宿敌机）

- 安装 Windows 10 Pro 22H2（或报告要求的版本），创建管理员与标准用户两个账号；
- `bcdedit /set testsigning off`，重启确认无水印（母盘别带 Test Mode）；
- UAC 默认、Defender 实时保护开启（除非报告前提明确要求关闭）；
- 开启 OpenSSH Server；配置 AutoAdminLogon（录屏用，见 references/recording.md）；
- `powercfg` 关闭息屏/睡眠；关闭/推迟 Windows Update（防录制中重启）；
- 装好后打快照 `baseline`，母盘就此冻结。

Linux 靶机基线：最小安装、报告要求的内核/组件版本、SSH 可达、串口日志落盘、可快照回滚。

## 6. 资源预算

| 档位 | 配置 | 用途 |
|---|---|---|
| S | 1 vCPU / 2 GB | 单发复验、录屏 |
| M | 2 vCPU / 3 GB | 常规复现（默认） |
| L | 4 vCPU / 5 GB | 并发/压力类复现 |

预算：`<总内存> − 已分配 VM − 宿主 3G − 8G×agent 会话数`（lab-up.sh 动态读取 /proc/meminfo）；超限降档。每 VM cgroup `MemoryMax=1.3×mem`、`CPUQuota=(vcpu+1)×100%`。禁止全局 `pkill qemu`。SSH/VNC 只绑 127.0.0.1。启动设备用 ide-hd+e1000（Windows 客箱免装驱动）。VNC display 号由 lab-up 动态分配。

## 7. 常见问题

- VNC 字符注入不可靠 → 用简单密码/文件名，先截图核对再回车；
- SSH 会话是 session 0，GUI 不可见 → `schtasks /IT` 或控制台 VNC；
- 母盘带 Test Mode → 录制前必须关闭并重启验证；
- conda 的 ffmpeg 可能无 libx264 → 用系统 `/usr/bin/ffmpeg`；
- Windows Update 弹窗 → 提前推迟/关闭。
