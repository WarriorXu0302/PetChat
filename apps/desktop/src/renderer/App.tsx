import { useEffect, useState } from "react";
import type { BackendMetadata, Contact, Message, Source } from "@petchat/shared";
import { api } from "./api.js";

export function App() {
  const [contacts, setContacts] = useState<Contact[]>([]);
  const [activeSlug, setActiveSlug] = useState<string | null>(null);
  const [source, setSource] = useState<Source>("distilled");

  useEffect(() => {
    api.listContacts().then((cs) => {
      setContacts(cs);
      if (cs.length && !activeSlug) {
        setActiveSlug(cs[0].slug);
        setSource(cs[0].hasDistilled ? "distilled" : "feishu");
      }
    });
  }, []);

  const activeContact = contacts.find((c) => c.slug === activeSlug);

  return (
    <div className="app">
      <aside className="sidebar">
        <header>
          <h1>PetChat</h1>
          <button onClick={() => api.listContacts().then(setContacts)}>刷新</button>
        </header>
        <ul className="contacts">
          {contacts.length === 0 && <li className="empty">还没有联系人 — 先在 Claude Code 里跑 /distill-contact</li>}
          {contacts.map((c) => (
            <li
              key={c.slug}
              className={c.slug === activeSlug ? "active" : ""}
              onClick={() => setActiveSlug(c.slug)}
            >
              <div className="name">{c.name}</div>
              <div className="tags">
                {c.hasDistilled && <span className="tag">蒸馏</span>}
                {c.hasFeishu && <span className="tag">飞书</span>}
              </div>
            </li>
          ))}
        </ul>
      </aside>
      <main className="chat">
        {activeContact ? (
          <ChatPanel
            key={`${activeContact.slug}:${source}`}
            contact={activeContact}
            source={source}
            onSourceChange={setSource}
          />
        ) : (
          <div className="placeholder">选择左侧联系人, 或先在 Claude Code 里蒸馏一个。</div>
        )}
      </main>
    </div>
  );
}

function ChatPanel({
  contact,
  source,
  onSourceChange,
}: {
  contact: Contact;
  source: Source;
  onSourceChange: (s: Source) => void;
}) {
  const [meta, setMeta] = useState<BackendMetadata | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [draft, setDraft] = useState("");
  const [streaming, setStreaming] = useState(false);

  useEffect(() => {
    setMeta(null);
    setMessages([]);
    api.getMetadata(contact.slug, source).then(setMeta).catch((err) => {
      setMeta({
        source,
        displayName: contact.name,
        readOnly: true,
        notice: `无法加载: ${err.message}`,
      });
    });
    api.getHistory(contact.slug, source, 50).then(setMessages).catch(() => setMessages([]));
  }, [contact.slug, source]);

  const canDistilled = contact.hasDistilled;
  const canFeishu = contact.hasFeishu;

  function handleSend() {
    if (!draft.trim() || streaming || meta?.readOnly) return;
    const userMsg: Message = {
      role: "user",
      content: draft,
      timestamp: new Date().toISOString(),
      source,
    };
    const assistantMsg: Message = {
      role: "assistant",
      content: "",
      timestamp: new Date().toISOString(),
      source,
    };
    setMessages((prev) => [...prev, userMsg, assistantMsg]);
    const text = draft;
    setDraft("");
    setStreaming(true);

    api.send(
      contact.slug,
      source,
      text,
      (chunk) => {
        setMessages((prev) => {
          const next = [...prev];
          const last = next[next.length - 1];
          next[next.length - 1] = { ...last, content: last.content + chunk };
          return next;
        });
      },
      () => setStreaming(false),
      (err) => {
        setMessages((prev) => {
          const next = [...prev];
          const last = next[next.length - 1];
          next[next.length - 1] = { ...last, content: last.content + `\n[错误: ${err}]` };
          return next;
        });
        setStreaming(false);
      },
    );
  }

  return (
    <div className="chat-panel">
      <header>
        <div className="title">{contact.name}</div>
        <div className="source-switch">
          <button
            className={source === "distilled" ? "active" : ""}
            disabled={!canDistilled}
            onClick={() => onSourceChange("distilled")}
          >
            蒸馏人格
          </button>
          <button
            className={source === "feishu" ? "active" : ""}
            disabled={!canFeishu}
            onClick={() => onSourceChange("feishu")}
          >
            真人 · 飞书
          </button>
        </div>
      </header>
      {meta?.notice && <div className="notice">{meta.notice}</div>}
      <div className="messages">
        {messages.map((m, i) => (
          <div key={i} className={`msg ${m.role}`}>
            <div className="role">{m.role === "user" ? "你" : contact.name}</div>
            <div className="content">{m.content || (streaming && i === messages.length - 1 ? "…" : "")}</div>
          </div>
        ))}
      </div>
      <footer>
        <textarea
          value={draft}
          disabled={meta?.readOnly || streaming}
          placeholder={meta?.readOnly ? "当前后端只读" : "输入消息, Enter 发送 / Shift+Enter 换行"}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              handleSend();
            }
          }}
        />
        <button onClick={handleSend} disabled={!draft.trim() || streaming || meta?.readOnly}>
          发送
        </button>
      </footer>
    </div>
  );
}
