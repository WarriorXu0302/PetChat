import { contextBridge, ipcRenderer } from "electron";
import type { BackendMetadata, Contact, Message, Source } from "@petchat/shared";

let channelSeq = 0;

const api = {
  listContacts: (): Promise<Contact[]> => ipcRenderer.invoke("contacts:list"),

  registerFeishu: (slug: string, name: string, chatId: string): Promise<Contact[]> =>
    ipcRenderer.invoke("contacts:registerFeishu", slug, name, chatId),

  getMetadata: (slug: string, source: Source): Promise<BackendMetadata> =>
    ipcRenderer.invoke("backend:metadata", slug, source),

  getHistory: (slug: string, source: Source, limit = 50): Promise<Message[]> =>
    ipcRenderer.invoke("backend:history", slug, source, limit),

  send: (
    slug: string,
    source: Source,
    text: string,
    onChunk: (chunk: string) => void,
    onEnd: () => void,
    onError: (err: string) => void,
  ): void => {
    const channelId = `ch-${++channelSeq}`;
    const handler = (_e: unknown, payload: { type: string; chunk?: string; error?: string }) => {
      if (payload.type === "chunk" && payload.chunk != null) onChunk(payload.chunk);
      else if (payload.type === "end") {
        ipcRenderer.removeListener(`backend:stream:${channelId}`, handler);
        onEnd();
      } else if (payload.type === "error") {
        ipcRenderer.removeListener(`backend:stream:${channelId}`, handler);
        onError(payload.error ?? "unknown error");
      }
    };
    ipcRenderer.on(`backend:stream:${channelId}`, handler);
    ipcRenderer.send("backend:send", channelId, slug, source, text);
  },
};

contextBridge.exposeInMainWorld("petchat", api);

export type PetChatAPI = typeof api;
