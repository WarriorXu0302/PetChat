# 宠物动画资源项目（xinxin）

该仓库默认聚焦 `xinxin-run`，`kea-run` 仅留作历史对照，不纳入默认执行流程。

## 当前状态

- `xinxin-run`：主线产线齐备（jobs complete、frames 全量、目录一致性良好）
- `kea-run`：历史快照保留，可按需查看

## 三阶段执行（已完成）

### 阶段1：修复
1. 修复中文资源文本编码与可读性：`xinxin-run/xinxin-warm-lines.zh-CN.json`
2. 修正路径可移植性（去绝对路径）：`xinxin-run/pet_request.json`
3. 完善历史兼容字段：`kea-run/pet_request.json` 保留 `canonical_identity_reference`

### 阶段2：脚本化
1. `scripts/collect-pet-run-status.ps1`
2. `scripts/run-pet-workflow.ps1`
3. `scripts/generate-pipeline-manifest.ps1`

### 阶段3：治理与增强（本轮新增）
1. 状态脚本增强：`health score`、`frames 完整率`、`jobs 完整率`、`generation gate`
2. `run-pet-workflow` 支持 `-RequireHealthy`，用于自动化前置闸门
3. 新增交付清单脚本：`scripts/build-xinxin-delivery-manifest.ps1`

## 推荐执行清单（默认 xinxin）

```powershell
# 1) 快速健康检查（会输出 qa/run-status.json）
powershell -ExecutionPolicy Bypass -File .\scripts\collect-pet-run-status.ps1 -RunDir .\xinxin-run

# 2) 初始化目录（如缺失）并进行流程检查
powershell -ExecutionPolicy Bypass -File .\scripts\run-pet-workflow.ps1 -RunDir .\xinxin-run -CreateStructure

# 3) 自动化要求：直接用 -RequireHealthy 做保护（推荐在 CI/脚本化中使用）
powershell -ExecutionPolicy Bypass -File .\scripts\run-pet-workflow.ps1 -RunDir .\xinxin-run -RequireHealthy

# 4) 生成仓库级汇总（仅 xinxin-run）
powershell -ExecutionPolicy Bypass -File .\scripts\generate-pipeline-manifest.ps1 -RootDir .\

# 5) 交付前产物清单（含 SHA-256）
powershell -ExecutionPolicy Bypass -File .\scripts\build-xinxin-delivery-manifest.ps1 -RunDir .\xinxin-run -RequireHealthy
```

kea 数据不会自动进入默认执行命令，但仍可按需保留和对照。

