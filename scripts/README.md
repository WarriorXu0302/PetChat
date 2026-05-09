# Pet Pipeline Scripts (xinxin 专线)

本目录是宠物动画流水线脚本集合，默认聚焦 `xinxin-run`。
`kea-run` 仅保留为历史对照，不进入默认执行口径。

## 1. `collect-pet-run-status.ps1`

用途：检查一个 run 目录并生成 `qa/run-status.json`。
- 输入：`-RunDir "C:\...\xinxin-run"`
- 输出：`qa/run-status.json`
- 监控项：
  - `pet_request.json` / `imagegen-jobs.json` 是否存在
  - canonical base 是否存在
  - 每个状态帧数是否达到 `expected/frame-count`
  - 是否存在 `pending`/`failed` job
  - 执行门禁 `gate.ready_for_generation`
- 输出：控制台 + JSON（除非传入 `-NoWrite`）

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\collect-pet-run-status.ps1 -RunDir .\xinxin-run
```

## 2. `run-pet-workflow.ps1`

用途：用于 xinxin 工作流前置检查/目录初始化。
- 输入：`-RunDir .\xinxin-run`（默认值）
- 可选：`-CreateStructure` 自动创建 `decoded`/`frames`/`final`/`qa`/`references`/`prompts` 基础目录
- 可选：`-RequireHealthy` 在有 blocked/degraded 时直接抛错（适合 CI 或自动化触发）

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-pet-workflow.ps1 -RunDir .\xinxin-run -CreateStructure -RequireHealthy
```

## 3. `generate-pipeline-manifest.ps1`

用途：生成当前仓库运行状态汇总。
默认只聚合 `xinxin-run`；如需扫描全部 `*-run`，请使用 `-IncludeAllRuns`。
- 输入：`-RootDir "C:\...\pet"`
- 输出：`pipeline-manifest.json`
- 输出字段：`run_dir/state/issues/warnings/jobs/summary/readiness_score`

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\generate-pipeline-manifest.ps1 -RootDir .\
```

## 4. `build-xinxin-delivery-manifest.ps1`

用途：在可交付前输出交付清单与哈希，便于归档。
- 输入：`-RunDir .\xinxin-run`
- 可选：`-RequireHealthy` 要求 `run` 状态健康后才输出
- 可选：`-OutputFile` 自定义输出位置，默认写入 `qa\delivery-manifest.json`
- 可选：`-NoWrite` 仅返回对象，不落盘
- 可选：`-UpdateLegacySummary` 同步更新 `qa\run-summary.json`

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-xinxin-delivery-manifest.ps1 -RunDir .\xinxin-run -RequireHealthy
```

## 5. `audit-xinxin-v2.1.ps1`

用途：执行统一审计并输出 PASS/FAIL 结果矩阵，落盘 `qa/run-audit-<时间戳>.json`，用于最终 IP 决策。
- 输入：`-RunDir .\xinxin-run`
- 可选：`-NoWrite` 仅返回对象
- 可选：`-OutputFile` 自定义输出路径

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\audit-xinxin-v2.1.ps1 -RunDir .\xinxin-run
```

## 6. `generate-v2.1-run-log.ps1`

用途：基于审计结果自动生成 v2.1 run log（`qa/run-log-YYYYMMDD-HHmmss.md`）。
- 输入：`-RunDir .\xinxin-run`
- 可选：`-AuditFile` 指定某个 `run-audit-*.json`（默认读取最新）
- 可选：`-OutputFile` 指定输出路径
- 可选：`-Executor` 标注执行人

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\generate-v2.1-run-log.ps1 -RunDir .\xinxin-run
```

可选：
- 生成快照文件：`-SummaryFile .\xinxin-run\qa\run-log-YYYYMMDD-HHMMSS-summary.json`

## 7. `set-v2.1-manual-review.ps1`

用途：把“人工逐状态复核”写入最新或指定 `run-audit-*.json`，避免手工改 markdown，并可联动生成新的 run log。

