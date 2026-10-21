# vuln-repro：漏洞复现技能包

版本：2026-10-21（v1.1）
形态：单技能 Agent Skill（`vuln-repro/SKILL.md` + `references/` + `scripts/` + `assets/`），遵循 Agent Skills 开放标准（agentskills.io），兼容 Claude Code 及其他支持该标准的 agent。**完全自包含，不依赖其他技能包。**

## 用途

输入一份第三方漏洞报告（含可选 PoC），在隔离的 KVM 靶机里按报告原样复现，产出：

```text
<目标> <漏洞类型> 复现报告.docx    # 环境、步骤、判定、N/M 统计、与原报告差异、完整 PoC、证据
<目标> <漏洞类型> 复现视频.mp4    # 1920×1080 H.264，一键自动录制（判死续录/heartbeat），失败不剪
```

复现失败（`failed`）是合法结论，同样产出报告与视频。不做漏洞挖掘、不重写漏洞分析、不做平台报送。

## 系统架构（三层）

一句话：**环境层搭一个安全、可回滚、可观测的舞台；agent 负责读、判断、成文；脚本负责执行、度量、校验**——agent 不重写确定性动作，脚本不替 agent 做判断。

```text
第三方漏洞报告 ──agent──> repro-info.yaml（复现契约：目标/前提/判定标准）
        │                      │
        ▼                      ▼
   环境层：隔离靶机  <──脚本──>  agent：五道闸门裁定 + 差异排查
   （快照回滚/受控端口/资源限额）      │
        │                            ▼
        └──── 脚本：录制/插卡/合成/文档/校验 ──> 复现报告.docx + 复现视频.mp4
```

**① 实验环境层（Linux 宿主 + KVM/QEMU，把"环境"变成受控资产）**

- 隔离与可回滚：Windows/Linux 基线母盘 + 每次复现独立 qcow2 overlay，快照随时回滚——确定性复测（N/M 统计）的物理前提；
- 受控连通：SSH hostfwd 与 VNC 只绑 127.0.0.1、端口动态分配，带洞靶机不暴露到网络；
- 资源治理：预算闸门 + 每 VM cgroup 限额（内存/CPU），复现失控（驱动挂死、内存炸弹）拖不垮宿主；
- 宿主侧观测位：VNC 帧流在 guest 崩溃后仍可持续拍摄；外部 heartbeat 独立判活；QEMU monitor 可复位/快照；
- 产物工具链：ffmpeg(libx264)、vncsnapshot、python-docx + Pillow——视频与文档的生成原料。

**② Agent 层（语义判断：读 → 判断 → 写）**

- **读**：解析任意格式的第三方报告，提取并补全复现契约 `repro-info.yaml`（目标指纹、宣称前提、验收标准 acceptance——"什么算复现成功"先定义清楚再动手）；
- **判断**：环境选型（靶机类型/档位）、部署保真度分级（LAB 级仅限初步复现，最终交付必须 PRODUCT 级）、五道闸门逐关裁定（环境→部署→执行→判定→确定性）、异常解释与差异排查（版本/前提/步骤歧义，单变量最多两轮）、`reproduced / partial / failed` 终审；
- **写**：复现报告叙事（步骤、与原报告差异、结论）、guest 内分镜脚本 go.cmd（STEP-N-<身份> 窗口、`=== 分段 ===` 指纹、产品 GUI 强制出镜）、cards.json 说明卡内容（结果卡数据取自实测事件日志，不得预写）；
- 纪律执行：失败轮次不剪、阴性证据同等留档、复现失败是合法产出。

**③ 辅助脚本层（确定性动作：零自由度、显式报错、任意 CWD 可调）**

| 环节 | 脚本 | 提供的能力 |
|---|---|---|
| 环境生命周期（9） | lab-check / lab-up / lab-wait / lab-snapshot / lab-reset / lab-ls / lab-down / qemu-monitor / health-check | 能力自检；预算感知建 VM；等端口；快照（校验真正落盘）；回滚；巡检；精确停机；monitor 命令；长会话资源自检 |
| 证据链（1） | build-manifest | evidence/ → manifest.json（路径加盐 id、SHA-256、复核后 verified 标记） |
| 复现报告 DOCX（3） | append-poc / make_docx / check-docx | 完整 PoC 附录（防重复追加）；Markdown→A4 排版（图片映射/列表编号保留）；require/forbid 内容自检 |
| 复现视频 MP4（5） | auto-repro / record-vnc / make-cards / encode-frames / check-mp4 | 一键录制（可见触发+判死续录+heartbeat）；帧采集（打印实测帧率）；文字卡/BSOD 结果卡渲染；插卡合成（黑边对齐+时间戳烧录）；规格校验 |

## 快速开始（两步，全部交给 agent）

1. **配置技能**：把 `vuln-repro/` 技能目录交给你的 agent——放进其技能目录即可（Claude Code：`~/.claude/skills/`；其他兼容 Agent Skills 的 agent：`.agents/skills/`、`.zcode/skills/` 等），也可以直接让 agent 自行完成安装。
2. **执行环境配置**：对 agent 说"配置漏洞复现环境"。agent 会自动完成全部准备：运行能力自检（`scripts/lab-check.sh`）、按 `references/host-setup.md` 补装缺失依赖、配置 KVM、构建 Windows/Linux 基线母盘并打快照；缺能力时明确报告缺什么、怎么装，不猜也不跳过。

准备完成后即可日常使用：把漏洞报告（可选附 PoC）交给 agent，说"复现这份报告"，即产出复现报告 DOCX + 复现视频 MP4。

## 流程（SKILL.md 详版）

```text
输入报告 → repro-info.yaml 登记
  → ① 环境自检/搭靶机（lab-check/lab-up/快照）
  → ② 复现执行：五道闸门（环境→部署→执行→判定→确定性 N/M），失败走差异排查分支
  → ③ 证据落盘 evidence/ + manifest + verdict.yaml（reproduced/partial/failed）
  → ④ 复现报告 DOCX（append-poc → make_docx → check-docx）
  → ⑤ 复现视频 MP4（auto-repro.sh 一键 / 手动 record+encode，check-mp4 校验）
```

## 脚本清单（18 个，全部可从任意 CWD 调用）

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
| `auto-repro.sh` | **一键自动复现+录制**（crash/hang 两模式、判死续录、heartbeat、`--cards` 插卡、`--no-encode`） |
| `record-vnc.sh` | VNC 帧采集（默认 5fps/quality 82，打印实测帧率） |
| `make-cards.py` | 片头/说明/结果卡渲染（文字卡 + BSOD 样式结果卡，输出 placement.tsv；结果卡数据须来自实测事件日志） |
| `encode-frames.sh` | 帧 → 1920×1080 H.264 MP4（`--cards` 插卡拼接、等比缩放加黑边、`--timestamp` 烧时钟） |
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
    ├── scripts/                  # 18 个脚本（见上表）
    └── assets/
        ├── go.cmd.template       # guest 内分镜模板（schtasks /IT 可见执行）
        └── lab.yaml.example      # 档位/基线参数人读示例
```
