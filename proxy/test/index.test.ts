import { describe, expect, it } from "vitest";
import { handleRequest, HttpError, type Env, type Extractor } from "../src/index";
import { buildUserMessage } from "../src/prompt";
import { ExtractionSchema } from "../src/schema";

const env: Env = { ANTHROPIC_API_KEY: "test", APP_TOKEN: "secret-token" };

const sample = {
  client_name: "Mary Johnson",
  client_email: "mary@example.com",
  client_phone: null,
  job_address: "12 Oak St",
  job_title: "Fence repair",
  items: [{ description: "Replace fence boards", quantity: 12, unit_price_cents: 1500, details: "Cedar" }],
  notes: null,
};

const fakeExtract: Extractor = async () => sample;

function req(body: unknown, token = "secret-token", path = "/extract"): Request {
  return new Request(`https://example.com${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

describe("handleRequest", () => {
  it("returns extraction for a valid request", async () => {
    const res = await handleRequest(req({ transcript: "fixed the fence" }), env, fakeExtract);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual(sample);
  });

  it("rejects a wrong token", async () => {
    const res = await handleRequest(req({ transcript: "x" }, "nope"), env, fakeExtract);
    expect(res.status).toBe(401);
  });

  it("rejects when no token is configured", async () => {
    const res = await handleRequest(req({ transcript: "x" }, ""), { ...env, APP_TOKEN: "" }, fakeExtract);
    expect(res.status).toBe(401);
  });

  it("rejects bad JSON and empty transcripts", async () => {
    expect((await handleRequest(req("{not json"), env, fakeExtract)).status).toBe(400);
    expect((await handleRequest(req({ transcript: "" }), env, fakeExtract)).status).toBe(400);
  });

  it("404s other paths", async () => {
    expect((await handleRequest(req({ transcript: "x" }, "secret-token", "/other"), env, fakeExtract)).status).toBe(404);
  });

  it("maps extractor HttpErrors to their status", async () => {
    const failing: Extractor = async () => {
      throw new HttpError(422, "nope");
    };
    expect((await handleRequest(req({ transcript: "x" }), env, failing)).status).toBe(422);
  });

  it("passes defaults for optional lists", async () => {
    let seen: unknown;
    const spy: Extractor = async (r) => {
      seen = r;
      return sample;
    };
    await handleRequest(req({ transcript: "x" }), env, spy);
    expect(seen).toEqual({ transcript: "x", existing_items: [], known_clients: [] });
  });
});

describe("schema and prompt", () => {
  it("accepts a null price", () => {
    const parsed = ExtractionSchema.parse({
      ...sample,
      items: [{ description: "Haul debris", quantity: 1, unit_price_cents: null, details: null }],
    });
    expect(parsed.items[0].unit_price_cents).toBeNull();
  });

  it("includes known clients and existing items only when present", () => {
    const withAll = buildUserMessage({ transcript: "t", existing_items: ["Paint door"], known_clients: ["Mary Johnson"] });
    expect(withAll).toContain("<known_clients>\nMary Johnson");
    expect(withAll).toContain("<existing_items>\nPaint door");
    const bare = buildUserMessage({ transcript: "t", existing_items: [], known_clients: [] });
    expect(bare).toBe("<transcript>\nt\n</transcript>");
  });
});
