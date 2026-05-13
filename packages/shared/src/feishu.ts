import { z } from "zod";

/** Feishu IM message envelope (subset we care about). */
export const FeishuSenderSchema = z.object({
  id: z.string().optional(),
  open_id: z.string().optional(),
  sender_type: z.string().optional(),
});

export const FeishuMessageSchema = z.object({
  message_id: z.string().optional(),
  chat_id: z.string().optional(),
  msg_type: z.string(),
  create_time: z.union([z.string(), z.number()]).optional(),
  deleted: z.boolean().optional(),
  sender: FeishuSenderSchema.optional(),
  body: z
    .object({
      content: z.union([z.string(), z.record(z.any())]).optional(),
    })
    .optional(),
});
export type FeishuMessage = z.infer<typeof FeishuMessageSchema>;

/** Accepts: raw Bot API response, wrapper objects, or flat arrays. */
export const FeishuPayloadSchema = z.union([
  z.array(FeishuMessageSchema),
  z.object({ items: z.array(FeishuMessageSchema) }),
  z.object({ messages: z.array(FeishuMessageSchema) }),
  z.object({
    data: z.object({ items: z.array(FeishuMessageSchema) }),
  }),
]);
export type FeishuPayload = z.infer<typeof FeishuPayloadSchema>;

/** Our normalized form, compatible with wechat parser output. */
export const NormalizedMessageSchema = z.object({
  timestamp: z.string(),
  senderId: z.string(),
  sender: z.string(),
  msgType: z.string(),
  content: z.string(),
});
export type NormalizedMessage = z.infer<typeof NormalizedMessageSchema>;
