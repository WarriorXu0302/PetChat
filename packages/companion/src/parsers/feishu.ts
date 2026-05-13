/**
 * Feishu (Lark) chat-history parser.
 *
 * Accepts: raw Bot API response (`{code, data:{items}}`), wrapper objects
 * (`{items}` / `{messages}`) or flat arrays. Produces a normalized message
 * list and a markdown analysis report (speech particles, emoji, punctuation,
 * active hours, sample messages) — mirrors the old `wechat_parser.py` output
 * contract so downstream distillation prompts don't need to change.
 */

import {
  FeishuPayload,
  FeishuPayloadSchema,
  FeishuMessage,
  NormalizedMessage,
} from "@petchat/shared";

export interface ParseOptions {
  targetOpenId?: string;
  targetName?: string;
  senderMap?: Record<string, string>;
}

export interface AnalysisResult {
  totalMessages: number;
  targetMessages: number;
  otherMessages: number;
  topParticles: [string, number][];
  topEmojis: [string, number][];
  avgMessageLength: number;
  messageStyle: "short_burst" | "long_form";
  punctuationHabits: Record<string, number>;
  activeHours: number[];
  sampleMessages: string[];
}

// ---------- load & flatten ----------

export function flattenPayload(raw: unknown): FeishuMessage[] {
  const parsed = FeishuPayloadSchema.parse(raw);
  if (Array.isArray(parsed)) return parsed;
  if ("items" in parsed) return parsed.items;
  if ("messages" in parsed) return parsed.messages;
  if ("data" in parsed) return parsed.data.items;
  throw new Error("Unrecognized Feishu payload shape");
}

// ---------- content extraction ----------

function extractPostText(content: Record<string, unknown>): string {
  const parts: string[] = [];
  if (content.title) parts.push(String(content.title));
  const paragraphs = (content.content as unknown[][]) ?? [];
  for (const paragraph of paragraphs ?? []) {
    const line: string[] = [];
    for (const nodeRaw of paragraph ?? []) {
      const node = nodeRaw as Record<string, unknown>;
      const tag = node.tag as string | undefined;
      if (tag === "text") line.push(String(node.text ?? ""));
      else if (tag === "a") line.push(`${node.text ?? ""}(${node.href ?? ""})`);
      else if (tag === "at") line.push(`@${node.user_id ?? ""}`);
      else if (tag === "img" || tag === "media" || tag === "file") line.push(`[${tag}]`);
      else if (tag === "emotion") line.push(`[emoji:${node.key ?? ""}]`);
      else line.push(String(node.text ?? `[${tag}]`));
    }
    if (line.length) parts.push(line.join(""));
  }
  return parts.join("\n").trim();
}

export function extractContent(msg: FeishuMessage): string {
  const raw = msg.body?.content;
  let content: Record<string, unknown>;
  if (raw == null || raw === "") return "";
  if (typeof raw === "string") {
    try {
      content = JSON.parse(raw);
    } catch {
      return raw;
    }
  } else {
    content = raw;
  }

  switch (msg.msg_type) {
    case "text":
      return String(content.text ?? "");
    case "post":
      return extractPostText(content);
    case "image":
      return "[图片]";
    case "file":
      return `[文件:${content.file_name ?? ""}]`;
    case "audio":
      return "[语音]";
    case "sticker":
      return "[表情]";
    case "share_chat":
      return "[分享群聊]";
    case "share_user":
      return "[分享名片]";
    case "interactive":
      return "[卡片]";
    default:
      return `[${msg.msg_type}]`;
  }
}

// ---------- normalize ----------

export function normalize(messages: FeishuMessage[], senderMap?: Record<string, string>): NormalizedMessage[] {
  const out: NormalizedMessage[] = [];
  for (const m of messages) {
    if (m.deleted) continue;
    const sid = m.sender?.id ?? m.sender?.open_id ?? "";
    const sender = sid ? senderMap?.[sid] ?? sid : "unknown";
    let ts = String(m.create_time ?? "");
    const ms = Number(ts);
    if (Number.isFinite(ms) && ms > 0) {
      const d = new Date(ms);
      ts = formatLocalDate(d);
    }
    const content = extractContent(m);
    if (!content) continue;
    out.push({
      timestamp: ts,
      senderId: sid,
      sender,
      msgType: m.msg_type,
      content,
    });
  }
  return out;
}

