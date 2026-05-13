import type { BackendMetadata, Message } from "@petchat/shared";
import type { ChatBackend } from "./base.js";
import { openDb } from "./sqlite.js";
import path from "node:path";

const TENANT_TOKEN_ENDPOINT =
  "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal";
const SEND_MESSAGE_ENDPOINT =
  "https://open.feishu.cn/open-apis/im/v1/messages";

export interface FeishuBackendOptions {
  contactSlug: string;
  chatId: string;
  displayName: string;
  storageDir: string;
  appId?: string;
  appSecret?: string;
}

export class FeishuBackend implements ChatBackend {
  readonly metadata: BackendMetadata;
  private db: ReturnType<typeof openDb>;
  private appId?: string;
  private appSecret?: string;
  private chatId: string;
  private tokenCache: { token: string; expiresAt: number } | null = null;

  constructor(opts: FeishuBackendOptions) {
    this.appId = opts.appId ?? process.env.FEISHU_APP_ID;
    this.appSecret = opts.appSecret ?? process.env.FEISHU_APP_SECRET;
    this.chatId = opts.chatId;

    const hasCreds = !!(this.appId && this.appSecret);
    this.metadata = {
      source: "feishu",
      displayName: opts.displayName,
      feishuChatId: opts.chatId,
      readOnly: !hasCreds,
      notice: hasCreds
        ? "真人 · 通过飞书 Bot 中转。对方看到的是机器人身份。"
        : "⚠️ 未配置 FEISHU_APP_ID / FEISHU_APP_SECRET, 当前只能看历史, 发消息会入列但不会真发。",
    };

    const dbPath = path.join(opts.storageDir, `feishu-${opts.contactSlug}.sqlite`);
    this.db = openDb(dbPath);
    this.db.exec(
      `CREATE TABLE IF NOT EXISTS messages (
         id INTEGER PRIMARY KEY AUTOINCREMENT,
         direction TEXT NOT NULL CHECK(direction IN ('in','out','pending')),
         role TEXT NOT NULL,
         content TEXT NOT NULL,
         ts TEXT NOT NULL,
         feishu_message_id TEXT
       )`,
    );
  }

  async history(limit = 50): Promise<Message[]> {
    const rows = this.db
      .prepare("SELECT role, content, ts FROM messages ORDER BY id DESC LIMIT ?")
      .all(limit) as { role: string; content: string; ts: string }[];
    return rows.reverse().map((r) => ({
      role: r.role as Message["role"],
      content: r.content,
      timestamp: r.ts,
      source: "feishu" as const,
    }));
  }

  /** Called by the webhook receiver when ta replies. */
  recordIncoming(content: string, feishuMessageId?: string): void {
    const ts = new Date().toISOString();
    this.db
      .prepare(
        "INSERT INTO messages(direction, role, content, ts, feishu_message_id) VALUES(?,?,?,?,?)",
      )
      .run("in", "assistant", content, ts, feishuMessageId ?? null);
  }

  async *send(text: string): AsyncIterable<string> {
    const ts = new Date().toISOString();
    const direction = this.appId && this.appSecret ? "out" : "pending";
    this.db
      .prepare(
        "INSERT INTO messages(direction, role, content, ts) VALUES(?,?,?,?)",
      )
      .run(direction, "user", text, ts);

    if (direction === "pending") {
      yield `[未配置飞书凭证, 消息已入列但未发出: ${text.slice(0, 40)}]`;
      return;
    }

    try {
      const messageId = await this.sendToFeishu(text);
      yield `[已发送 · message_id=${messageId}]`;
      yield "\n对方回复会通过事件订阅推回, 请保持 webhook 服务运行。";
    } catch (err) {
      yield `[发送失败: ${(err as Error).message}]`;
    }
  }

  // ---------- Feishu API ----------

  private async tenantToken(): Promise<string> {
    if (this.tokenCache && this.tokenCache.expiresAt > Date.now() + 60_000) {
      return this.tokenCache.token;
    }
    const resp = await fetch(TENANT_TOKEN_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ app_id: this.appId, app_secret: this.appSecret }),
    });
    const data = (await resp.json()) as {
      code: number;
      tenant_access_token?: string;
      expire?: number;
    };
    if (data.code !== 0 || !data.tenant_access_token) {
      throw new Error(`获取 tenant_access_token 失败: ${JSON.stringify(data)}`);
    }
    this.tokenCache = {
      token: data.tenant_access_token,
      expiresAt: Date.now() + (data.expire ?? 1800) * 1000,
    };
    return data.tenant_access_token;
  }

  private async sendToFeishu(text: string): Promise<string> {
    const token = await this.tenantToken();
    const url = `${SEND_MESSAGE_ENDPOINT}?receive_id_type=chat_id`;
    const resp = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        receive_id: this.chatId,
        msg_type: "text",
        content: JSON.stringify({ text }),
      }),
    });
    const data = (await resp.json()) as {
      code: number;
      data?: { message_id?: string };
      msg?: string;
    };
    if (data.code !== 0) {
      throw new Error(`飞书 send_message 失败: ${JSON.stringify(data)}`);
    }
    const msgId = data.data?.message_id ?? "";
    this.db
      .prepare(
        "UPDATE messages SET feishu_message_id = ? WHERE id = (SELECT MAX(id) FROM messages)",
      )
      .run(msgId);
    return msgId;
  }
}
