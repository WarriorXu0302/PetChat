"""FeishuBackend: 通过飞书 Bot 与真人私聊的桥接

当前是骨架实现。完整闭环需要:
1. 自建飞书应用, 拿到 app_id / app_secret。
2. 配置事件订阅 URL, 接收 im.message.receive_v1。
3. 本地跑一个 webhook 服务接事件 → 写入下面的历史存储 → UI 拉取。
4. `send` 调 /open-apis/im/v1/messages 以 bot 身份发消息。

骨架部分仅把输入写本地 SQLite, 便于先把 UI 切换接通; 真正的 API 调用和
webhook 事件接入单独实现后再替换。
"""

from __future__ import annotations

import os
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import AsyncIterator

import urllib.error
import urllib.request
import json

from .base import BackendMetadata, ChatBackend, Message


TENANT_TOKEN_ENDPOINT = "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal"
SEND_MESSAGE_ENDPOINT = "https://open.feishu.cn/open-apis/im/v1/messages"


class FeishuBackend(ChatBackend):
    def __init__(
        self,
        contact_slug: str,
        *,
        chat_id: str,
        display_name: str,
        storage_dir: str | Path,
        app_id: str | None = None,
        app_secret: str | None = None,
    ):
        self._slug = contact_slug
        self._chat_id = chat_id
        self._name = display_name
        self._app_id = app_id or os.environ.get("FEISHU_APP_ID")
        self._app_secret = app_secret or os.environ.get("FEISHU_APP_SECRET")

        self._storage = Path(storage_dir)
        self._storage.mkdir(parents=True, exist_ok=True)
        self._db_path = self._storage / f"feishu-{contact_slug}.sqlite"
        self._init_db()

        self._token_cache: tuple[str, float] | None = None

    # ----- metadata -----

    @property
    def metadata(self) -> BackendMetadata:
        has_creds = bool(self._app_id and self._app_secret)
        notice = (
            "真人 · 通过飞书 Bot 中转。对方看到的是机器人身份。"
            if has_creds
            else "⚠️ 未配置 FEISHU_APP_ID / FEISHU_APP_SECRET, 当前只能看历史, 发消息会入列但不会真发。"
        )
        return BackendMetadata(
            source="feishu",
            display_name=self._name,
            persona_slug=None,
            feishu_chat_id=self._chat_id,
            read_only=not has_creds,
            notice=notice,
        )

    # ----- history -----

    def _init_db(self) -> None:
        with sqlite3.connect(self._db_path) as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    direction TEXT NOT NULL CHECK(direction IN ('in', 'out', 'pending')),
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    ts TEXT NOT NULL,
                    feishu_message_id TEXT
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
        return [Message(role=r[0], content=r[1], timestamp=r[2], source="feishu") for r in rows]

    def record_incoming(self, content: str, feishu_message_id: str | None = None) -> None:
        """Webhook 接收到对方消息时由事件处理器调用."""
        ts = datetime.now(tz=timezone.utc).astimezone().isoformat()
        with sqlite3.connect(self._db_path) as conn:
            conn.execute(
                "INSERT INTO messages(direction, role, content, ts, feishu_message_id) VALUES(?,?,?,?,?)",
                ("in", "assistant", content, ts, feishu_message_id),
            )

    # ----- send -----

    async def send(self, text: str) -> AsyncIterator[str]:
        ts = datetime.now(tz=timezone.utc).astimezone().isoformat()
        direction = "out" if (self._app_id and self._app_secret) else "pending"

        with sqlite3.connect(self._db_path) as conn:
            conn.execute(
                "INSERT INTO messages(direction, role, content, ts) VALUES(?,?,?,?)",
                (direction, "user", text, ts),
            )

        if direction == "pending":
            async def _skipped() -> AsyncIterator[str]:
                yield f"[未配置飞书凭证, 消息已入列但未发出: {text[:40]}]"

            return _skipped()

        try:
            feishu_message_id = self._send_to_feishu(text)

            async def _ok() -> AsyncIterator[str]:
                yield f"[已发送 · message_id={feishu_message_id}]"
                yield "\n对方回复会通过事件订阅推回, 请保持 webhook 服务运行。"

            return _ok()
        except Exception as exc:  # noqa: BLE001
            async def _fail() -> AsyncIterator[str]:
                yield f"[发送失败: {exc}]"

            return _fail()

    # ----- 飞书 API ----

    def _tenant_token(self) -> str:
        if self._token_cache and self._token_cache[1] > time.time() + 60:
            return self._token_cache[0]
        assert self._app_id and self._app_secret
        body = json.dumps({"app_id": self._app_id, "app_secret": self._app_secret}).encode("utf-8")
        req = urllib.request.Request(
            TENANT_TOKEN_ENDPOINT,
            data=body,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        if data.get("code") != 0:
            raise RuntimeError(f"获取 tenant_access_token 失败: {data}")
        token = data["tenant_access_token"]
        expire = time.time() + int(data.get("expire", 1800))
        self._token_cache = (token, expire)
        return token

    def _send_to_feishu(self, text: str) -> str:
        token = self._tenant_token()
        payload = {
            "receive_id": self._chat_id,
            "msg_type": "text",
            "content": json.dumps({"text": text}, ensure_ascii=False),
        }
        body = json.dumps(payload).encode("utf-8")
        url = f"{SEND_MESSAGE_ENDPOINT}?receive_id_type=chat_id"
        req = urllib.request.Request(
            url,
            data=body,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            raise RuntimeError(f"HTTP {exc.code}: {exc.read().decode('utf-8', errors='ignore')}") from exc
        if data.get("code") != 0:
            raise RuntimeError(f"飞书 send_message 失败: {data}")
        msg_id = data.get("data", {}).get("message_id", "")
        with sqlite3.connect(self._db_path) as conn:
            conn.execute(
                "UPDATE messages SET feishu_message_id = ? WHERE id = (SELECT MAX(id) FROM messages)",
                (msg_id,),
            )
        return msg_id
