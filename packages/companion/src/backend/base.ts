import type { BackendMetadata, Message } from "@petchat/shared";

export interface ChatBackend {
  readonly metadata: BackendMetadata;
  history(limit?: number): Promise<Message[]>;
  /** Stream the reply as an async iterator of text chunks. */
  send(text: string): AsyncIterable<string>;
}
