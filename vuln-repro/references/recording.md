# 复现视频：录制实现与分镜

> 配套脚本：`scripts/auto-repro.sh`（一键：录制→可见触发→判死→续录→合成）、`scripts/record-vnc.sh` + `scripts/encode-frames.sh`（手动分步）；分镜模板 `assets/go.cmd.template`。目标：观众不用读报告也能看懂"什么环境、按什么步骤、触发了什么、结果如何"。

## 1. 录制原理（为什么这样做）

- **录制器在宿主侧**：`vncsnapshot -allowblank` 循环抓 VNC（约 0.2–0.4 s/帧）。guest 崩溃/蓝屏后宿主仍在拍——崩溃过程全程入镜的关键；
- **可见触发免按键注入**：把复现分镜写成 guest 内 `go.cmd`，用 `schtasks /create /tr "cmd /c c:\p\go.cmd" /sc once /it /f` + `/run` 以交互式任务在已解锁控制台弹**可见 cmd 窗口**执行。不要用 vncdo/裸 RFB 注入按键——不可靠（连接被掐断/锁屏吞键，实测）；
- **判死（崩溃型）**：hostfwd 的 SSH 端口断连 = guest 死；用 qemu 进程数区分"真死"（进程还在）与"VM 被杀"（进程没了）；
- **合成**：`encode-frames.sh --timestamp` 烧入 pts 时钟；`-framerate` 用**实测帧率**（总帧数 ÷ 墙钟秒数，record-vnc.sh 与 auto-repro.sh 都会打印），否则回放速度漂移。

## 2. guest 一次性环境（每新快照重做）

1. AutoAdminLogon=1 + DefaultUserName/DefaultPassword（崩溃重启自动回桌面，否则录到登录页全黑）；
2. `powercfg /change monitor-timeout-ac 0` 防息屏全黑；
3. `bcdedit /set recoveryenabled no`（连续蓝屏会触发 WinRE 打断录制）；
4. go.cmd 与 PoC 预置（路径无空格无特殊字符）；录制前确认无系统弹窗、无 Test Mode 水印。

## 3. 通用分镜结构

```text
片头卡（6 s）：目标/版本/来源报告（CVE 或标题）/复现环境/日期
Step 1 卡 → 屏幕：环境与版本指纹（winver/ver、产品/组件版本与哈希）
Step 2 卡 → 屏幕：目标部署来源（安装包哈希、服务/进程状态）；
            若报告宣称低权限 → 标准用户 whoami + 权限组证明入镜
Step 3 卡 → 屏幕：按报告步骤触发（控制台打印 === Step N ... ===，静音可读）
Step 4 卡 → 屏幕：结果与判定（oracle 现象、恢复/对照）
片尾卡（6 s）：verdict、N/M 统计、与报告的差异一句话
```

按漏洞类型补证：

- **崩溃型**：蓝屏/崩溃全程、错误码特写、重启后事件/dump 检查入镜；
- **挂死/DoS 型**：外部 heartbeat 终端（TIMEOUT 序列）与目标机同框；恢复后"无崩溃转储、未重启"检查入镜；
- **功能效果型**（未授权/弱口令/逻辑等）：触发前阴性对照（正常路径做不到）→ 触发后效果，先后入镜；
- **信息泄露型**：泄露内容特写与边界（多少字节、是什么）。

纪律：真实屏幕、不摆拍、**失败轮次不剪掉**（片尾一句话说明该轮结果）；长等待可加速播放但保留系统时钟连续性。

## 4. 一键用法

```bash
# 崩溃型：触发 → 等 SSH 断（判死）→ 续录 150 s 覆盖崩溃+重启
scripts/auto-repro.sh \
  --display 127.0.0.1:<d> --ssh-port <p> --ssh-user <user> \
  --go-cmd 'c:\p\go.cmd' --out repro.mp4 --mode crash \
  --vm-disk /opt/winlab/vms/<vm>.qcow2

# 挂死/效果型：录全程 + 外部 heartbeat
scripts/auto-repro.sh ... --mode hang --duration 240 --heartbeat
```

产出：`<out>`（含时间戳）、`frames-<out>/`（原始帧，证据）、`heartbeat-<out>.log`（OK/TIMEOUT 时间线）。

## 5. 实测坑

- schtasks 用 `cmd /c` 不要 `/k`（挂住阻塞下一轮）；下一轮前 `schtasks /end` 清理；
- 崩溃写 dump 可能损坏半写的 dll：崩溃后校验并重拷 PoC 依赖再复用；
- 蓝屏帧判别用"画面均值≈(8,134,222)+低方差"，不要用"蓝色占比"（壁纸假阳性）；
- 并发会话可能杀你的 VM：异常消失先 `scripts/lab-ls.sh` 查；只准 `lab-down.sh --name` 停自己的；
- 名义 fps ≠ 实际 fps（vncsnapshot 单次 5–50 ms 开销）：编码一律用实测值；
- 规格：1920×1080、H.264、20–60 fps、60–600 s（`scripts/check-mp4.sh` 校验；建议 1.5–5 分钟）。