参数：
- `-RunDir .\xinxin-run`
- `-AuditFile`：可选，指定某个审计文件；默认读最新
- `-StateReview`：按 `state:PASS|FAIL|PENDING` 填写（可重复传）
- `-ManualStatus`：可选，覆盖整体验收状态
- `-Reviewer`：复核人（默认系统用户名）
- `-RunLogFile`：可选，若指定则按该文件名生成 run-log（不传则自动生成）

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\set-v2.1-manual-review.ps1 -RunDir .\xinxin-run -StateReview idle:PASS -StateReview waiting:PASS -Reviewer xinxin
```

## 8. `check-v2.1-release-gate.ps1`

用途：一键执行发布门禁：
- 自动审计结果 `overall` 需为 `PASS`
- `manual_review.status` 需为 `PASS`
- `run-status.gate.ready_for_generation` 需为 `true`

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\check-v2.1-release-gate.ps1 -RunDir .\xinxin-run
# 需要严格阻断：不满足条件抛错退出
powershell -ExecutionPolicy Bypass -File .\scripts\check-v2.1-release-gate.ps1 -RunDir .\xinxin-run -RequirePass
```

## 9. `run-xinxin-v2.1.ps1` 增强

命令聚合脚本新增模式：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1.ps1 -Mode all -RunDir .\xinxin-run
```

此命令会顺序执行：
- workflow 检查
- 交付清单打包
- PASS/FAIL 审计
- 自动生成 run log 草稿

可选模式：
- `check`：仅检查 pipeline
- `pack`：仅打包交付清单
- `audit`：检查 + 审计
- `log`：仅基于最新审计生成 run log
- `all`：check + pack + audit + log
- `full`：兼容旧入口，等同于旧版本的全流程路径（建议改用 `all`）

可选参数：
- `-RequireReleaseGate`：在 `-Mode all` 下触发发布门禁，失败抛错阻断（`check-v2.1-release-gate.ps1 -RequirePass`）。
- `-ReviewRunLog`：将发布门禁检查放在 run log 产物生成之前，仍使用 `run-log` 的草稿+快照产物。
- `-ReleaseGateOutputFile`：指定发布门禁 JSON 输出路径（例如 `.\xinxin-run\qa\release-gate.json`）。不传则按时间戳自动落盘。
- `-RunLogOutputFile`：指定 `run-log` Markdown 输出路径（例如 `.\xinxin-run\qa\run-log.md`）。不传则按时间戳自动落盘。
- `-RunLogSummaryFile`：指定 run-log snapshot JSON 输出路径（例如 `.\xinxin-run\qa\run-log-summary.json`）。不传则按时间戳自动落盘。
- `-OutputBundleDir`：为本次执行指定统一产物目录（例如 `.\xinxin-run\qa\release-line-20260509`），未传则自动生成 `.\xinxin-run\qa\release-line-<run_id>` 目录。
- `-RunIdPrefix`：为 run_id 增加统一前缀（例如 `release-candidate`，最终生成 `release-candidate-<run_id>`）。

新增：
- `gate`：执行发布门禁检查（`check-v2.1-release-gate.ps1`）

## 说明

脚本从“检查”升级到“可交付”：可用于发布前门禁与清单归档，而不仅是执行前预检。

## 10. CI 集成

可以使用仓库内置 Workflow 启动发布前自动复检：

```text
.github\workflows\xinxin-v2.1-dry-run.yml
```

触发参数：
- `runlog_name`：固定的 run-log 文件名（默认 `run-log-release-candidate.md`）
- `runlog_summary_name`：固定的 summary 文件名（默认 `run-log-release-candidate-summary.json`）
- `release_gate_name`：固定的发布门禁文件名（默认 `release-gate.json`）

对应场景：
- 干跑/可视化巡检（不中断）：`xinxin-v2.1-dry-run.yml`
- 发布闸门（阻断式）：`xinxin-v2.1-release-gate.yml`
- 兼容一体入口（可选）：`xinxin-v2.1-release-check.yml`（支持 `require_release_gate`）
- 三条 CI 流水线默认都会额外产出 `run-status.json`，并随 artifact 一起打包，便于快速回放与排障。

可用于：
- 统一产物输出名，便于 CI 上传下载
- 在阻断失败时直接让 job 失败，阻断发布

### 触发参数补充（可选）

- `xinxin-v2.1-dry-run.yml`
  - `run_id_prefix`：给 artifact 名称加统一前缀，便于批次归档
  - `retention_days`：artifact 保留天数（默认 30）
  - `run_command_center`（是否运行命令中心诊断，默认 `false`）
  - 仓库变量 `XINXIN_DRY_RUN_RUN_COMMAND_CENTER`（默认 `false`，workflow_dispatch 时 `run_command_center` 为准）
  - 说明：`run_command_center=true` 时，会在主流程失败后继续尝试输出命令中心诊断与回放产物。
- `xinxin-v2.1-release-gate.yml`
  - `run_id_prefix`
  - `retention_days`
  - `run_command_center`（是否运行命令中心诊断，默认 `false`）
- `xinxin-v2.1-on-release-gate.yml`
  - `run_command_center`（workflow_dispatch 时可选，默认 `false`）
  - `retention_days`（workflow_dispatch 时可选，默认 `30`）
  - 仓库变量 `XINXIN_ON_RELEASE_GATE_RUN_COMMAND_CENTER`（默认 `false`，发布事件下生效）
  - 通过仓库变量配置健康闸口：
    - `XINXIN_HEALTH_GATE_FAIL_ON_ATTENTION`（默认 `false`）
    - `XINXIN_HEALTH_GATE_FAIL_ON_CRITICAL`（默认 `true`）
    - `XINXIN_HEALTH_GATE_MIN_HEALTH_SCORE`（默认 `70`）
- `xinxin-v2.1-release-check.yml`
  - `run_id_prefix`
  - `retention_days`
  - `run_command_center`（是否运行命令中心一键诊断，默认 `false`）
  - 仓库变量 `XINXIN_RELEASE_CHECK_RUN_COMMAND_CENTER`（默认 `false`，workflow_dispatch 时 `run_command_center` 为准）
  - 说明：`run_command_center=true` 时，即使主流程失败也会走 `command-center` 诊断，便于快速复盘。
- `xinxin-v2.1-release-line.yml`
  - `run_id_prefix`
  - `run_id`（可覆盖 run id）
  - `retention_days`
  - `run_command_center`（可选，默认 `false`）
  - 仓库变量 `XINXIN_RELEASE_LINE_RUN_COMMAND_CENTER`（默认 `false`，workflow_dispatch 时 `run_command_center` 为准）
  - 说明：`run_command_center=true` 时，`command-center` 在失败链路也会尝试执行。
- `xinxin-v2.1-pr-dry-run.yml`
  - `run_command_center`（workflow_dispatch 时可选，默认 `false`）
  - 仓库变量 `XINXIN_PR_DRY_RUN_RUN_COMMAND_CENTER`（默认 `false`）

仓库变量快速设置（可选）：

```bash
gh variable set XINXIN_PR_DRY_RUN_RUN_COMMAND_CENTER --body false --repo <owner>/<repo>
gh variable set XINXIN_ON_RELEASE_GATE_RUN_COMMAND_CENTER --body false --repo <owner>/<repo>
gh variable set XINXIN_DRY_RUN_RUN_COMMAND_CENTER --body false --repo <owner>/<repo>
gh variable set XINXIN_RELEASE_CHECK_RUN_COMMAND_CENTER --body false --repo <owner>/<repo>
gh variable set XINXIN_RELEASE_LINE_RUN_COMMAND_CENTER --body false --repo <owner>/<repo>
```

启用方式：

```bash
gh variable set XINXIN_PR_DRY_RUN_RUN_COMMAND_CENTER --body true --repo <owner>/<repo>
gh variable set XINXIN_ON_RELEASE_GATE_RUN_COMMAND_CENTER --body true --repo <owner>/<repo>
gh variable set XINXIN_DRY_RUN_RUN_COMMAND_CENTER --body true --repo <owner>/<repo>
gh variable set XINXIN_RELEASE_CHECK_RUN_COMMAND_CENTER --body true --repo <owner>/<repo>
gh variable set XINXIN_RELEASE_LINE_RUN_COMMAND_CENTER --body true --repo <owner>/<repo>
```

### 附加用法：all 模式直接带发布门禁

```powershell
# 一键执行：check -> pack -> audit -> run-log -> release-gate
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1.ps1 -Mode all -RunDir .\xinxin-run -RequireReleaseGate

