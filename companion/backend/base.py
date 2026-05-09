"""ChatBackend 抽象接口

UI 侧只依赖这个接口。DistilledBackend 和 FeishuBackend 是两种实现,
用户在桌面助手里切换 "蒸馏人格 / 真人" 时, 实际就是切实例。
"""

from __future__ import annotations

import abc
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import AsyncIterator, Literal


Source = Literal["distilled", "feishu"]


@dataclass
class Message:
    role: Literal["user", "assistant", "system"]
    content: str
    timestamp: str = field(
        default_factory=lambda: datetime.now(tz=timezone.utc).astimezone().isoformat()
    )
    source: Source | None = None


@dataclass
class BackendMetadata:
    source: Source
    display_name: str
    persona_slug: str | None = None
    feishu_chat_id: str | None = None
    read_only: bool = False
    notice: str | None = None


class ChatBackend(abc.ABC):
    """所有聊天后端的统一接口."""

    @property
    @abc.abstractmethod
    def metadata(self) -> BackendMetadata: ...

    @abc.abstractmethod
    async def history(self, limit: int = 50) -> list[Message]:
        """返回最近 N 条消息, 按时间升序."""

    @abc.abstractmethod
    async def send(self, text: str) -> AsyncIterator[str]:
        """发送一条用户消息, 流式返回对方回复 token.

        返回一个 async generator: `async for chunk in backend.send(text): ...`
        """
