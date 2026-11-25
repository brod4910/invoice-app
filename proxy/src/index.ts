import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { SYSTEM_PROMPT, buildUserMessage } from "./prompt";
import { MatchRequestSchema, matchWithClaude, type Matcher } from "./match";
import { ExtractionRequestSchema, ExtractionSchema, type Extraction, type ExtractionRequest } from "./schema";

export interface Env {
  ANTHROPIC_API_KEY: string;
  APP_TOKEN: string;
}

export type Extractor = (req: ExtractionRequest, env: Env) => Promise<Extraction>;

/** Calls Claude with structured output so the reply always matches ExtractionSchema. */
export const extractWithClaude: Extractor = async (req, env) => {
  const client = new Anthropic({ apiKey: env.ANTHROPIC_API_KEY });
  const response = await client.beta.messages.parse({
    model: "claude-opus-5-5",
    max_tokens: 16000,
    // If a safety classifier declines, the API retries on its recommended fallback model.
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    output_config: {
      effort: "medium",
      format: betaZodOutputFormat(ExtractionSchema),
    },
    system: SYSTEM_PROMPT,
    messages: [{ role: "user", content: buildUserMessage(req) }],
  });

  if (response.stop_reason === "refusal") {
    throw new HttpError(422, "The transcript could not be processed.");
  }
  if (response.stop_reason === "max_tokens" || !response.parsed_output) {
    throw new HttpError(502, "The model did not return a complete result.");
  }
  return response.parsed_output;
};

export class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}

export async function handleRequest(
  request: Request,
  env: Env,
  extract: Extractor = extractWithClaude,
  match: Matcher = matchWithClaude,
): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname !== "/extract" && url.pathname !== "/match-email") return json({ error: "Not found" }, 404);
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);

  if (!env.APP_TOKEN || !tokensMatch(request.headers.get("Authorization"), `Bearer ${env.APP_TOKEN}`)) {
    return json({ error: "Unauthorized" }, 401);
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Body must be JSON" }, 400);
  }
  try {
    if (url.pathname === "/match-email") {
      const parsed = MatchRequestSchema.safeParse(body);
      if (!parsed.success) return json({ error: "Invalid request", issues: parsed.error.issues }, 400);
      return json(await match(parsed.data, env), 200);
    }
    const parsed = ExtractionRequestSchema.safeParse(body);
    if (!parsed.success) return json({ error: "Invalid request", issues: parsed.error.issues }, 400);
    return json(await extract(parsed.data, env), 200);
  } catch (err) {
    if (err instanceof HttpError) return json({ error: err.message }, err.status);
    if (err instanceof Anthropic.RateLimitError) return json({ error: "Busy, try again shortly" }, 503);
    if (err instanceof Anthropic.APIError) return json({ error: "Upstream error" }, 502);
    console.error(err);
    return json({ error: "Internal error" }, 500);
  }
}

function json(value: unknown, status: number): Response {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
}

/** Length-independent comparison so the token can't be guessed by timing. */
function tokensMatch(given: string | null, expected: string): boolean {
  if (!given) return false;
  const a = new TextEncoder().encode(given);
  const b = new TextEncoder().encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) diff |= (a[i] ?? 0) ^ b[i];
  return diff === 0;
}

export default {
  fetch: (request: Request, env: Env) => handleRequest(request, env),
};