# 一键执行：review-ready（先 run release-gate，再落 run-log-summary）
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1.ps1 -Mode all -RunDir .\xinxin-run -ReviewRunLog -ReleaseGateOutputFile .\xinxin-run\qa\release-gate.json

# 一键执行：all + 指定 run-log 输出（CI 中固定产物名）
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1.ps1 -Mode all -RunDir .\xinxin-run -ReviewRunLog -RunLogOutputFile .\xinxin-run\qa\run-log-20260509-180000.md -RunLogSummaryFile .\xinxin-run\qa\run-log-20260509-180000-summary.json
```

### 一键发布线（本地）

新增：

- `scripts\run-xinxin-v2.1-release-line.ps1`
- `-Line baseline|gate|all`
- `-NoFail`（失败不中断，产出失败报告）

```powershell
# 基线线（输出 log 与 summary，不阻断）
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1-release-line.ps1 -Line baseline

# 闸门线（检查并阻断）
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1-release-line.ps1 -Line gate

# 全量线（输出报告 + pipeline 状态）
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1-release-line.ps1 -Line all
```

`-RequireReleaseGate` 会在 `all` 模式下触发发布门禁，失败时抛错退出。默认先执行 run-log，再执行门禁；如需先门禁再 run-log，可配合 `-ReviewRunLog`。

## 触发顺序建议

- PR 代码变更：`xinxin-v2.1-pr-dry-run.yml`（自动触发，非阻断）
- 人工复核与问题修复完成后：`xinxin-v2.1-release-gate.yml`（阻断式，建议发布前手动触发）
- `release` 发布事件：`xinxin-v2.1-on-release-gate.yml`（自动触发阻断）
- 需要统一口径一次跑完时：`xinxin-v2.1-release-check.yml`（可选）

### CI 本地线入口（推荐）

- `xinxin-v2.1-release-line.yml`（`workflow_dispatch`，可选 `line=baseline|gate|all`）

```bash
gh workflow run xinxin-v2.1-release-line.yml --field line=baseline
gh workflow run xinxin-v2.1-release-line.yml --field line=gate
gh workflow run xinxin-v2.1-release-line.yml --field line=all
gh workflow run xinxin-v2.1-release-line.yml --field line=all --field run_id_prefix=release-20260509
```

### 推荐下一步命令自动化

`xinxin` 发布线新增：
- `scripts\resolve-xinxin-next-action.ps1`
  - 输入可选：`-ReportPath`、`-ReleaseGatePath`、`-RunStatusPath`、`-RunIdPrefix`、`-MarkdownOutputPath`
  - 输出统一 JSON：`recommended_command`、`recommended_step`、`recommended_reason`
  - 另含输出：`recommended_commands`、`recommended_playbooks`、`recommended_notes`
  - `-MarkdownOutputPath` 可固定写入统一文件名（示例：`next-action-recommendation.md`），便于归档与脚本化提取
- `schema_validation`：包含 `schema_version`、`source`、`valid`、`errors`、`warnings`、`checks`
- `collect-xinxin-next-artifacts.ps1` 额外输出健康快照：`health_status`、`health_score`、`needs_attention`、`health_reasons`
- 新增 `scripts\collect-xinxin-next-artifacts.ps1`，可一键聚合最近一次产物并输出执行摘要 JSON

可用于在 CI 之后快速给出补跑命令：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\resolve-xinxin-next-action.ps1 `
  -ReportPath .\xinxin-run\qa\release-line-report.json `
  -ReleaseGatePath .\xinxin-run\qa\release-gate.json `
  -RunStatusPath .\xinxin-run\qa\run-status.json `
  -RunIdPrefix release-candidate
```

