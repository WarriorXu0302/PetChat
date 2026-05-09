"""Minimal CLI for the two-backend switch.

python -m companion.backend.cli list
python -m companion.backend.cli chat <slug> --source distilled
python -m companion.backend.cli chat <slug> --source feishu
python -m companion.backend.cli register-feishu <slug> <name> <chat_id>

Use Ctrl+D or type /quit to exit chat.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

from .registry import BackendRegistry


COMPANION_ROOT = Path(__file__).resolve().parents[1]


async def chat_loop(slug: str, source: str) -> None:
    reg = BackendRegistry(COMPANION_ROOT)
    try:
        backend = reg.get(slug, source)  # type: ignore[arg-type]
    except Exception as exc:  # noqa: BLE001
        print(f"启动后端失败: {exc}", file=sys.stderr)
        sys.exit(1)

    meta = backend.metadata
    print(f"--- {meta.display_name} ({meta.source}) ---")
    if meta.notice:
        print(meta.notice)
    print("最近历史:")
    history = await backend.history(limit=20)
    for m in history:
        tag = "你" if m.role == "user" else meta.display_name
        print(f"  [{tag}] {m.content}")
    print("(空行 / Ctrl+D 退出)")

    while True:
        try:
            line = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if not line or line in ("/quit", "/exit"):
            return

        stream = await backend.send(line)
        print(f"  [{meta.display_name}] ", end="", flush=True)
        async for chunk in stream:
            print(chunk, end="", flush=True)
        print()


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list")

    chat = sub.add_parser("chat")
    chat.add_argument("slug")
    chat.add_argument("--source", choices=["distilled", "feishu"], default="distilled")

    reg_fs = sub.add_parser("register-feishu")
    reg_fs.add_argument("slug")
    reg_fs.add_argument("name")
    reg_fs.add_argument("chat_id")

    args = ap.parse_args()
    reg = BackendRegistry(COMPANION_ROOT)

    if args.cmd == "list":
        for c in reg.list_contacts():
            flags = []
            if c.get("has_distilled"):
                flags.append("distilled")
            if c.get("has_feishu"):
                flags.append("feishu")
            print(f"- {c['slug']:<20} {c.get('name', ''):<16} [{','.join(flags) or 'empty'}]")
        return

    if args.cmd == "register-feishu":
        reg.register_feishu(args.slug, args.name, args.chat_id)
        print(f"已绑定 {args.slug} → chat_id={args.chat_id}")
        return

    if args.cmd == "chat":
        asyncio.run(chat_loop(args.slug, args.source))
        return


if __name__ == "__main__":
    main()
