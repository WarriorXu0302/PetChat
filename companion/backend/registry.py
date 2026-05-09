"""BackendRegistry: 按 contact slug + source 选后端.

桌面 UI 的"蒸馏人格 / 真人"切换就是调 `get(slug, source)` 换实例。
每个 contact 可以同时拥有两个后端实例, 但两条对话历史存在不同的 sqlite 里,
不会互相污染。
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Literal

from .base import ChatBackend
from .distilled import DistilledBackend
from .feishu import FeishuBackend


Source = Literal["distilled", "feishu"]


class BackendRegistry:
    def __init__(self, companion_root: str | Path):
        self.root = Path(companion_root)
        self.personas_dir = self.root / "personas"
        self.feishu_storage = self.root / "runtime" / "feishu"
        self.contacts_index = self.root / "runtime" / "contacts.json"

        self._cache: dict[tuple[str, Source], ChatBackend] = {}

    def list_contacts(self) -> list[dict]:
        """列出所有联系人. 索引由 contacts.json 维护; 没有就扫 personas/."""
        if self.contacts_index.exists():
            return json.loads(self.contacts_index.read_text(encoding="utf-8"))

        out: list[dict] = []
        if self.personas_dir.exists():
            for d in sorted(self.personas_dir.iterdir()):
                meta = d / "meta.json"
                if meta.exists():
                    data = json.loads(meta.read_text(encoding="utf-8"))
                    out.append(
                        {
                            "slug": data.get("slug", d.name),
                            "name": data.get("name", d.name),
                            "has_distilled": True,
                            "has_feishu": False,
                            "feishu_chat_id": None,
                        }
                    )
        return out

    def register_feishu(self, slug: str, name: str, chat_id: str) -> None:
        """把一个 contact 的飞书 chat_id 记下来, 下次 get(slug, 'feishu') 用它."""
        contacts = self.list_contacts()
        found = False
        for c in contacts:
            if c["slug"] == slug:
                c["has_feishu"] = True
                c["feishu_chat_id"] = chat_id
                c["name"] = name
                found = True
                break
        if not found:
            contacts.append(
                {
                    "slug": slug,
                    "name": name,
                    "has_distilled": (self.personas_dir / slug / "SKILL.md").exists(),
                    "has_feishu": True,
                    "feishu_chat_id": chat_id,
                }
            )
        self.contacts_index.parent.mkdir(parents=True, exist_ok=True)
        self.contacts_index.write_text(json.dumps(contacts, ensure_ascii=False, indent=2), encoding="utf-8")

    def get(self, slug: str, source: Source) -> ChatBackend:
        key = (slug, source)
        if key in self._cache:
            return self._cache[key]

        if source == "distilled":
            backend: ChatBackend = DistilledBackend(self.personas_dir / slug)
        elif source == "feishu":
            contact = next((c for c in self.list_contacts() if c["slug"] == slug), None)
            if not contact or not contact.get("feishu_chat_id"):
                raise ValueError(f"联系人 {slug} 未绑定飞书 chat_id, 先调 register_feishu")
            backend = FeishuBackend(
                contact_slug=slug,
                chat_id=contact["feishu_chat_id"],
                display_name=contact.get("name", slug),
                storage_dir=self.feishu_storage,
            )
        else:
            raise ValueError(f"未知 source: {source}")

        self._cache[key] = backend
        return backend