加 `-HumanReadable` 可直接输出可读清单（含推荐 playbook 与推荐命令）：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\resolve-xinxin-next-action.ps1 `
  -ReportPath .\xinxin-run\qa\release-line-report.json `
  -ReleaseGatePath .\xinxin-run\qa\release-gate.json `
  -RunStatusPath .\xinxin-run\qa\run-status.json `
  -RunIdPrefix release-candidate `
  -HumanReadable
```

加 `-MarkdownOutputPath` 可直接导出可复用的 markdown 文档（含清单+命令块）：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\resolve-xinxin-next-action.ps1 `
  -ReportPath .\xinxin-run\qa\release-line-report.json `
  -ReleaseGatePath .\xinxin-run\qa\release-gate.json `
  -RunStatusPath .\xinxin-run\qa\run-status.json `
  -RunIdPrefix release-candidate `
  -MarkdownOutputPath .\xinxin-run\qa\next-action-recommendation.md
```

```powershell
# 聚合最近一次产物并做 schema 健康检查（可读）
# RunDir 可直接指向 xinxin-run 根目录或 release-line 的 bundle 目录（脚本会自动回退到输入目录本身）
powershell -ExecutionPolicy Bypass -File .\scripts\collect-xinxin-next-artifacts.ps1 `
  -RunDir .\xinxin-run `
  -RunIdPrefix release-candidate `
  -OutputPath .\xinxin-run\qa\next-action-collect.json `
  -HumanReadable
```

