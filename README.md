# PetChat

一个桌面陪伴助手的原型仓库。一只像素风小人挂在桌面上, 接上聊天软件, 既可以和真人中转对话, 也可以和"从聊天记录蒸馏出来的 AI 人格"对话, 聊天状态同步驱动桌宠动画。

当前进度:

- ✅ 精灵图流水线 (xinxin 的 9 状态 57 帧 + 发布闸门自动化, PowerShell)
- ✅ 人格蒸馏骨架 (飞书聊天记录 → 5 层 Persona + 共同上下文)
- ✅ 聊天后端接口 (蒸馏 / 飞书真人可切换, 历史分别存储)
- ✅ Electron 桌面壳 (联系人列表 + 双后端切换 + 流式对话)
- ⏳ 飞书 webhook 接收服务 (能发, 收需要公网端点)
- ⏳ sprite 动画挂接消息事件

---

## 技术栈

- **TypeScript** 为主力语言(`@petchat/shared` / `@petchat/companion` / `@petchat/desktop`)
- **pnpm workspace** 做 monorepo, 三个 package 共享类型
- **Electron + React + Vite** 做桌面壳
- **better-sqlite3** 做本地对话历史
- **@anthropic-ai/sdk** 调 Claude API 驱动蒸馏人格
- **PowerShell**(遗留): `scripts/*.ps1` 是旧的 sprite 流水线, 后续再统一迁到 TS

---

## 仓库结构

```
pet/
├── packages/
│   ├── shared/              zod schemas: Message / BackendMetadata / Persona / Feishu
│   └── companion/           业务逻辑
│       ├── src/
│       │   ├── backend/     ChatBackend 接口 + Distilled / Feishu / Registry
│       │   ├── parsers/     feishu 消息 JSON 解析器 (含 CLI)
│       │   ├── distiller/   Claude Code Skill + 分析/模板 prompts
│       │   └── cli.ts       petchat-companion list / chat / register-feishu
│       └── personas/        (gitignored) 蒸馏产物
├── apps/
│   └── desktop/             Electron + React
│       └── src/
│           ├── main/        主进程 + preload, IPC 调 @petchat/companion
│           └── renderer/    React UI (联系人列表 + 聊天面板 + source 切换)
├── xinxin-run/              精灵图流水线数据 (不变)
├── scripts/                 PowerShell 流水线 (遗留, 后续迁移)
├── .github/workflows/       sprite 流水线 CI (6 条)
├── pnpm-workspace.yaml
└── tsconfig.base.json
```

---

## 快速开始

前置: Node 22+, pnpm 10+。

```bash
pnpm install
# better-sqlite3 和 electron 需要一次构建脚本授权
pnpm approve-builds
```

### 1. 蒸馏一个联系人 (在 Claude Code 里)

```
/distill-contact
```

Skill 会问 3 个问题 (代号 / 关系 / 性格印象), 然后引导你导入飞书 Bot API 的 JSON 或直接粘贴。产物写到 `packages/companion/personas/{slug}/`:

```
memory.md      共同上下文
persona.md     5 层人格 (Layer 0 硬规则 → Layer 4 互动)
SKILL.md       合并产物, 下游 backend 当 system prompt
meta.json      元信息
```

### 2. CLI 冒烟测试双后端

```bash
# 纯 JS 解析飞书 JSON
pnpm --filter @petchat/companion parse-feishu -- \
  --file /path/to/feishu.json --target-open-id ou_xxx \
  --output /tmp/report.md

# 列出联系人
pnpm --filter @petchat/companion cli list

# 和蒸馏人格对话
ANTHROPIC_API_KEY=sk-ant-... pnpm --filter @petchat/companion cli chat {slug} --source distilled

# 和真人 (飞书中转)
FEISHU_APP_ID=... FEISHU_APP_SECRET=... \
  pnpm --filter @petchat/companion cli register-feishu {slug} "显示名" oc_chat_id_xxx
pnpm --filter @petchat/companion cli chat {slug} --source feishu
```

### 3. 桌面 app

```bash
# 开发模式 (Vite dev server + Electron 并行)
pnpm --filter @petchat/desktop start

# 生产构建
pnpm --filter @petchat/desktop build
```

Electron 主进程从 `packages/companion/personas/` 读联系人, 通过 IPC 转发消息流到渲染进程; UI 里每个联系人有 `[蒸馏人格] [真人 · 飞书]` 两个 tab, 点哪个就切哪个后端, **历史各存各的互不污染**。

---

## 设计要点

- **`ChatBackend` 接口** (`packages/shared` 的 `Message` / `BackendMetadata` + `packages/companion/src/backend/base.ts`) 是 UI 的唯一依赖。切换后端就是换实例, UI 不关心底下是本地 LLM 还是真人中转。
- **历史隔离**: 蒸馏存 `personas/{slug}/history.sqlite`, 飞书存 `runtime/feishu/feishu-{slug}.sqlite`。
- **`BackendMetadata.source` / `readOnly` / `notice`** 给 UI 做身份提示和禁用态。

---

## 已知限制

- **飞书只能 Bot 中转**: ta 看到的是 bot 身份, 不是用户本人。官方 API 不提供"以用户身份双向私聊"。
- **接收方向需要公网 webhook**: 当前能发不能收; 先用蒸馏模式玩起来。
- **蒸馏质量受原材料影响**: 至少几百条 ta 本人的消息才有辨识度。
- **xinxin-run 流水线仍是 PowerShell**: 当前阶段聚焦桌宠, 等闭环后再统一迁到 TS。

---

## 路线图

1. 用真实飞书数据跑一次端到端蒸馏, 打磨 prompts (`packages/companion/src/distiller/prompts/`)
2. 写飞书 webhook 接收服务 (Node + Express/Fastify + 公网隧道), 让 `FeishuBackend.recordIncoming` 能被触发
3. 把 `xinxin-run/` 的 sprite 状态挂上消息事件 (收到消息 → waving / 回复中 → running / 失败 → failed)
4. 最后把 `scripts/*.ps1` 的流水线能力也迁成 TS package, 完全去掉 PowerShell 依赖

## 致谢

人格蒸馏管线的设计思路参考 ex-skill 项目 (5 层 Persona 结构 + 增量 merge + 纠正流程)。本仓库把上下文从"前任"泛化为"同事/朋友/家人", 把 parser 换成飞书, 并把整套管道从 Python 迁到 TypeScript。
