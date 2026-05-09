"""DistilledBackend: 读 companion/personas/{slug}/SKILL.md 当 system prompt, 调 Claude API."""

from __future__ import annotations

import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import AsyncIterator

from .base import BackendMetadata, ChatBackend, Message


DEFAULT_MODEL = "claude-opus-4-7"
SYSTEM_PROMPT_FILE = "SKILL.md"
META_FILE = "meta.json"


class DistilledBackend(ChatBackend):
    def __init__(
        self,
        persona_dir: str | Path,
        *,
        model: str = DEFAULT_MODEL,
        history_db: str | Path | None = None,
    ):
        self.persona_dir = Path(persona_dir)
        if not self.persona_dir.exists():
            raise FileNotFoundError(f"persona dir 不存在: {self.persona_dir}")

        skill_path = self.persona_dir / SYSTEM_PROMPT_FILE
        if not skill_path.exists():
            raise FileNotFoundError(
                f"缺少 {SYSTEM_PROMPT_FILE}, 请先跑 distill-contact 生成人格"
            )
        self._system_prompt = skill_path.read_text(encoding="utf-8")

        meta_path = self.persona_dir / META_FILE
        self._meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else {}

        self._slug = self._meta.get("slug") or self.persona_dir.name
        self._name = self._meta.get("name", self._slug)
        self.model = model

        self._db_path = Path(history_db) if history_db else self.persona_dir / "history.sqlite"
        self._init_db()

    # ----- metadata / history -----

    @property
    def metadata(self) -> BackendMetadata:
        return BackendMetadata(
            source="distilled",
            display_name=self._name,
            persona_slug=self._slug,
            read_only=False,
            notice="这是基于聊天记录蒸馏的 AI 人格, 不是真人。",
        )

    def _init_db(self) -> None:
        with sqlite3.connect(self._db_path) as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    ts TEXT NOT NULL
                )
                """
            )

    async def history(self, limit: int = 50) -> list[Message]:
        with sqlite3.connect(self._db_path) as conn:
            rows = conn.execute(
                "SELECT role, content, ts FROM messages ORDER BY id DESC LIMIT ?",
                (limit,),
            ).fetchall()
        rows.reverse()
        return [Message(role=r[0], content=r[1], timestamp=r[2], source="distilled") for r in rows]

    def _append(self, role: str, content: str) -> None:
        ts = datetime.now(tz=timezone.utc).astimezone().isoformat()
        with sqlite3.connect(self._db_path) as conn:
            conn.execute(
                "INSERT INTO messages(role, content, ts) VALUES(?, ?, ?)",
                (role, content, ts),
            )

    # ----- send -----

    async def send(self, text: str) -> AsyncIterator[str]:
        self._append("user", text)

        api_key = os.environ.get("ANTHROPIC_API_KEY")
        if not api_key:
            msg = "[未配置 ANTHROPIC_API_KEY, DistilledBackend 无法生成回复]"
            self._append("assistant", msg)

            async def _err() -> AsyncIterator[str]:
                yield msg

            return _err()

        try:
            from anthropic import AsyncAnthropic
        except ImportError:
            msg = "[缺少 anthropic 依赖: pip install anthropic]"
            self._append("assistant", msg)

            async def _err() -> AsyncIterator[str]:
                yield msg

            return _err()

        client = AsyncAnthropic(api_key=api_key)
        prior = await self.history(limit=40)
        api_messages = [{"role": m.role, "content": m.content} for m in prior if m.role in ("user", "assistant")]

        async def _stream() -> AsyncIterator[str]:
            collected: list[str] = []
            async with client.messages.stream(
                model=self.model,
                max_tokens=1024,
                system=self._system_prompt,
                messages=api_messages,
            ) as stream:
                async for chunk in stream.text_stream:
                    collected.append(chunk)
                    yield chunk
            self._append("assistant", "".join(collected))

        return _stream()
