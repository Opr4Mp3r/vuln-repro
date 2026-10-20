---
name: vuln-repro
description: 接收第三方漏洞报告并在隔离实验环境中复现：搭建 KVM 靶机、按报告/PoC 原样触发、采集证据，产出复现报告 DOCX 与复现视频 MP4。当用户提供漏洞报告/CVE/安全公告并要求复现、验证复现、写复现报告或录制复现视频时使用。
compatibility: 要求 Linux x86_64 宿主（KVM、/proc、GNU coreutils）；依赖 qemu-system-x86_64/qemu-img、ssh/sshpass、vncsnapshot/vncdo、ffmpeg(libx264)、python3 + python-docx + Pillow；可选 systemd-run（VM cgroup 限制）。本技能完全自包含，不依赖其他技能。
metadata:
  version: "1.1.0"
---

# 漏洞复现工厂（vuln-repro）

目标：输入一份别人写的漏洞报告，输出可复核的复现事实——**一份复现报告 DOCX + 一条复现视频 MP4**。原始报告已经写了漏洞分析；本技能不重新分析、不挖掘、不报送，只验证"这个洞在这套环境里能不能按报告说的复现"并留全程证据。

红线（每次必读）：

- 只在 KVM 隔离靶机里复现；宿主禁止加载内核模块、禁止运行 PoC；
- PoC 按原样触发验证，不改进、不扩展、不武器化；
- **复现失败是合法结论**：如实写"未能复现"与排查过程，不硬凑现象；
- 证据先落盘再继续，每步日志 flush；一次实验只改一个变量。

## 0. 输入契约

最小输入 = 一份漏洞报告（md/pdf/txt/链接均可）+ 可选 PoC 附件。开工前把关键信息登记进 `repro-info.yaml`（本次复现的唯一真相源，放在工作目录根）：

```yaml
id: <slug>
source_report: <报告路径或 URL>
cve: <编号，可空>
target:
  product: <产品>
  version: <版本>
  component: <受影响组件，可空>
  sha256: <安装包/组件哈希，可空>
claim:                        # —— 以下全部从原报告提取 ——
  vuln_type: <报告宣称的类型（注入/泄露/DoS/未授权/弱口令/…）>
  preconditions: <OS/版本/配置前提>
  privileges: <宣称所需权限；若宣称低权限，复现必须以标准用户执行并证明>
  expected: <报告宣称的现象（判定标准的原始表述）>
poc: <PoC 路径；没有则写 "无：按报告步骤手工复现">
env:
  guest: windows10 | linux
  tier: S | M | L             # S=单发复验/录屏，M=默认，L=并发/高频
acceptance: <什么观测结果算复现成功——从报告提取；含糊就自行明确并记录在此>
```

报告缺关键信息（精确版本/PoC/前提）先尝试从来源补齐；补不齐就把假设显式写进 `acceptance`，复现报告里注明。

## 1. 环境搭建（先自检，缺能力就停）

```bash
scripts/lab-check.sh --json                 # 必选项缺失退出码 2，先补齐
scripts/lab-up.sh --name <vm> --tier M      # 端口/VNC 动态分配，只绑 127.0.0.1
scripts/lab-wait.sh --name <vm> --port <lab-up 输出的端口> --ssh-user <user>
scripts/lab-snapshot.sh --name <vm> --tag clean   # 每轮复现的回滚点
```

- 新机从零搭建（依赖包、KVM、母盘、Windows/Linux 基线）按 `references/host-setup.md` 逐步做；
- 凭据从 `LAB_SSH_PASSWORD` 读，不写进任何文件；`assets/lab.yaml.example` 是档位/基线参数的人读示例（脚本不解析，实际配置用环境变量+参数）；
- 预算闸门被裁决（降档/拒绝）就接受；禁止手改 qemu 参数绕过、**禁止全局 pkill qemu**（只准 `scripts/lab-down.sh --name <vm>`）；资源纪律精简版见 `references/resource-discipline.md`（长会话每 30 分钟 `scripts/health-check.sh`）。

## 2. 复现执行（五道闸门，顺序执行）

