import { z } from "zod";

export const PersonaMetaSchema = z.object({
  slug: z.string(),
  name: z.string(),
  createdAt: z.string(),
  updatedAt: z.string(),
  version: z.string().default("v1"),
  profile: z
    .object({
      relation: z.string().optional(),
      context: z.string().optional(),
      knownDuration: z.string().optional(),
      occupation: z.string().optional(),
      mbti: z.string().optional(),
      zodiac: z.string().optional(),
    })
    .default({}),
  tags: z
    .object({
      personality: z.array(z.string()).default([]),
      speechStyle: z.string().optional(),
    })
    .default({ personality: [] }),
  impression: z.string().optional(),
  sources: z
    .array(
      z.object({
        kind: z.string(),
        path: z.string(),
        messageCount: z.number().optional(),
      }),
    )
    .default([]),
  correctionsCount: z.number().default(0),
});
export type PersonaMeta = z.infer<typeof PersonaMetaSchema>;