function pad(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}
function formatLocalDate(d: Date): string {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

// ---------- analyze ----------

const PARTICLE_RE = /[哈嗯哦噢嘿唉呜啊呀吧嘛呢吗么]+/g;
const EMOJI_RE = /(\p{Extended_Pictographic}(?:‍\p{Extended_Pictographic})*)/gu;

export function analyze(
  messages: NormalizedMessage[],
  targetIdentifier: string,
  targetOpenId?: string,
): AnalysisResult {
  const target = targetOpenId
    ? messages.filter((m) => m.senderId === targetOpenId)
    : messages.filter((m) => targetIdentifier && m.sender.includes(targetIdentifier));
  const other = messages.filter((m) => !target.includes(m));

  const text = target.map((m) => m.content).join(" ");

  const particles: Record<string, number> = {};
  for (const match of text.matchAll(PARTICLE_RE)) {
    const w = match[0];
    particles[w] = (particles[w] ?? 0) + 1;
  }
  const topParticles = Object.entries(particles).sort((a, b) => b[1] - a[1]).slice(0, 10) as [string, number][];

  const emojis: Record<string, number> = {};
  for (const match of text.matchAll(EMOJI_RE)) {
    const e = match[0];
    emojis[e] = (emojis[e] ?? 0) + 1;
  }
  const topEmojis = Object.entries(emojis).sort((a, b) => b[1] - a[1]).slice(0, 10) as [string, number][];

  const lengths = target.map((m) => m.content.length);
  const avg = lengths.length ? lengths.reduce((a, b) => a + b, 0) / lengths.length : 0;

  const punct: Record<string, number> = {
    句号: (text.match(/。/g) ?? []).length,
    感叹号: (text.match(/[!！]/g) ?? []).length,
    问号: (text.match(/[?？]/g) ?? []).length,
    省略号: (text.match(/\.{3}|…/g) ?? []).length,
    波浪号: (text.match(/[~～]/g) ?? []).length,
  };

  const activeHours = new Array(24).fill(0) as number[];
  for (const m of target) {
    const match = m.timestamp.match(/^\d{4}-\d{2}-\d{2}\s+(\d{2}):/);
    if (match) {
      const h = Number(match[1]);
      if (h >= 0 && h < 24) activeHours[h] += 1;
    }
  }

  return {
    totalMessages: messages.length,
    targetMessages: target.length,
    otherMessages: other.length,
    topParticles,
    topEmojis,
    avgMessageLength: Math.round(avg * 10) / 10,
    messageStyle: avg < 20 ? "short_burst" : "long_form",
    punctuationHabits: punct,
    activeHours,
    sampleMessages: target.slice(0, 50).map((m) => m.content),
  };
}

// ---------- report ----------

export function renderReport(
  source: string,
  targetLabel: string,
  stats: AnalysisResult,
): string {
  const lines: string[] = [];
  lines.push(`# 飞书聊天记录分析 — ${targetLabel}`, "");
  lines.push(`来源文件: ${source}`);
  lines.push(`总消息数: ${stats.totalMessages}`);
  lines.push(`ta 的消息数: ${stats.targetMessages}`);
  lines.push(`其他人消息数: ${stats.otherMessages}`, "");

  if (stats.topParticles.length) {
    lines.push("## 高频语气词");
    for (const [w, c] of stats.topParticles) lines.push(`- ${w}: ${c} 次`);
    lines.push("");
  }
  if (stats.topEmojis.length) {
    lines.push("## 高频 Emoji");
    for (const [e, c] of stats.topEmojis) lines.push(`- ${e}: ${c} 次`);
    lines.push("");
  }

  lines.push("## 标点习惯");
  for (const [k, v] of Object.entries(stats.punctuationHabits)) lines.push(`- ${k}: ${v} 次`);
  lines.push("");

  lines.push("## 消息风格");
  lines.push(`- 平均消息长度: ${stats.avgMessageLength} 字`);
  lines.push(`- 风格: ${stats.messageStyle === "short_burst" ? "短句连发型" : "长段落型"}`, "");

  lines.push("## 活跃时段 (24h)");
  const peak = stats.activeHours.some((v) => v > 0)
    ? stats.activeHours.indexOf(Math.max(...stats.activeHours))
    : null;
  if (peak != null) lines.push(`- 峰值小时: ${peak}:00`);
  for (let h = 0; h < 24; h++) {
    if (stats.activeHours[h]) lines.push(`  - ${pad(h)}:00 — ${stats.activeHours[h]}`);
  }
  lines.push("");

  if (stats.sampleMessages.length) {
    lines.push("## 消息样本 (前 50 条)");
    stats.sampleMessages.forEach((msg, i) => lines.push(`${i + 1}. ${msg}`));
  }

  return lines.join("\n");
}

export function parseFeishu(raw: unknown, opts: ParseOptions): {
  normalized: NormalizedMessage[];
  analysis: AnalysisResult;
} {
  const items = flattenPayload(raw);
  const normalized = normalize(items, opts.senderMap);
  const label = opts.targetName ?? opts.targetOpenId ?? "";
  const analysis = analyze(normalized, label, opts.targetOpenId);
  return { normalized, analysis };
}