1. **环境闸门**：靶机为 `clean` 快照；采集版本指纹（OS 构建号、产品/组件版本与 SHA-256）落盘，与 `claim.preconditions` 核对；
2. **部署闸门（保真度分级）**：按报告步骤部署目标，不要"更聪明"地改变部署。两级：
   - **LAB 级**（手工拷组件/手工建服务）：仅用于初步复现与差异排查，结论在报告中标 `lab-deployed`；
   - **PRODUCT 级**（完整官方安装，组件经产品真实分发路径就位——安装器直装，或客户端"按需下发"真实触发）：**最终复现报告与视频必须基于 PRODUCT 级**。若报告前提是"安装了该产品的正常机器"，LAB 级结果只算初步证据——须在 PRODUCT 级重跑判定与 N/M 后才能写 `reproduced`，否则写 `partial` 并把部署差异写进 verdict.differences；
3. **执行闸门**：按报告/PoC **原样**触发；控制台输出、时间戳、截图逐项落盘；
4. **判定闸门**：对照 `acceptance` 判定；观测配方按漏洞类型见 `references/evidence.md`（崩溃/挂死/信息泄露/访问控制/功能效果五类 oracle 与取证要求）；
5. **确定性闸门**：`lab-reset.sh --name <vm> --tag clean --yes` 回滚后重复执行——崩溃类 ≥5 次，其余 ≥3 次，记录 N/M 与时间；一次成功不算结论。

**分支**：

- 成功 → 补采阴性/边界证据（不触发时的对照、恢复性、影响边界）→ 进 §3/§4；
- 现象不符 → 差异排查（目标版本、OS/补丁、配置前提、报告步骤歧义），每轮只改一个变量，最多 2 轮，每轮差异记录落盘；仍未复现 → 按失败结论出报告；
- 报告步骤本身写错/缺步骤 → 在复现报告中如实标注歧义点与你的合理补全，不替原作者圆场。

**证据与结论落盘**：每步先写日志再继续；证据目录与 manifest 生成、复核后标记 verified 的流程见 `references/evidence.md`。最终结论写 `verdict.yaml`（工作目录根）：

```yaml
verdict: reproduced | partial | failed
acceptance_met: <对照 acceptance 的原文现象>
runs: {attempts: N, successes: M}
differences: <与原报告宣称的差异清单，无则空>
evidence: [<manifest ids>]
open_questions: [...]
```

## 3. 复现报告 DOCX

骨架、文风与生成命令见 `references/report-format.md`。要点：审稿人只看这一份 DOCX 就能知道"什么报告、什么环境、怎么复现、结果如何、与原宣称差异在哪"。完整 PoC/复现脚本放附录 A（`scripts/append-poc.py` 自动追加）；生成后 `scripts/check-docx.py` 自检。命名：`<目标> <漏洞类型> 复现报告.docx`。

## 4. 复现视频 MP4

一键录制（崩溃型：判死续录；挂死型：全程+外部 heartbeat）：

```bash
scripts/auto-repro.sh --display 127.0.0.1:<d> --ssh-port <p> --ssh-user <u> \
  --go-cmd '<guest 内分镜脚本>' --out "<目标> <漏洞类型> 复现视频.mp4" \
  --mode crash|hang [--vm-disk <盘路径>] [--heartbeat] [--duration 240]
```

分镜模板 `assets/go.cmd.template`；录制原理、guest 一次性环境（AutoAdminLogon/防息屏/关 WinRE）与实测坑见 `references/recording.md`。纪律：**最终视频基于 PRODUCT 级部署**（LAB 级手工组件快照不得用于最终视频，先完整重装重验再录）；片中证明**复现环境与报告前提一致**（版本指纹入镜；报告宣称低权限则标准用户 `whoami` 入镜）；真实屏幕、失败不剪、不摆拍。规格校验 `scripts/check-mp4.sh`。文件名与 DOCX 同名（扩展名不同）。

## 5. 交付物与收尾

```text
<工作目录>/
├── repro-info.yaml  verdict.yaml  evidence/{manifest.json,...}
├── <目标> <漏洞类型> 复现报告.docx
└── <目标> <漏洞类型> 复现视频.mp4
```

自检：

- [ ] DOCX 单独可读：环境指纹、逐步骤命令与输出、判定标准、N/M 统计、差异说明、完整 PoC、证据原文（非"见 evidence/"）；
- [ ] 视频与报告同一套事实、同一命名；失败过程未剪掉；
- [ ] `verdict` 与证据一致（`partial` 不得写成 `reproduced`）；
- [ ] 快照已回滚、VM 已收尾（`scripts/lab-ls.sh` 确认无残留），证据已归档。