```powershell
# 聚合并开启健康闸口（低于阈值/异常时让任务失败）
powershell -ExecutionPolicy Bypass -File .\scripts\collect-xinxin-next-artifacts.ps1 `
  -RunDir .\xinxin-run `
  -RunIdPrefix release-candidate `
  -FailOnAttention `
  -FailOnCritical `
  -MinHealthScore 70 `
  -OutputPath .\xinxin-run\qa\next-action-collect.json `
  -HumanReadable
```

`collect-xinxin-next-artifacts.ps1` 新增健康闸口字段：
- `health_gate.enabled.fail_on_attention`
- `health_gate.enabled.fail_on_critical`
- `health_gate.enabled.min_health_score`
- `health_gate.blocked`
- `health_gate.reasons`
### 健康闸口统一规则（建议默认）

- 适用于：`xinxin-v2.1-release-line.yml`、`xinxin-v2.1-release-gate.yml`、`xinxin-v2.1-release-check.yml`、`xinxin-v2.1-on-release-gate.yml`
- 阈值规则在最终汇总时都由 `collect-xinxin-next-artifacts.ps1` 决定（`FailOnAttention` / `FailOnCritical` / `MinHealthScore`）：
  - `FailOnAttention`：`needs_attention` 为 `true` 时阻断
  - `FailOnCritical`：`health_status` 为 `critical` 时阻断
  - `MinHealthScore`：`health_score < min_health_score` 时阻断
- 默认建议：`FailOnAttention=false`、`FailOnCritical=true`、`MinHealthScore=70`
- 输出统一检查字段（可直接用于 CI 脚本判断）：
  - `health_status`、`health_score`、`needs_attention`、`health_reasons`
  - `health_gate.enabled.*` 与 `health_gate.blocked`、`health_gate.reasons`

## 11. `infer-xinxin-remediation-plan.ps1`

用途：把 `collect-xinxin-next-artifacts.ps1` 的聚合快照转成**可执行修复计划**，输出统一 JSON 和可读 Markdown（含推荐命令清单）。

参数：
- `-CollectPath`：可选，直接指定 `next-action-collect.json` 路径（默认自动在 `RunDir` 扫描）
- `-RunDir`：默认 `.\\xinxin-run`，用于自动定位最近的 `next-action-collect.json`
- `-RunIdPrefix`：用于在 `-CollectPath` 缺省时过滤本次批次
- `-OutputPath`：可选，输出 JSON 计划（便于程序化消费）
- `-MarkdownOutputPath`：可选，输出 Markdown 修复计划
- `-HumanReadable`：输出控制台可读摘要

示例：

```powershell
# 1) 先聚合产物快照（可带门禁）
powershell -ExecutionPolicy Bypass -File .\scripts\collect-xinxin-next-artifacts.ps1 `
  -RunDir .\xinxin-run `
  -RunIdPrefix release-candidate `
  -FailOnAttention `
  -FailOnCritical `
  -MinHealthScore 70 `
  -OutputPath .\xinxin-run\qa\next-action-collect.json

