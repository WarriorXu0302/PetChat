---
name: distill-contact
description: 把一个联系人(同事/朋友/家人)从飞书聊天记录蒸馏成可对话的 AI 人格。产物写入 packages/packages/companion/personas/{slug}/, 供桌面陪伴助手作为 "蒸馏人格" 后端调用。
argument-hint: [contact-slug]
version: 0.1.0
user-invocable: true
allowed-tools: Read, Write, Edit, Bash
---

> 语言: 按用户第一条消息的语言全程回复。本 Skill 的模板以中文为主。

# distill-contact 创建器

## 触发条件

- `/distill-contact`
- "蒸馏一个联系人" / "新建一个蒸馏人格" / "从飞书聊天记录蒸馏 XX"

进化模式 (已有人格):
- "我找到了新的聊天记录 / 追加新对话"
- "不对 / ta 不会这样说 / ta 其实是..."
- `/update-contact {slug}`

列出:
- `/list-contacts`

## 工具使用规则

本 Skill 运行在 Claude Code 环境, 可用工具:

| 任务 | 工具 |
|------|------|
| 读取 markdown / 图片 / JSON | `Read` |
| 解析飞书导出 / Bot API 响应 | `Bash` → `pnpm --filter @petchat/companion parse-feishu --` |
| 写入 / 更新人格文件 | `Write` / `Edit` |

**基础目录**: 所有产物写到 `packages/packages/companion/personas/{slug}/` (相对仓库根)。

## 安全边界

1. 仅用于桌面陪伴助手的"蒸馏人格"对话; **不代替与真人的真实沟通**。
2. **不主动联系真人**: 蒸馏产物是本地模型 + prompt, 不会向外发任何消息。
3. **不生成骚扰性内容**: 不模拟威胁、PUA、骚扰、性暗示 (除非原材料中就是这样, 而且用户是蒸馏自己熟悉的对象用于反思)。
4. **隐私**: 所有原材料和人格只在本机 `packages/companion/personas/{slug}/` 目录内, 不上传。
5. **Layer 0 硬规则**: 生成的人格不得输出原材料里没有证据、但现实中会造成伤害的话 (如代真人承诺、代真人道歉)。

## 主流程: 蒸馏一个新联系人

### Step 1: 基础信息 (3 个问题)

按 `packages/companion/src/distiller/prompts/intake.md` 只问 3 个问题:
1. 代号 (必填, 用作 slug)
2. 关系 + 基本信息 (一句话, 可跳过)
3. 性格画像 (一句话, 可跳过)

汇总后确认, 再进入下一步。

### Step 2: 原材料导入

询问用户:

```
原材料怎么给? 越多越像 ta。

  [A] 飞书 Bot API 拉到的 JSON
      (/open-apis/im/v1/messages 的响应, 含 items 数组)
  [B] 飞书客户端导出 / 规整好的消息列表 JSON
      数组或 {items: [...]} 均可, 要包含 sender.id, create_time, body.content
  [C] 直接粘贴 / 口述
      ta 的口头禅、风格、你们的共同上下文
  [D] 混合: A/B 给基础, C 做补充 (推荐)

可以跳过 A/B, 仅凭 C 生成, 但保真度会下降。
```

**解析飞书 JSON** (方式 A / B):

```bash
pnpm --filter @petchat/companion parse-feishu -- \
  --file {path} \
  --target-open-id {ou_xxx} \
  --output /tmp/feishu_{slug}.md \
  --dump-normalized /tmp/feishu_{slug}.normalized.json
```

如果只有显示名、没有 open_id:

```bash
pnpm --filter @petchat/companion parse-feishu -- \
  --file {path} \
  --target-name "{display_name}" \
  --sender-map {path_to_map.json} \
  --output /tmp/feishu_{slug}.md
```

sender-map JSON 格式: `{"ou_xxx": "张三", "ou_yyy": "我"}` —— 至少覆盖 ta 和用户自己两个 open_id。

**读回分析报告**: 用 `Read` 读 `/tmp/feishu_{slug}.md`。
**读回规整数据**: 用 `Read` 读 `/tmp/feishu_{slug}.normalized.json`, 取 `sample_messages` 做风格证据。

### Step 3: 分析原材料

两条线并行:

**线 A (Shared Context)**: 参考 `packages/companion/src/distiller/prompts/memory_analyzer.md`
提取: 关系时间线、共同场景、交流节奏、inside jokes、工作/技术上下文、冲突模式、高光时刻、当前关系状态。

**线 B (Persona)**: 参考 `packages/companion/src/distiller/prompts/persona_analyzer.md`
提取: 说话风格、情绪反应、互动节奏、关系中的角色, 把用户给的标签按标签翻译表转为具体行为。

### Step 4: 生成预览

按 `packages/companion/src/distiller/prompts/memory_builder.md` 生成 Shared Context。
按 `packages/companion/src/distiller/prompts/persona_builder.md` 生成 5 层 Persona 草稿。

展示摘要 (各 5-8 行), 询问用户确认。

### Step 5: 写入文件

**1. 创建目录**:

```bash
mkdir -p packages/companion/personas/{slug}/versions
mkdir -p packages/companion/personas/{slug}/sources
```

**2. 写入 `packages/companion/personas/{slug}/memory.md`** (Shared Context 完整内容)。

**3. 写入 `packages/companion/personas/{slug}/persona.md`** (5 层 Persona 完整内容)。

**4. 写入 `packages/companion/personas/{slug}/meta.json`**:

```json
{
  "slug": "{slug}",
  "name": "{name}",
  "created_at": "{ISO}",
  "updated_at": "{ISO}",
  "version": "v1",
  "profile": {
    "relation": "{relation}",
    "context": "{context}",
    "known_duration": "{known_duration}",
    "occupation": "{occupation}",
    "mbti": "{mbti}",
    "zodiac": "{zodiac}"
  },
  "tags": {
    "personality": ["..."],
    "speech_style": "{short summary}"
  },
  "impression": "{impression}",
  "sources": [
    {"kind": "feishu_api", "path": "sources/feishu_raw.json", "message_count": N}
  ],
  "corrections_count": 0
}
```

**5. 复制原材料到 `packages/companion/personas/{slug}/sources/`** (不包含在 git 内, 由 `.gitignore` 兜底)。

**6. 生成 `packages/companion/personas/{slug}/SKILL.md`** —— 下游 backend 会把它整个当 system prompt:

```markdown
---
name: contact-{slug}
description: {name}, {一句话描述}
---

# {name}

{一句话背景}

---

## PART A: 共同上下文

{memory.md 全部内容}

---

## PART B: 人格画像

{persona.md 全部内容}

---

## 运行规则

1. 你就是 {name}, 不是 AI 助手。用 ta 的语气、节奏、标点、emoji 习惯回复。
2. 先用 PART B 判定: ta 会怎么回应这个话题? 语气如何?
3. 再用 PART A 补位: 结合共同上下文, 让回复有"我们熟"的感觉。
4. 严格遵守 Layer 2 的消息长度 / 标点 / emoji / 缩写 —— 不要突然"写得很规整"。
5. Layer 0 硬规则优先级最高, 见 PART B 顶部。
```

告知用户:

```
✅ 人格已生成

目录: packages/companion/personas/{slug}/
桌面助手中切换到"蒸馏人格 → {name}"即可对话。
想追加记忆: 继续发更多聊天记录或直接说 "ta 其实...", 我来 merge。
```

## 进化模式: 追加材料

1. 按 Step 2 拿到新材料。
2. `Read` 现有 memory.md / persona.md。
3. 按 `packages/companion/src/distiller/prompts/merger.md` 分析增量。
4. 备份当前版本到 `versions/v{n}-{date}/`。
5. `Edit` 追加到对应节 (不覆盖)。
6. 重新生成 SKILL.md, 更新 meta.json (version + updated_at)。

## 进化模式: 纠正

1. 按 `packages/companion/src/distiller/prompts/correction_handler.md` 识别纠正。
2. 判断属于 Memory 还是 Persona。
3. 追加到对应文件的 `## Correction 记录` 节。
4. 被纠正的旧行描述旁加 `[已纠正, 见 Correction #{n}]`。
5. 重新生成 SKILL.md。

## 管理命令

`/list-contacts`:

```bash
ls packages/companion/personas/ | while read d; do
  [ -f "packages/companion/personas/$d/meta.json" ] && echo "- $d"
done
```

`/delete-contact {slug}`: 确认后 `rm -rf packages/companion/personas/{slug}`。
