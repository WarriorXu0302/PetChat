import { z } from "zod";

export const SourceSchema = z.enum(["distilled", "feishu"]);
export type Source = z.infer<typeof SourceSchema>;

export const MessageRoleSchema = z.enum(["user", "assistant", "system"]);
export type MessageRole = z.infer<typeof MessageRoleSchema>;

export const MessageSchema = z.object({
  role: MessageRoleSchema,
  content: z.string(),
  timestamp: z.string(),
  source: SourceSchema.optional(),
});
export type Message = z.infer<typeof MessageSchema>;

export const BackendMetadataSchema = z.object({
  source: SourceSchema,
  displayName: z.string(),
  personaSlug: z.string().optional(),
  feishuChatId: z.string().optional(),
  readOnly: z.boolean().default(false),
  notice: z.string().optional(),
});
export type BackendMetadata = z.infer<typeof BackendMetadataSchema>;

export const ContactSchema = z.object({
  slug: z.string(),
  name: z.string(),
  hasDistilled: z.boolean().default(false),
  hasFeishu: z.boolean().default(false),
  feishuChatId: z.string().nullable().default(null),
});
export type Contact = z.infer<typeof ContactSchema>;