# 2) 基于快照输出可执行修复计划
powershell -ExecutionPolicy Bypass -File .\scripts\infer-xinxin-remediation-plan.ps1 `
  -CollectPath .\xinxin-run\qa\next-action-collect.json `
  -RunIdPrefix release-candidate `
  -HumanReadable `
  -MarkdownOutputPath .\xinxin-run\qa\remediation-plan.md `
  -OutputPath .\xinxin-run\qa\remediation-plan.json
```

输出中包含：
- `remediation_plan`：按优先级排序的可执行步骤（包含 `commands`、`playbooks`、`notes`）
- `health_gate_reasons`、`validation_hint`：辅助判断是否存在阻断风险
- `collect_path`：当前计划关联的快照路径
- `run_id_prefix`：本次计划关联前缀（用于回放同批次）
- `next_action_step`、`next_action_reason`、`next_action_command`：来自 next-action 的结构化建议
- `health_gate_enabled`：`collect` 输出中的闸口配置快照（包含 `fail_on_attention`、`fail_on_critical`、`min_health_score`）
- `health_gate_blocked`：是否命中阻断条件

CI 常用衍生字段：
- `remediation_plan_steps`：`remediation_plan` 长度
- `remediation_validation_hint`：`validation_hint` 的快速提取
- `remediation_plan_path`：CI 产物 JSON 路径
- `remediation_plan_markdown_path`：CI 产物 Markdown 路径

本地线增强（`run-xinxin-v2.1-release-line.ps1`）：
- 同一执行会追加产出并在 report 对齐的字段：
  - `next-action-collect.json`
  - `remediation-plan.json`
  - `remediation-plan.md`
  - report 根字段 `remediation_plan_steps`、`remediation_validation_hint`

## 12. `summarize-xinxin-recovery.ps1`

用途：一键聚合 `release-line-report.json`、`next-action-collect.json`、`remediation-plan.json` 与 `next-action-recommendation.md`，输出可执行复盘快照。

