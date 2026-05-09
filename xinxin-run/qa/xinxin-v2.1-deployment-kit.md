# Xinxin v2.1 Deployment Kit

目标：把当前 `xinxin` IP 增强直接转化为可重复执行的交付动作。

## A. 预执行检查（开始前）
- 切到项目根：`D:\pet`
- 确认 `xinxin-run` 中已处于编辑后的 v2.1 资产
- 备份当前 outputs（用于回退）
  - `decoded\`
  - `frames\`
  - `final\`

## B. 执行顺序（推荐）
1) P0 阶段
- `prompts\base-pet.md` 无需改动时，先重跑 `idle`
- 复核通过后继续

2) P1 阶段
- 依次重跑：
  - `waiting`
  - `running`
  - `review`
  - `waving`

3) P2 阶段
- 依次重跑：
  - `jumping`
  - `running-right`
  - `running-left`
  - `failed`

## C. 三阶段增强清单（按周期开启）

### 阶段 1：可交付基线（Base）
- 完成 P0/P1/P2 全流程重跑与逐状态复核。
- 生成最新 `qa/run-log-YYYYMMDD-HHMM.md` 与 `qa/run-log-YYYYMMDD-HHMMSS-summary.json`。
- 输出 `qa/run-log-template.md` 变更项并与 `qa/run-audit` 产物一致。
- 建议本地执行：`.\scripts\run-xinxin-v2.1-release-line.ps1 -Line baseline`

### 阶段 2：流程门禁（Gate）
- 运行发布前一键：
  - `scripts\run-xinxin-v2.1.ps1 -Mode all -ReviewRunLog -RequireReleaseGate`
- 确认 `run-xinxin-v2.1.ps1` 输出：
  - `qa/release-gate.json`
  - `qa/run-log-*.md`
  - `qa/run-log-*-summary.json`
- 门禁失败则回到阶段 1 修复并补跑相关 state。

### 阶段 3：发布闭环（Release）
- 触发 CI 阶段，固定产物名入库并关联 release 事件记录：
  - `xinxin-v2.1-release-gate.yml` 或 `xinxin-v2.1-release-check.yml`
  - `xinxin-v2.1-on-release-gate.yml`（release 已发布时自动阻断）
- 如果需要一条命令覆盖本地验证与门禁产出，执行：
  - `.\scripts\run-xinxin-v2.1-release-line.ps1 -Line gate`
- 在 `qa/xinxin-v2.1-release-summary.md` 追加该轮结论与人工复核签名。

## D. 结果同步（每个 state）
- 更新 `qa/v2.1-qa-checklist.md` 的检查项
- 若 FAIL，立刻执行 [qa/v2.1-failure-remediation-playbook.md](qa/v2.1-failure-remediation-playbook.md)
- 修复后只重跑该 state
- 全通过后再继续下一 state

## E. 复训完成后的文件收口
- 更新 `decoded/` 与 `frames/`
- 重建 `final/`
- 输出/更新运行记录：
  - 新建 `qa/run-log-YYYYMMDD-HHMM.md`
  - 同步生成 `qa/run-log-YYYYMMDD-HHMMSS-summary.json`
  - 填写结果并附时间戳
- 在 [qa/xinxin-v2.1-ops-index.md](qa/xinxin-v2.1-ops-index.md) 补充新 run log 链接

## F. 发布前门禁
- 执行自动化门禁：
  - `powershell -ExecutionPolicy Bypass -File scripts\check-v2.1-release-gate.ps1 -RunDir .\xinxin-run`
- 阻断式门禁（CI/发布前建议）：
  - `powershell -ExecutionPolicy Bypass -File scripts\check-v2.1-release-gate.ps1 -RunDir .\xinxin-run -RequirePass`
- 发布前一键（先执行门禁、再落 run-log 与 summary，可提供门禁产物名）：
  - `powershell -ExecutionPolicy Bypass -File scripts\run-xinxin-v2.1.ps1 -Mode all -RunDir .\xinxin-run -ReviewRunLog -ReleaseGateOutputFile .\xinxin-run\qa\release-gate.json -RunLogOutputFile .\xinxin-run\qa\run-log-release-candidate.md -RunLogSummaryFile .\xinxin-run\qa\run-log-release-candidate-summary.json`
- 人工复核补齐：
  - 先用 `set-v2.1-manual-review.ps1` 入库每个 state 的 PASS/FAIL
  - 再复跑 `generate-v2.1-run-log.ps1` 生成含快照的 run-log

## G. 不可变更边界（高优先级）
- 不改：
  - 身份核心特征（发型、脸型、服饰骨架）
  - 画面结构（单行横向帧条）
  - 纯色 chroma key `#00FFFF`
- 不添加：
  - 文本、UI、logo、符号
  - 光效、阴影、渐变、模糊
  - detach 式粒子/漂浮元素

## H. 结果定义
- `PASS`：所有 state 满足 v2.1 检查清单，且 `manual_review.status` 为 `PASS`，并通过发布门禁
- `RE-TRY`：任一 P0/P1 状态失败未在 1 次修复后解决

## I. 输出清单（交付前核对）
- [x] `qa/v2.1-qa-checklist.md`
- [x] `qa/v2.1-failure-remediation-playbook.md`
- [x] `qa/v2.1-fast-track-playbook.md`
- [x] `qa/run-log-template.md`
- [x] 最新 `run-log-YYYYMMDD-HHMM.md`
- [ ] final spritesheet/validation 更新
- [ ] `qa/xinxin-v2.1-release-summary.md` 复盘结果更新

## J. 发布一键口径（新增）
- 推荐 CI 命令：
  - `powershell -ExecutionPolicy Bypass -File scripts\run-xinxin-v2.1.ps1 -Mode all -RunDir .\xinxin-run -RequireReleaseGate -RunLogOutputFile .\xinxin-run\qa\run-log-release-candidate.md -RunLogSummaryFile .\xinxin-run\qa\run-log-release-candidate-summary.json`
- 若门禁失败，命令直接失败并返回错误，作为自动发布阻断条件。
- 若需统一 CI 产物名，可直接触发：
  - `.github\workflows\xinxin-v2.1-release-check.yml`
- 更标准的两阶段线：
  - 先跑干跑：`.github\workflows\xinxin-v2.1-dry-run.yml`
  - 再跑发布闸：`.github\workflows\xinxin-v2.1-release-gate.yml`
