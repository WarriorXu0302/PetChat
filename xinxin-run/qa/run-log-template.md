# Xinxin v2.1 Run Log Template

用途：每次使用 v2.1 prompt 套件重训后，记录配置变更、执行结果和 QA 通过情况。

## 文件命名规范
- 建议文件名：`run-log-YYYYMMDD-HHMM.md`
- 示例：`run-log-20260509-1430.md`
- 时间以本地时间（24小时制）为准。

## 记录模板

### 基本信息
- 日期：
- 执行者：
- 分支/工作树：
- 目标版本：`xinxin-persona-v2.1`
- 触发原因：
  - [ ] 文案优化
  - [ ] IP漂移修复
  - [ ] 失败状态修复
  - [ ] 首次全量验收
  - [ ] 其他（请说明）

### 改动文件
- `pet_request.json`：
- `xinxin-ip-contract.md`：
- `prompts/rows/v2/*.md`：
- `imagegen-jobs.json`：
- 其他：

### 执行步骤
1. 触发状态：
2. 重跑作业：
3. 生成/导出：
4. QA 复核（简述）：

### 按状态结果（P0/P1/P2）
- idle：PASS / FAIL（备注）
- waiting：PASS / FAIL（备注）
- running：PASS / FAIL（备注）
- review：PASS / FAIL（备注）
- waving：PASS / FAIL（备注）
- jumping：PASS / FAIL（备注）
- running-right：PASS / FAIL（备注）
- running-left：PASS / FAIL（备注）
- failed：PASS / FAIL（备注）

### 风险与问题
- 发现问题：
- 定位状态：
- 处理策略：
  - [ ] v2 状态 prompt 修订
  - [ ] 单状态重跑
  - [ ] 全量重跑
  - [ ] 归位到上一次稳定版

### 通过判断
- 总结状态：`PASS` / `RE-TRY`
- 决策：

### 留存快照
- `decoded/*` 时间戳：
- `frames/*` 时间戳：
- `final/*` 时间戳：
- 回退基线文件：
- 机器可读快照：`run-log-YYYYMMDD-HHMMSS-summary.json`

### 人工复核
- `set-v2.1-manual-review.ps1` 逐状态结果：
  - idle：PASS / FAIL / PENDING（备注）
  - waiting：PASS / FAIL / PENDING（备注）
  - running：PASS / FAIL / PENDING（备注）
  - review：PASS / FAIL / PENDING（备注）
  - waving：PASS / FAIL / PENDING（备注）
  - jumping：PASS / FAIL / PENDING（备注）
  - running-right：PASS / FAIL / PENDING（备注）
  - running-left：PASS / FAIL / PENDING（备注）
  - failed：PASS / FAIL / PENDING（备注）

### 备注
- 复核人签名：
- 审核通过人：