参数：
- `-ReportPath`：可选，指定 `release-line-report.json`（未传则按 `RunDir` 自动按时间+前缀回退）
- `-RunDir`：默认 `.\\xinxin-run`，用于在 `-ReportPath` 缺省时自动定位 bundle
- `-RunIdPrefix`：用于过滤同批次历史产物
- `-OutputPath`：可选，输出汇总 JSON（便于脚本化消费）
- `-MarkdownOutputPath`：可选，输出汇总 Markdown（适合复盘）
- `-HumanReadable`：默认输出控制台可读摘要

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\summarize-xinxin-recovery.ps1 -RunDir .\xinxin-run -RunIdPrefix release-candidate -HumanReadable
powershell -ExecutionPolicy Bypass -File .\scripts\summarize-xinxin-recovery.ps1 -RunDir .\xinxin-run -RunIdPrefix release-candidate -MarkdownOutputPath .\xinxin-run\qa\recovery-digest.md -OutputPath .\xinxin-run\qa\recovery-digest.json
```

输出中包含：
- `status` / `summary_pass` / `gate_required` / `gate_pass`
- `next_action_*`（步骤、命令、优先级、playbook）
- `remediation_plan_steps` / `remediation_validation_hint`
- `health_status` / `health_score` / `needs_attention` / `health_reasons`
- `artifacts`：`report`、`next_action_collect`、`remediation_plan`、`next_action_recommendation`
- `recovery_commands`（按优先级给出的下一步建议命令）

## 13. `execute-xinxin-recovery-cycle.ps1`（新增）

用途：本地一条命令完成三段式复盘闭环，自动按顺序执行：
- `baseline`（基线修复线）
- `gate`（闸门线）
- `all`（全量线）

每段单独产出独立 bundle，并最终在同一目录输出：
- `recovery-cycle-report.json`（三段结果总览）
- `recovery-cycle-summary.md`（简明 markdown 报告）
- `recovery-cycle-digest.json` + `recovery-cycle-digest.md`（基于 all 报告的聚合复盘）
- `next-action-recommendation.md`（最终下一步建议）

参数：
- `-RunDir`：默认 `.\\xinxin-run`
- `-RunIdPrefix`：本次闭环前缀（会透传到各线，默认 `recovery-cycle`）
- `-OutputRoot`：闭环产物根目录（默认 `.\\xinxin-run\\qa\\recovery-cycles`）
- `-BundleName`：可选，复用固定目录名
- `-RunId`：闭环批次 id，默认时间戳
- `-Force`：允许覆盖已存在的输出目录
 - `-CycleReportPath`：自定义总览输出路径
 - `-CycleMarkdownPath`：自定义 markdown 输出路径
 - `-OnlyPhases baseline|gate|all`：仅执行指定阶段（可写多个，默认三段）
 - `-StopOnFail`：任一阶段失败后立即停掉，不再执行后续阶段
 - `-NoExit`：供命令中枢等上层脚本调用时不在内部 `exit`，由调用方统一判定结果

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\execute-xinxin-recovery-cycle.ps1
```

```powershell
# 只跑闸门线（适用于已确认 baseline 通过后）
powershell -ExecutionPolicy Bypass -File .\scripts\execute-xinxin-recovery-cycle.ps1 -OnlyPhases gate -RunIdPrefix release-20260509
```

```powershell
# 只跑基线且遇失败即停
powershell -ExecutionPolicy Bypass -File .\scripts\execute-xinxin-recovery-cycle.ps1 -OnlyPhases baseline -StopOnFail -RunIdPrefix release-20260509
```

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\execute-xinxin-recovery-cycle.ps1 -RunIdPrefix release-20260509 -RunDir .\xinxin-run
```

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\execute-xinxin-recovery-cycle.ps1 `
  -RunIdPrefix hotfix-20260509 `
  -OutputRoot .\xinxin-run\qa\recovery-cycles `
  -BundleName daily-batch `
  -Force
```

## 14. `build-xinxin-recovery-board.ps1`（新增）

用途：基于 `recovery-cycle-report.json` 生成“发布看板单”，用于交接与复盘。

参数：
- `-OutputRoot`：闭环产物根目录（默认 `.\\xinxin-run\\qa\\recovery-cycles`）
- `-CycleName`：可选，指定要读取的 `OutputRoot` 子目录名
- `-CycleReportPath`：可选，直接指定 `recovery-cycle-report.json`
- `-OutputJson`：看板 JSON 输出路径（默认 `release-cycle-board.json`）
- `-OutputMarkdown`：看板 Markdown 输出路径（默认 `release-cycle-board.md`）
- `-HumanReadable`：在终端打印关键信息

示例：

```powershell
# 读取最新一次恢复闭环并生成看板
powershell -ExecutionPolicy Bypass -File .\scripts\build-xinxin-recovery-board.ps1
```

```powershell
# 读取指定闭环目录并生成看板
powershell -ExecutionPolicy Bypass -File .\scripts\build-xinxin-recovery-board.ps1 -CycleName release-20260509
```

## 15. `run-xinxin-release-command-center.ps1`（新增）

