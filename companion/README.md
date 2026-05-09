# companion/ — 桌面陪伴助手

把"蒸馏人格"和"飞书真人中转"接到同一个聊天窗口。UI 按钮切 source, 底下换后端实例。

```
companion/
├── distiller/              # 人格蒸馏 (Claude Code Skill, 参考 ex-skill)
│   ├── SKILL.md
│   ├── prompts/            # intake / analyzer / builder / correction / merger
│   └── tools/
│       └── feishu_parser.py
├── backend/                # 运行时后端
│   ├── base.py             # ChatBackend / Message / BackendMetadata
│   ├── distilled.py        # 蒸馏人格 → Claude API
│   ├── feishu.py           # 飞书 Bot 中转 (真人)
│   ├── registry.py         # 按 (slug, source) 取实例
│   └── cli.py              # 最小命令行, 用来先把两个后端跑通
├── personas/               # 蒸馏产物 (每人一个目录, gitignored)
└── runtime/                # sqlite + contacts 索引 (gitignored)
```

## 快速流程

### 0. 依赖

```bash
pip install anthropic
```

环境变量:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
# 真人后端要用时再配:
export FEISHU_APP_ID=cli_...
export FEISHU_APP_SECRET=...
```

### 1. 蒸馏一个人 (走 Claude Code)

在 Claude Code 里:

```
/distill-contact
```

或者说"蒸馏一个联系人", Skill 会引导 3 个问题 + 原材料导入。
原材料可以是:

- 飞书 Bot API 拉到的消息 JSON (推荐, 结构稳定)
- 客户端导出的消息 JSON / 数组
- 直接粘贴 / 口述 (保真度较低)

产物写到 `companion/personas/{slug}/`:

```
memory.md       共同上下文
persona.md      5 层人格
meta.json
SKILL.md        下游 backend 读取的合并产物
sources/        原材料备份 (gitignored)
versions/       历史版本
```

### 2. 解析飞书消息 (可单独跑)

```bash
python3 companion/distiller/tools/feishu_parser.py \
  --file /path/to/feishu_export.json \
  --target-open-id ou_xxx \
  --output /tmp/feishu-report.md \
  --dump-normalized /tmp/feishu-normalized.json
```

支持的输入结构:
- Bot API 响应: `{"code":0,"data":{"items":[...]}}`
- 扁平数组 / `{"items":[...]}` / `{"messages":[...]}`

### 3. 和蒸馏人格对话

```bash
python3 -m companion.backend.cli list
python3 -m companion.backend.cli chat {slug} --source distilled
```

### 4. 接通真人 (飞书 Bot 中转)

首先在飞书开放平台建一个自建应用, 拿到 `app_id` / `app_secret`, 开启
`im:message` 权限, 把 bot 拉进与 ta 的群或开启单聊。然后:

```bash
python3 -m companion.backend.cli register-feishu {slug} "ta 的显示名" oc_chat_id_xxx
python3 -m companion.backend.cli chat {slug} --source feishu
```

**注意**: 当前 `FeishuBackend.send` 已实现 bot 身份发消息; **接收** ta 的回复
还需要一个 webhook 服务订阅 `im.message.receive_v1` 事件, 并把事件转到
`FeishuBackend.record_incoming(...)`。这一步是独立任务, CLI 里暂时只能看
webhook 写入的历史, 不会自动拉取。

## 后端切换语义

- 同一个 contact 可以同时有两种后端; 历史分开存, 不互相污染:
  - 蒸馏: `personas/{slug}/history.sqlite`
  - 飞书: `runtime/feishu/feishu-{slug}.sqlite`
- `BackendMetadata.notice` 是给 UI 的提示条 (是不是 AI / 是否只读 / 是否缺凭证)。
- `BackendMetadata.read_only=True` 时 UI 应禁用发送框。

## 已知限制

- **飞书只能 Bot 中转**: ta 看到的是 bot 身份, 不是用户本人。官方 API 不提供
  "以用户身份双向私聊"。
- **接收方向需要公网 webhook**: 目前未集成; 先用蒸馏模式玩起来。
- **蒸馏质量受原材料影响**: 至少给几百条 ta 本人的消息才会有辨识度。
