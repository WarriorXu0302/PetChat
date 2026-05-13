import type { BackendMetadata, Contact, Message, Source } from "@petchat/shared";

export interface PetChatAPI {
  listContacts(): Promise<Contact[]>;
  registerFeishu(slug: string, name: string, chatId: string): Promise<Contact[]>;
  getMetadata(slug: string, source: Source): Promise<BackendMetadata>;
  getHistory(slug: string, source: Source, limit?: number): Promise<Message[]>;
  send(
    slug: string,
    source: Source,
    text: string,
    onChunk: (chunk: string) => void,
    onEnd: () => void,
    onError: (err: string) => void,
  ): void;
}

declare global {
  interface Window {
    petchat: PetChatAPI;
  }
}

export const api: PetChatAPI = window.petchat;
