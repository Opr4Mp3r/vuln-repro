# 复现报告格式与 DOCX 生成

> 复现报告 ≠ 漏洞报告：漏洞分析在原始报告里已有，这里只写"我按它复现了什么、结果如何、差异在哪"。审稿人只看这一份 DOCX 应能独立判断复现是否成立。

## 1. 报告骨架（中文）

```
# <目标产品> <组件> <漏洞类型> 复现报告

## 1. 原始报告与来源
（报告出处/链接/CVE 编号、提交方、宣称的漏洞类型与影响、验收标准的原文表述）
## 2. 复现环境
（宿主与靶机配置、档位、镜像与快照、系统/产品/组件版本指纹与 SHA-256、账号权限；
**部署保真度：PRODUCT 级/LAB 级 + 依据**——完整官方安装记录，或显式标注 lab-deployed）
## 3. 复现步骤
### 3.1 环境准备
### 3.2 目标部署
### 3.3 触发执行
（逐步命令 + 实际输出；与报告步骤不一致处显式标注）
## 4. 结果与判定
（对照 acceptance 的判定；N/M 复现统计；现象截图/日志引用）
## 5. 与原报告的差异
（版本差异、现象差异、步骤歧义与你的补全；无差异也写"无"）
## 6. 证据清单
（引用 manifest id：环境指纹/运行日志/oracle/截图；关键证据原文直接贴正文）
## 7. 结论
（verdict 原文 + 一句话解释 + open_questions）
## 附录 A：PoC/复现脚本完整代码
## 附录 B：排查记录（仅 failed/partial：每轮假设、改动、结果）
```

## 2. 文风（反 AI 腔）

- 用事实和数字："5/5 次触发，平均 38 s 后 SSH 失联"优于"稳定复现"；
- 复现步骤和结果写细，背景和评论写短；
- 不确定的边界用一句话说清；内部标签（verdict 值除外）不进正文；
- 证据是原文粘贴，不是"见 evidence/"。

## 3. DOCX 生成

```bash
# 1) 完整 PoC 追加为附录 A（按"附录 X"标签查重，重复运行不会追加两次）
python3 scripts/append-poc.py --md report.md --poc poc/exploit.ps1 \
  --heading "附录 A：PoC 完整代码（exploit.ps1）" --lang powershell

# 2) Markdown → DOCX（截图先规范化为 JPEG；images.json 把二级标题映射到截图+图注）
python3 scripts/make_docx.py --md report.md \
  --out "<目标> <漏洞类型> 复现报告.docx" \
  --images images.json --shots-dir shots_norm --normalize-images

# 3) 自检（--require 必须存在；--forbid 必须不存在）
python3 scripts/check-docx.py \
  --docx "<目标> <漏洞类型> 复现报告.docx" \
  --require "附录 A" --require "<判定关键词>" \
  --forbid "见附件" --forbid "见 evidence" \
  --min-images 3 --min-chars 3000
```

images.json 示例（键=去掉编号的二级标题；图片插入在该节末尾）：

```json
{
  "复现环境": [["01-version.jpg", "图 1 靶机版本指纹（03:12）"]],
  "结果与判定": [["07-trigger.jpg", "图 2 触发后控制台输出（03:17）"]]
}
```

排版与踩坑：A4、微软雅黑 10.5 pt、代码 Consolas 8.5 pt（生成端无需安装字体，只写字体名）；混合图片格式会报 `UnrecognizedImageError`，一律 `--normalize-images`；表格单元格内不要用竖线字符；行内 `**`/反引号标记会被剥成纯文本（代码块不受影响）；有序列表编号已保留，回归时留意。
