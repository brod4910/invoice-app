import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import * as z from "zod";

/** What the app sends: the client name Dad said, and people from his mail who might be them. */
export const MatchRequestSchema = z.object({
  client_name: z.string().min(1).max(200),
  job_address: z.string().max(300).default(""),
  people: z
    .array(
      z.object({
        email: z.string().max(320),
        name: z.string().max(200).default(""),
        /** How many emails Dad has sent them. */
        sent_count: z.number().int().min(0).default(0),
        /** Subject and Gmail snippet of emails that mention the client, if any. */
        snippets: z.array(z.string().max(600)).max(5).default([]),
      }),
    )
    .max(150),
});

export type MatchRequest = z.infer<typeof MatchRequestSchema>;

export const MatchSchema = z.object({
  matches: z.array(
    z.object({
      email: z.string(),
      /** "sure": clearly works for or is the client. "maybe": likely, Dad should confirm. */
      confidence: z.enum(["sure", "maybe"]),
    }),
  ),
});

export type Match = z.infer<typeof MatchSchema>;

export const MATCH_SYSTEM_PROMPT = `You help a small maintenance business owner find the email address of a client for an invoice.
The client name was spoken aloud and turned into text, so it may be misspelled, shortened, or missing words like "Company" or "LLC".
You get people from his mailbox: their email, display name, how often he emails them, and snippets of emails that mention the client.

Return the people who are the client or who work for the client. Use every clue: signatures and snippets ("Veronica, Crown Management Co."), company names, email domains (including abbreviations, initials and rebrands, e.g. Crown Management at cmc.rent), and the job address.
- "sure": the evidence clearly ties this person to the client.
- "maybe": plausible but not certain.
Leave out anyone who only happens to appear in the same email, such as suppliers, newsletters, or the owner's family.
Only return emails from the list you were given. Return an empty list if nobody fits.`;

export function buildMatchMessage(req: MatchRequest): string {
  const people = req.people
    .map((p, i) => {
      const lines = [`${i + 1}. ${p.name || "(no name)"} <${p.email}>, emailed ${p.sent_count} times`];
      for (const s of p.snippets) lines.push(`   - ${s}`);
      return lines.join("\n");
    })
    .join("\n");
  return `Client name (spoken): ${req.client_name}\nJob address: ${req.job_address || "(unknown)"}\n\nPeople:\n${people || "(none)"}`;
}

export type Matcher = (req: MatchRequest, env: { ANTHROPIC_API_KEY: string }) => Promise<Match>;

export const matchWithClaude: Matcher = async (req, env) => {
  if (req.people.length === 0) return { matches: [] };
  const client = new Anthropic({ apiKey: env.ANTHROPIC_API_KEY });
  const response = await client.beta.messages.parse({
    // Sonnet is plenty for matching names to emails, and cheaper than Opus (used for line items).
    model: "claude-sonnet-5-5",
    max_tokens: 4000,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    output_config: { effort: "low", format: betaZodOutputFormat(MatchSchema) },
    system: MATCH_SYSTEM_PROMPT,
    messages: [{ role: "user", content: buildMatchMessage(req) }],
  });
  if (!response.parsed_output) return { matches: [] };
  // Never trust an address that wasn't sent in.
  const allowed = new Set(req.people.map((p) => p.email.toLowerCase()));
  return {
    matches: response.parsed_output.matches.filter((m) => allowed.has(m.email.toLowerCase())),
  };
};
