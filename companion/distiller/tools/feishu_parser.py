#!/usr/bin/env python3
"""飞书 (Lark) 聊天记录解析器

支持两种输入形态:
- Bot API 原始响应: /open-apis/im/v1/messages?container_id_type=chat&container_id=...
  结构形如 {"code":0,"msg":"success","data":{"items":[{...}, ...]}}
- 扁平化的消息数组: [{...}, {...}] 或 {"items": [...]} / {"messages": [...]}

每条消息的关键字段 (基于 Feishu Open API v1):
- message_id, chat_id, msg_type, create_time (ms string)
- sender.id (open_id), sender.sender_type (user/app)
- body.content: JSON 字符串, 结构取决于 msg_type
  - text:   {"text": "...", "mentions": [...]}
  - post:   {"title":"...", "content":[[{"tag":"text","text":"..."}]]}
  - image:  {"image_key": "..."}
  - file / audio / sticker / interactive / share_chat 等: 直接标记为 "[类型]"

Usage:
    python3 feishu_parser.py --file <path> --target-open-id ou_xxx --output <path>
    python3 feishu_parser.py --file <path> --target-name 张三 --sender-map map.json --output <path>
        map.json: {"ou_xxx": "张三", "ou_yyy": "我"}
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


# ---------- 读取 & 扁平化 ----------

def load_raw(file_path: str) -> list[dict]:
    """把任意支持的形态规整成消息列表"""
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        if "data" in data and isinstance(data["data"], dict) and "items" in data["data"]:
            return data["data"]["items"]
        if "items" in data:
            return data["items"]
        if "messages" in data:
            return data["messages"]
    raise ValueError(f"未能识别的飞书消息文件结构: {file_path}")


# ---------- 单条消息正文提取 ----------

def _extract_post_text(content_obj: dict) -> str:
    """post 富文本: content 是二维数组 [[段], [段], ...], 段是 {tag, text/user_id/...}"""
    parts: list[str] = []
    title = content_obj.get("title")
    if title:
        parts.append(str(title))
    for paragraph in content_obj.get("content", []) or []:
        line_parts: list[str] = []
        for node in paragraph or []:
            tag = node.get("tag")
            if tag == "text":
                line_parts.append(node.get("text", ""))
            elif tag == "a":
                line_parts.append(f"{node.get('text', '')}({node.get('href', '')})")
            elif tag == "at":
                line_parts.append(f"@{node.get('user_id', '')}")
            elif tag in ("img", "media", "file"):
                line_parts.append(f"[{tag}]")
            elif tag == "emotion":
                line_parts.append(f"[emoji:{node.get('key', '')}]")
            else:
                line_parts.append(node.get("text") or f"[{tag}]")
        if line_parts:
            parts.append("".join(line_parts))
    return "\n".join(parts).strip()


def extract_content(msg: dict) -> str:
    msg_type = msg.get("msg_type", "")
    body = msg.get("body") or {}
    raw = body.get("content", "")

    if isinstance(raw, dict):
        content_obj = raw
    elif isinstance(raw, str) and raw:
        try:
            content_obj = json.loads(raw)
        except json.JSONDecodeError:
            return raw
    else:
        return ""

    if msg_type == "text":
        return content_obj.get("text", "")
    if msg_type == "post":
        return _extract_post_text(content_obj)
    if msg_type == "image":
        return "[图片]"
    if msg_type == "file":
        return f"[文件:{content_obj.get('file_name', '')}]"
    if msg_type == "audio":
        return "[语音]"
    if msg_type == "sticker":
        return "[表情]"
    if msg_type == "share_chat":
        return "[分享群聊]"
    if msg_type == "share_user":
        return "[分享名片]"
    if msg_type == "interactive":
        return "[卡片]"
    return f"[{msg_type}]"


def normalize(messages: list[dict], sender_map: dict[str, str] | None) -> list[dict]:
    out: list[dict] = []
    for m in messages:
        if m.get("deleted"):
            continue
        sender = m.get("sender") or {}
        sid = sender.get("id") or sender.get("open_id") or ""
        display = (sender_map or {}).get(sid, sid) if sid else "unknown"
        ts_raw = m.get("create_time") or m.get("createTime") or ""
        try:
            ts_ms = int(ts_raw)
            ts = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S")
        except (TypeError, ValueError):
            ts = str(ts_raw)
        content = extract_content(m)
        if not content:
            continue
        out.append({
            "timestamp": ts,
            "sender_id": sid,
            "sender": display,
            "msg_type": m.get("msg_type", ""),
            "content": content,
        })
    return out


# ---------- 分析 (与 wechat_parser.analyze_messages 口径对齐) ----------

EMOJI_RE = re.compile(
    r"[\U0001F600-\U0001F64F\U0001F300-\U0001F5FF"
    r"\U0001F680-\U0001F6FF\U0001F1E0-\U0001F1FF"
    r"\U00002702-\U000027B0\U0000FE00-\U0000FE0F"
    r"\U0001F900-\U0001F9FF]+",
    re.UNICODE,
)
PARTICLE_RE = re.compile(r"[哈嗯哦噢嘿唉呜啊呀吧嘛呢吗么]+")


def analyze(messages: list[dict], target_identifier: str, target_open_id: str | None) -> dict:
    if target_open_id:
        target_msgs = [m for m in messages if m["sender_id"] == target_open_id]
    else:
        target_msgs = [m for m in messages if target_identifier and target_identifier in m["sender"]]
    other_msgs = [m for m in messages if m not in target_msgs]

    target_text = " ".join(m["content"] for m in target_msgs)

    particles: dict[str, int] = {}
    for p in PARTICLE_RE.findall(target_text):
        particles[p] = particles.get(p, 0) + 1
    top_particles = sorted(particles.items(), key=lambda x: -x[1])[:10]

    emojis: dict[str, int] = {}
    for e in EMOJI_RE.findall(target_text):
        emojis[e] = emojis.get(e, 0) + 1
    top_emojis = sorted(emojis.items(), key=lambda x: -x[1])[:10]

    lengths = [len(m["content"]) for m in target_msgs]
    avg_len = sum(lengths) / len(lengths) if lengths else 0.0

    punct = {
        "句号": target_text.count("。"),
        "感叹号": target_text.count("！") + target_text.count("!"),
        "问号": target_text.count("？") + target_text.count("?"),
        "省略号": target_text.count("...") + target_text.count("…"),
        "波浪号": target_text.count("～") + target_text.count("~"),
    }

    hour_counts = [0] * 24
    for m in target_msgs:
        try:
            hour = datetime.strptime(m["timestamp"], "%Y-%m-%d %H:%M:%S").hour
            hour_counts[hour] += 1
        except ValueError:
            continue

    return {
        "total_messages": len(messages),
        "target_messages": len(target_msgs),
        "other_messages": len(other_msgs),
        "top_particles": top_particles,
        "top_emojis": top_emojis,
        "avg_message_length": round(avg_len, 1),
        "message_style": "short_burst" if avg_len < 20 else "long_form",
        "punctuation_habits": punct,
        "active_hours": hour_counts,
        "sample_messages": [m["content"] for m in target_msgs[:50]],
    }


# ---------- 输出 ----------

def write_report(out_path: str, source: str, target: str, stats: dict) -> None:
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(f"# 飞书聊天记录分析 — {target}\n\n")
        f.write(f"来源文件: {source}\n")
        f.write(f"总消息数: {stats['total_messages']}\n")
        f.write(f"ta 的消息数: {stats['target_messages']}\n")
        f.write(f"其他人消息数: {stats['other_messages']}\n\n")

        if stats["top_particles"]:
            f.write("## 高频语气词\n")
            for w, c in stats["top_particles"]:
                f.write(f"- {w}: {c} 次\n")
            f.write("\n")

        if stats["top_emojis"]:
            f.write("## 高频 Emoji\n")
            for e, c in stats["top_emojis"]:
                f.write(f"- {e}: {c} 次\n")
            f.write("\n")

        f.write("## 标点习惯\n")
        for k, v in stats["punctuation_habits"].items():
            f.write(f"- {k}: {v} 次\n")
        f.write("\n")

        f.write("## 消息风格\n")
        f.write(f"- 平均消息长度: {stats['avg_message_length']} 字\n")
        f.write(
            f"- 风格: {'短句连发型' if stats['message_style'] == 'short_burst' else '长段落型'}\n\n"
        )

        f.write("## 活跃时段 (24h)\n")
        peak = max(range(24), key=lambda h: stats["active_hours"][h]) if any(stats["active_hours"]) else None
        if peak is not None:
            f.write(f"- 峰值小时: {peak}:00\n")
        for h, c in enumerate(stats["active_hours"]):
            if c:
                f.write(f"  - {h:02d}:00 — {c}\n")
        f.write("\n")

        if stats["sample_messages"]:
            f.write("## 消息样本 (前 50 条)\n")
            for i, msg in enumerate(stats["sample_messages"], 1):
                f.write(f"{i}. {msg}\n")


def main() -> None:
    ap = argparse.ArgumentParser(description="飞书聊天记录解析器")
    ap.add_argument("--file", required=True, help="输入 JSON 文件路径")
    ap.add_argument("--target-open-id", help="ta 的 open_id (ou_xxx), 精确匹配")
    ap.add_argument("--target-name", help="ta 的显示名, 需要配合 --sender-map")
    ap.add_argument("--sender-map", help="JSON 文件: {open_id: 显示名}")
    ap.add_argument("--output", required=True, help="输出 markdown 路径")
    ap.add_argument("--dump-normalized", help="可选: 把规整后的消息列表 dump 成 JSON")
    args = ap.parse_args()

    if not args.target_open_id and not args.target_name:
        print("错误: 需要 --target-open-id 或 --target-name 至少一个", file=sys.stderr)
        sys.exit(2)
    if not os.path.exists(args.file):
        print(f"错误: 文件不存在 {args.file}", file=sys.stderr)
        sys.exit(1)

    sender_map: dict[str, str] | None = None
    if args.sender_map:
        with open(args.sender_map, "r", encoding="utf-8") as f:
            sender_map = json.load(f)

    raw = load_raw(args.file)
    normalized = normalize(raw, sender_map)
    target_label = args.target_name or args.target_open_id
    stats = analyze(normalized, target_label, args.target_open_id)
    write_report(args.output, args.file, target_label, stats)

    if args.dump_normalized:
        os.makedirs(os.path.dirname(args.dump_normalized) or ".", exist_ok=True)
        with open(args.dump_normalized, "w", encoding="utf-8") as f:
            json.dump(normalized, f, ensure_ascii=False, indent=2)

    print(f"已分析 {stats['total_messages']} 条消息, ta 占 {stats['target_messages']} 条")
    print(f"报告: {args.output}")
    if args.dump_normalized:
        print(f"规整数据: {args.dump_normalized}")


if __name__ == "__main__":
    main()
