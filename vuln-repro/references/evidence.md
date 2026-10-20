# 证据与判定（oracle 配方、manifest、verdict）

> 复现的产出是"可复核的事实链"：观测 → 落盘 → 清单 → 结论。任何不确定的结论，要么补实验，要么写进 open_questions。

## 1. 五类 oracle 配方（按 vuln_type 对号）

| 类型 | 观测什么 | 必记 |
|---|---|---|
| 崩溃 | BugCheck/panic、事件 1001 四参、dump | 错误码原文、dump 大小与 SHA-256、N/N 复现统计 |
| 挂死/DoS | **外部主机** heartbeat（SSH/ICMP）超时与恢复、CPU 占用、服务状态 | 超时区间、恢复时间、无崩溃转储、服务状态、未重启证明 |
| 信息泄露 | 输出缓冲前后对比、泄露内容边界 | 前后 dump、变化偏移、泄露内容边界（多少字节、是什么） |
| 访问控制/未授权/弱口令 | 无凭据/低权限操作成功 | 身份证明（whoami/组）、请求与响应原文、成功判定依据 |
| 功能效果（逻辑/上传/注入等） | 报告宣称的业务效果 | 触发前后对照（未触发时同样操作无效的阴性对照）、截图/日志原文 |

通用纪律：

- 挂死类**必须**用宿主侧外部 heartbeat，不能只看 guest 内自测；
- 阴性证据与阳性同样重要：不触发时的对照、恢复性、影响边界（不要夸大）；
- 每步先写日志再继续；时间戳全程对齐（宿主与 guest 时钟差记录一次）。

## 2. 证据目录与 manifest

```text
evidence/
├── manifest.json          # 证据清单
├── env/                   # 版本指纹、安装来源、哈希
├── runs/                  # 每轮触发的控制台日志、时间戳
├── oracle/                # heartbeat 日志、事件导出、dump 清单
└── shots/                 # 截图
```

```bash
# 先生成清单（verified=false）
python3 scripts/build-manifest.py --dir evidence --out evidence/manifest.json
# 复核每条证据真实、与结论一致后，再全量标记
python3 scripts/build-manifest.py --dir evidence --out evidence/manifest.json --verified
```

字段：`id/type/description/path/sha256/bytes/timestamp/source/verified`。`--verified` 是全量置位：复核通过前不要加；需要逐条标注时复核后手工编辑 manifest（编辑后的文件即归档版，勿重跑覆盖）。报告与视频只引用 `verified=true` 的条目。

## 3. verdict.yaml（结论落盘，工作目录根）

```yaml
verdict: reproduced | partial | failed
acceptance_met: <对照 acceptance 的现象原文>
runs: {attempts: N, successes: M}
differences: <与原报告宣称的差异清单；无则空>
evidence: [<manifest ids>]
open_questions: [...]
```

- `reproduced`：五道闸门全过，acceptance 现象按统计复现；
- `partial`：现象出现但不稳定/不完整/仅在附加条件下成立——**必须**写明附加条件；
- `failed`：按报告与合理补全均未复现——保留全部排查记录，这正是复现报告的价值。
