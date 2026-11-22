import * as z from "zod";

/** What Claude returns for one recording. Keys match the iOS app's ExtractionResult. */
export const ExtractionSchema = z.object({
  client_name: z.string().nullable(),
  client_email: z.string().nullable(),
  client_phone: z.string().nullable(),
  job_address: z.string().nullable(),
  job_title: z.string().nullable(),
  items: z.array(
    z.object({
      description: z.string(),
      quantity: z.number(),
      unit_price_cents: z.number().int().nullable(),
      details: z.string().nullable(),
    }),
  ),
  notes: z.string().nullable(),
});

export type Extraction = z.infer<typeof ExtractionSchema>;

/** What the iOS app sends. */
export const ExtractionRequestSchema = z.object({
  transcript: z.string().min(1).max(20_000),
  existing_items: z.array(z.string().max(500)).max(200).default([]),
  known_clients: z.array(z.string().max(200)).max(1000).default([]),
});

export type ExtractionRequest = z.infer<typeof ExtractionRequestSchema>;
