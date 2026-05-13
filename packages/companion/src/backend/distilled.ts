import fs from "node:fs";
import path from "node:path";
import Anthropic from "@anthropic-ai/sdk";
import type { BackendMetadata, Message } from "@petchat/shared";
import type { ChatBackend } from "./base.js";
import { openDb } from "./sqlite.js";

const DEFAULT_MODEL = "claude-opus-4-5";
const SYSTEM_PROMPT_FILE = "SKILL.md";
const META_FILE = "meta.json";

export class DistilledBackend implements ChatBackend {
  readonly metadata: BackendMetadata;
  private systemPrompt: string;
  private db: ReturnType<typeof openDb>;
  private model: string;

  constructor(personaDir: string, opts: { model?: string; historyDb?: string } = {}) {
    if (!fs.existsSync(personaDir)) {
      throw new Error(`persona dir 不存在: ${personaDir}`);
    }
    const skillPath = path.join(personaDir, SYSTEM_PROMPT_FILE);
    if (!fs.existsSync(skillPath)) {
      throw new Error(`缺少 ${SYSTEM_PROMPT_FILE}: ${skillPath}`);
    }
    this.systemPrompt = fs.readFileSync(skillPath, "utf-8");

    const metaPath = path.join(personaDir, META_FILE);
    const meta: Record<string, unknown> = fs.existsSync(metaPath)
      ? JSON.parse(fs.readFileSync(metaPath, "utf-8"))
      : {};
    const slug = (meta.slug as string | undefined) ?? path.basename(personaDir);
    const name = (meta.name as string | undefined) ?? slug;

    this.metadata = {
      source: "distilled",
      displayName: name,
      personaSlug: slug,
      readOnly: false,
      notice: "这是基于聊天记录蒸馏的 AI 人格, 不是真人。",
    };
    this.model = opts.model ?? DEFAULT_MODEL;

    const dbPath = opts.historyDb ?? path.join(personaDir, "history.sqlite");
    this.db = openDb(dbPath);
    this.db.exec(
      `CREATE TABLE IF NOT EXISTS messages (
         id INTEGER PRIMARY KEY AUTOINCREMENT,
         role TEXT NOT NULL,
         content TEXT NOT NULL,
         ts TEXT NOT NULL
       )`,
    );
  }

  async history(limit = 50): Promise<Message[]> {
    const rows = this.db
      .prepare("SELECT role, content, ts FROM messages ORDER BY id DESC LIMIT ?")
      .all(limit) as { role: string; content: string; ts: string }[];
    return rows
      .reverse()
      .map((r) => ({
        role: r.role as Message["role"],
        content: r.content,
        timestamp: r.ts,
        source: "distilled" as const,
      }));
  }

  private append(role: Message["role"], content: string): void {
    const ts = new Date().toISOString();
    this.db
      .prepare("INSERT INTO messages(role, content, ts) VALUES(?, ?, ?)")
      .run(role, content, ts);
  }

  async *send(text: string): AsyncIterable<string> {
    this.append("user", text);

    const apiKey = process.env.ANTHROPIC_API_KEY;
    if (!apiKey) {
      const msg = "[未配置 ANTHROPIC_API_KEY, DistilledBackend 无法生成回复]";
      this.append("assistant", msg);
      yield msg;
      return;
    }

    const client = new Anthropic({ apiKey });
    const prior = await this.history(40);
    const apiMessages = prior
      .filter((m) => m.role === "user" || m.role === "assistant")
      .map((m) => ({ role: m.role as "user" | "assistant", content: m.content }));

    const collected: string[] = [];
    const stream = client.messages.stream({
      model: this.model,
      max_tokens: 1024,
      system: this.systemPrompt,
      messages: apiMessages,
    });

    for await (const event of stream) {
      if (
        event.type === "content_block_delta" &&
        event.delta.type === "text_delta"
      ) {
        collected.push(event.delta.text);
        yield event.delta.text;
      }
    }
    this.append("assistant", collected.join(""));
  }
}
