# PetChat

一个桌面陪伴助手的原型仓库。目标是把一只像素风小人 (xinxin) 挂在桌面上, 接上聊天软件, 既可以和真人中转对话, 也可以和"从聊天记录蒸馏出来的 AI 人格"对话, 聊天状态同步驱动桌宠动画。

当前进度:

- ✅ 精灵图流水线 (xinxin 的 9 状态 57 帧 + 发布闸门自动化)
- ✅ 人格蒸馏骨架 (飞书聊天记录 → 5 层 Persona + 共同上下文)
- ✅ 聊天后端接口 (蒸馏 / 飞书真人可切换, 历史分别存储)
- ⏳ 桌面 UI 壳 (Tauri, 待开工)
- ⏳ 飞书 webhook 接收服务 (现在只能发, 收需要公网端点)

---

## 仓库结构

```
pet/
├── xinxin-run/          # 精灵图流水线: 输入契约 / 生成帧 / 审计产物
├── scripts/             # PowerShell 自动化 (发布线 / 恢复闭环 / 命令中心)
├── .github/workflows/   # 6 条 xinxin-v2.1-* CI 线 (dry-run / 闸门 / 发布)
├── companion/           # 桌面陪伴助手
│   ├── distiller/       # Claude Code Skill: 从飞书记录蒸馏人格
│   ├── backend/         # ChatBackend 接口 + Distilled / Feishu 两种后端
│   ├── personas/        # (gitignored) 蒸馏产物, 每人一个目录
│   └── runtime/         # (gitignored) sqlite / contacts 索引
├── pipeline-manifest.json
└── references/
```

`CLAUDE.md` 里有给 Claude Code 的项目级工作指南 (流水线分层、约定、脚本索引)。

---

## 两条主线

### 一、桌面陪伴助手 (`companion/`)

**快速开始**:

```bash
pip install anthropic
export ANTHROPIC_API_KEY=sk-ant-...
```

**蒸馏一个联系人** (在 Claude Code 里):

```
/distill-contact
```

Skill 会问 3 个问题 (代号 / 关系 / 性格印象), 然后引导你导入飞书 Bot API 拉到的消息 JSON, 或者直接粘贴。产物写到 `companion/personas/{slug}/`:

```
memory.md      共同上下文
persona.md     5 层人格 (Layer 0 硬规则 → Layer 4 互动)
SKILL.md       合并产物, 下游 backend 当 system prompt
meta.json      元信息
sources/       原材料备份
```

**切换后端聊天** (CLI, 先把双后端跑通, 之后接 UI):

```bash
python3 -m companion.backend.cli list
python3 -m companion.backend.cli chat {slug} --source distilled      # 和蒸馏人格对话
python3 -m companion.backend.cli chat {slug} --source feishu         # 和真人中转
```

**飞书真人中转** 需要自建飞书应用:

```bash
export FEISHU_APP_ID=cli_...
export FEISHU_APP_SECRET=...
python3 -m companion.backend.cli register-feishu {slug} "显示名" oc_chat_id_xxx
```

⚠️ 当前只能发消息 (bot 身份), 接收对方回复需要另起一个 webhook 服务订阅 `im.message.receive_v1`, 转到 `FeishuBackend.record_incoming()`。详见 `companion/README.md`。

**设计要点**:

- `ChatBackend` 接口 (`companion/backend/base.py`) 是 UI 的唯一依赖, 切换后端就是换实例。
- 同一联系人的蒸馏历史和飞书历史**分开存 sqlite**, 不互相污染。
- `BackendMetadata.source` / `read_only` / `notice` 给 UI 做身份提示和禁用态。

### 二、精灵图流水线 (`xinxin-run/`)

"xinxin" 是一只粉白色 chibi 吉祥物, 用作桌宠的视觉载体。流水线从 prompt + 参考图开始, 经过 imagegen → 切帧 → 审计 → 人工复核 → 发布闸门, 最终产出 `final/spritesheet.png`。

**基本命令** (PowerShell, Windows 路径; macOS / Linux 用 pwsh 并把 `.\` 换成 `./`):

```powershell
# 快速健康检查
powershell -ExecutionPolicy Bypass -File .\scripts\collect-pet-run-status.ps1 -RunDir .\xinxin-run

# 本地一条命令跑完 check + pack + audit + run-log + 发布闸门
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1.ps1 -Mode all -RunDir .\xinxin-run -RequireReleaseGate

# 发布前命令中心 (恢复闭环 + 交接看板)
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-release-command-center.ps1 -RunIdPrefix release-<date> -RunDir .\xinxin-run -HumanReadable
```

**流水线分层**: 输入契约 → 生成产物 → 状态审计 → 复核闸门 → 发布编排 → 恢复/看板。完整说明在 `CLAUDE.md` 和 `scripts/README.md`。

**CI**: 6 条 `xinxin-v2.1-*` workflow 围绕发布闸门, 都产出统一的 `run-status.json` artifact, 通过 `XINXIN_HEALTH_GATE_*` 仓库变量控制健康阈值。

---

## 路线图

下一步按优先级:

1. 先跑一次端到端蒸馏, 用真实飞书数据打磨 prompts (`companion/distiller/prompts/`)
2. 写飞书 webhook 接收服务 (FastAPI + 公网隧道), 让 `FeishuBackend.record_incoming` 能被自动触发
3. Tauri 桌面壳: 左侧联系人列表, 每行 `[蒸馏] [真人]` 两个 tab, 点谁就 `registry.get(slug, source)` 换后端
4. 把 `xinxin-run/` 的 sprite 状态接上消息事件 (收到消息 → waving / 回复中 → running / 失败 → failed)

---

## 安全与隐私

- 所有聊天记录和蒸馏产物只在本机 `companion/personas/` / `companion/runtime/`, 已 `.gitignore`
- 蒸馏产物的 Layer 0 硬规则禁止模拟真人做承诺 / 道歉 / 表白, 除非原材料有同类证据
- 飞书 Bot 中转对方能看到机器人身份; 官方 API 不提供"以用户身份双向私聊", 这是平台限制不是技术选择

## 致谢

- 人格蒸馏管线的设计思路参考了 [ex-skill](https://github.com/) 项目 (5 层 Persona 结构 + 增量 merge + 纠正流程)。本仓库把上下文从"前任"泛化为"同事/朋友/家人", 并替换了飞书 parser。
