# vuln-repro：漏洞复现技能包

版本：2026-10-20（v1.0.0）
形态：单技能 Agent Skill（`vuln-repro/SKILL.md` + `references/` + `scripts/` + `assets/`），遵循 Agent Skills 开放标准（agentskills.io），兼容 Claude Code 及其他支持该标准的 agent。**完全自包含，不依赖其他技能包。**

## 用途

输入一份第三方漏洞报告（含可选 PoC），在隔离的 KVM 靶机里按报告原样复现，产出：

```text
<目标> <漏洞类型> 复现报告.docx    # 环境、步骤、判定、N/M 统计、与原报告差异、完整 PoC、证据
<目标> <漏洞类型> 复现视频.mp4    # 1920×1080 H.264，一键自动录制（判死续录/heartbeat），失败不剪
```

复现失败（`failed`）是合法结论，同样产出报告与视频。不做漏洞挖掘、不重写漏洞分析、不做平台报送。

## 安装

```bash
cp -r vuln-repro ~/.claude/skills/          # Claude Code
# 或放入 .agents/skills/、.zcode/skills/ 等你 agent 的技能目录
```

安装后首次使用先自检（新机从零搭建按 `vuln-repro/references/host-setup.md`）：

```bash
~/.claude/skills/vuln-repro/scripts/lab-check.sh
```

## 流程（SKILL.md 详版）

```text
输入报告 → repro-info.yaml 登记
  → ① 环境自检/搭靶机（lab-check/lab-up/快照）
  → ② 复现执行：五道闸门（环境→部署→执行→判定→确定性 N/M），失败走差异排查分支
  → ③ 证据落盘 evidence/ + manifest + verdict.yaml（reproduced/partial/failed）
  → ④ 复现报告 DOCX（append-poc → make_docx → check-docx）
  → ⑤ 复现视频 MP4（auto-repro.sh 一键 / 手动 record+encode，check-mp4 校验）
```

## 依赖

Linux x86_64 宿主：KVM/QEMU、qemu-img、OpenSSH、sshpass、vncsnapshot、vncdo、ffmpeg（libx264）、python3 + python-docx + Pillow；可选 systemd-run（VM cgroup 限制）。靶机：Windows 10/11 或 Linux（按报告前提）。

环境变量：`LAB_BASE_IMAGE`、`LAB_VM_DIR`、`LAB_SSH_PASSWORD`（靶机密码，勿写进文件）、`LAB_AGENT_PROC`（agent 进程名，默认 claude）、`LAB_EXTRA_IMAGES`、`LAB_ASSUME_YES`（全表见 `vuln-repro/references/resource-discipline.md`）。

## 脚本清单（17 个，全部可从任意 CWD 调用）

| 脚本 | 用途 |
|---|---|
| `lab-check.sh` | 宿主能力矩阵/缺失依赖 |
| `lab-up.sh` | 预算感知创建/启动 VM（overlay、cgroup、SSH/VNC 仅绑 127.0.0.1；`--dry-run`） |
| `lab-wait.sh` | 等 SSH 端口，可选验证登录 |
| `lab-snapshot.sh` | 快照（运行中 savevm 60s 超时 + 校验 / 停机 qemu-img） |
| `lab-reset.sh` | 回滚快照（需 --yes）——确定性复现的回滚点 |
| `lab-ls.sh` | 列出 VM/状态/端口/资源 |
| `lab-down.sh` | 精确停止指定 VM（--rm 只删 VMDIR 内 overlay） |
| `qemu-monitor.py` | QEMU monitor 命令（system_reset/info status 等） |
| `health-check.sh` | 长会话每 30 分钟资源自检 |
| `build-manifest.py` | evidence/ → manifest.json（id 路径加盐；复核后 `--verified`） |
| `append-poc.py` | 完整 PoC 追加为报告附录（按"附录 X"查重） |
| `make_docx.py` | Markdown → A4 DOCX（图片映射/JPEG 规范化/列表编号保留） |
| `check-docx.py` | DOCX 自检（--require/--forbid/图片数/字符数） |
| `auto-repro.sh` | **一键自动复现+录制**（crash/hang 两模式、判死续录、heartbeat、时间戳合成） |
| `record-vnc.sh` | VNC 帧采集（--duration 必填，打印实测帧率） |
| `encode-frames.sh` | 帧 → 1920×1080 H.264 MP4（--timestamp 烧时钟） |
| `check-mp4.sh` | MP4 规格校验 |

## 目录

```text
vuln-repro/
├── README.md
└── vuln-repro/
    ├── SKILL.md                  # 全流程（输入契约→环境→复现→报告→视频→交付）
    ├── references/
    │   ├── host-setup.md         # 新机搭建（依赖/KVM/母盘/基线/预算）
    │   ├── evidence.md           # oracle 配方、manifest、verdict
    │   ├── report-format.md      # 复现报告骨架、文风、DOCX 命令
    │   ├── recording.md          # 录制原理、一次性环境、分镜、实测坑
    │   └── resource-discipline.md# 资源纪律精简版 + 环境变量表
    ├── scripts/                  # 17 个脚本（见上表）
    └── assets/
        ├── go.cmd.template       # guest 内分镜模板（schtasks /IT 可见执行）
        └── lab.yaml.example      # 档位/基线参数人读示例
```

## 已验证出身

脚本与流程来自一套经过实战检验的漏洞研究流水线（Windows 驱动战役：崩溃型 965 帧蓝屏全程自动出片；挂死型外部 heartbeat 取证；自包含 DOCX 报告），本包为其"复现 + 报告 + 录制"子集的独立重组，剔除挖掘/报送等无关功能。