用途：将恢复闭环与看板生成压成一条命令（推荐发布前执行）：
- 默认先执行 `execute-xinxin-recovery-cycle.ps1`
- 再调用 `build-xinxin-recovery-board.ps1` 输出交接看板
- 适合“直接一条命令完成闭环+看板产出”

参数：
- `-RunDir`：默认 `.\\xinxin-run`
- `-RunIdPrefix`：默认 `release-cycle`
- `-OutputRoot`：闭环/看板产物根目录（默认 `.\\xinxin-run\\qa\\recovery-cycles`）
- `-BundleName`：可选，固定复用目录名；不填则按 `RunIdPrefix-RunId` 生成
- `-RunId`：闭环批次 ID，默认时间戳
- `-OnlyPhases baseline|gate|all`：可传递给闭环脚本
- `-StopOnFail`：可传递给闭环脚本
- `-SkipBoard`：只跑闭环，不生成看板
- `-NoBoardOnFail`：当闭环未通过时跳过看板生成
- `-HumanReadable`：看板阶段打印关键结果
- `-ReportFormat json|markdown|both`：控制命令中心结构化摘要输出格式（默认 `json`）
- `-EmitGithubOutputs`：强制将摘要/状态变量写入 `$GITHUB_OUTPUT`（默认仅当检测到该环境变量时写入）

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-release-command-center.ps1 -RunIdPrefix release-20260509
```

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-release-command-center.ps1 `
  -RunIdPrefix hotfix-20260509 `
  -RunDir .\xinxin-run `
  -OnlyPhases baseline,gate,all `
  -OutputRoot .\xinxin-run\qa\recovery-cycles `
  -HumanReadable
```

```powershell
# 闭环失败时直接退出，不生成看板（适合 CI）
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-release-command-center.ps1 `
  -RunIdPrefix release-20260509 `
  -RunDir .\xinxin-run `
  -OnlyPhases baseline `
  -NoBoardOnFail `
  -HumanReadable
```

```powershell
# 产出 JSON+Markdown 命令中心摘要（适合上层编排采集）
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-release-command-center.ps1 `
  -RunIdPrefix release-20260509 `
  -RunDir .\xinxin-run `
  -OnlyPhases baseline,gate,all `
  -ReportFormat both `
  -HumanReadable
```

默认会额外写入结构化命令中心摘要文件：
- `command-center-summary.json`
- `command-center-summary.md`（`-ReportFormat both` 或 `markdown` 时）

命令中心会输出（并在 GitHub Actions 下可落到 `$GITHUB_OUTPUT`）的变量：
- `command_center_summary` / `command_center_summary_json`
- `command_center_summary_markdown`
- `command_center_cycle_root`
- `cycle_report`
- `cycle_pass`
- `command_center_pass`
- `command_center_exit_code`
- `release_cycle_board_json`
- `release_cycle_board_markdown`


## Recovery Digest 增强说明

### 本次增强（与所有 Core 工作流一致）

- 所有 `xinxin-v2.1-*` CI 线已支持生成恢复摘要：
  - `recovery-digest.json`
  - `recovery-digest.md`
- `summarize-xinxin-recovery.ps1` 在无法读取 `release-line-report.json` 时，会回退到可用产物（`collect`/`remediation`/`next-action`）生成可用的恢复摘要，保证 CI 可持续产出。
- 工作流步骤会把摘要路径作为 outputs 输出：
  - `recovery_digest_path`
  - `recovery_digest_markdown_path`

### 推荐消费顺序

1. `health_status` / `health_score` / `needs_attention` 先判定是否阻断。
2. `recovery-digest.md` 直接交接复盘。
3. `recovery-digest.json` 与 `remediation-plan.json` 一起推进下一轮修复。
4. `next_action_path` 可直接打开获取统一建议 markdown。

### 快速读取建议

在 Workflow 结果中可优先关注：
- `recovery_digest_path`
- `recovery_digest_markdown_path`
- `summary_pass`
- `health_gate_blocked`
- `health_gate_reasons`
