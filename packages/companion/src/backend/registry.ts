import fs from "node:fs";
import path from "node:path";
import type { Contact, Source } from "@petchat/shared";
import type { ChatBackend } from "./base.js";
import { DistilledBackend } from "./distilled.js";
import { FeishuBackend } from "./feishu.js";

/**
 * BackendRegistry resolves (slug, source) pairs into backend instances.
 * Two backends for the same slug keep history in separate sqlite files
 * so the distilled conversation and the real Feishu relay don't pollute
 * each other.
 */
export class BackendRegistry {
  readonly root: string;
  readonly personasDir: string;
  readonly feishuStorage: string;
  readonly contactsIndex: string;
  private cache = new Map<string, ChatBackend>();

  constructor(companionRoot: string) {
    this.root = companionRoot;
    this.personasDir = path.join(companionRoot, "personas");
    this.feishuStorage = path.join(companionRoot, "runtime", "feishu");
    this.contactsIndex = path.join(companionRoot, "runtime", "contacts.json");
  }

  listContacts(): Contact[] {
    if (fs.existsSync(this.contactsIndex)) {
      return JSON.parse(fs.readFileSync(this.contactsIndex, "utf-8")) as Contact[];
    }
    if (!fs.existsSync(this.personasDir)) return [];
    const out: Contact[] = [];
    for (const d of fs.readdirSync(this.personasDir).sort()) {
      const metaPath = path.join(this.personasDir, d, "meta.json");
      if (!fs.existsSync(metaPath)) continue;
      const meta = JSON.parse(fs.readFileSync(metaPath, "utf-8")) as {
        slug?: string;
        name?: string;
      };
      out.push({
        slug: meta.slug ?? d,
        name: meta.name ?? d,
        hasDistilled: true,
        hasFeishu: false,
        feishuChatId: null,
      });
    }
    return out;
  }

  registerFeishu(slug: string, name: string, chatId: string): void {
    const contacts = this.listContacts();
    const existing = contacts.find((c) => c.slug === slug);
    if (existing) {
      existing.hasFeishu = true;
      existing.feishuChatId = chatId;
      existing.name = name;
    } else {
      contacts.push({
        slug,
        name,
        hasDistilled: fs.existsSync(path.join(this.personasDir, slug, "SKILL.md")),
        hasFeishu: true,
        feishuChatId: chatId,
      });
    }
    fs.mkdirSync(path.dirname(this.contactsIndex), { recursive: true });
    fs.writeFileSync(
      this.contactsIndex,
      JSON.stringify(contacts, null, 2),
      "utf-8",
    );
  }

  get(slug: string, source: Source): ChatBackend {
    const key = `${slug}:${source}`;
    const cached = this.cache.get(key);
    if (cached) return cached;

    let backend: ChatBackend;
    if (source === "distilled") {
      backend = new DistilledBackend(path.join(this.personasDir, slug));
    } else {
      const contact = this.listContacts().find((c) => c.slug === slug);
      if (!contact || !contact.feishuChatId) {
        throw new Error(`联系人 ${slug} 未绑定飞书 chat_id, 先调用 registerFeishu`);
      }
      backend = new FeishuBackend({
        contactSlug: slug,
        chatId: contact.feishuChatId,
        displayName: contact.name ?? slug,
        storageDir: this.feishuStorage,
      });
    }
    this.cache.set(key, backend);
    return backend;
  }
}
