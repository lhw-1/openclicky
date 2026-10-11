import { describe, it, expect, beforeAll, afterAll, beforeEach } from "vitest";
import http from "node:http";
import { createApp } from "../src/app.js";
import type { Env } from "../src/env.js";
import { MemorySpendLedger } from "../src/ledger.js";
import { resetOwnKeyLimits } from "../src/ownKey.js";

// Issue #4: an own OpenAI key works with no account.

type Seen = { url: string; auth?: string; apiKey?: string };
let upstream: http.Server;
let upstreamUrl: string;
const seen: Seen[] = [];

beforeAll(async () => {
  upstream = http.createServer((req, res) => {
    req.resume();
    req.on("end", () => {
      seen.push({ url: req.url!, auth: req.headers.authorization, apiKey: req.headers["x-api-key"] as string | undefined });
      if (req.url!.endsWith("/audio/speech")) {
        res.writeHead(200, { "content-type": "audio/mpeg" });
        return void res.end(Buffer.from("ID3fake"));
      }
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.end('data: {"chunk":1}\n\ndata: [DONE]\n\n');
    });
  });
  await new Promise<void>((r) => upstream.listen(0, "127.0.0.1", r));
  upstreamUrl = `http://127.0.0.1:${(upstream.address() as { port: number }).port}`;
});
afterAll(() => upstream.close());
beforeEach(() => {
  seen.length = 0;
  resetOwnKeyLimits();
});

const env = (): Env => ({
  SUPABASE_JWT_SECRET: "supabase-test-secret-supabase-test-secret",
  SESSION_TOKEN_SECRET: "session-secret-session-secret-session",
  // The backend's own keys point somewhere else: an own-key request must never reach them.
  OPENAI_API_KEY: "sk-backend",
  OPENAI_BASE_URL: "http://backend-keys.invalid/v1",
  ANTHROPIC_API_KEY: "ak-backend",
  ANTHROPIC_BASE_URL: "http://backend-keys.invalid",
  ELEVENLABS_API_KEY: "xi-backend",
  ELEVENLABS_BASE_URL: "http://backend-keys.invalid",
  ASSEMBLYAI_API_KEY: "aai-backend",
  BYOK_OPENAI_BASE_URL: upstreamUrl + "/v1",
  BYOK_ANTHROPIC_BASE_URL: upstreamUrl,
});
const app = createApp({ log: null });
const ownKey = (extra: Record<string, string> = {}) => ({ "content-type": "application/json", "x-openclicky-openai-key": "sk-user", "x-forwarded-for": "203.0.113.7", ...extra });
const ask = (headers: Record<string, string>, over: Partial<Env> = {}, path = "/v1/chat/completions") =>
  app.request(path, { method: "POST", headers, body: JSON.stringify({ model: "gpt-4o-mini", messages: [], stream: true }) }, { ...env(), ...over });

describe("own key, no account", () => {
  it("reaches the upstream with the person's key and no token", async () => {
    const r = await ask(ownKey());
    expect(r.status).toBe(200);
    await r.text();
    expect(seen).toHaveLength(1);
    expect(seen[0].url).toBe("/v1/chat/completions");
    expect(seen[0].auth).toBe("Bearer sk-user");
  });

  it("runs the Claude lanes on the person's Anthropic key, and refuses them without one", async () => {
    const without = await ask(ownKey(), {}, "/v1/messages");
    expect(without.status).toBe(402);
    expect(await without.json()).toEqual({ error: "byok_missing_anthropic_key" });
    const withKey = await ask(ownKey({ "x-openclicky-anthropic-key": "ak-user" }), {}, "/chat");
    expect(withKey.status).toBe(200);
    await withKey.text();
    expect(seen.map((s) => s.apiKey)).toEqual(["ak-user"]);
  });

  it("speaks with the person's OpenAI key, never the backend's ElevenLabs key", async () => {
    const r = await app.request("/tts", { method: "POST", headers: ownKey(), body: JSON.stringify({ text: "hi" }) }, env());
    expect(r.status).toBe(200);
    expect(seen.map((s) => [s.url, s.auth])).toEqual([["/v1/audio/speech", "Bearer sk-user"]]);
  });

  it("is never metered on a grant backend", async () => {
    const ledger = new MemorySpendLedger();
    const billed = createApp({ log: null, spendLedger: ledger });
    const r = await billed.request("/v1/chat/completions", { method: "POST", headers: ownKey(), body: JSON.stringify({ model: "x", messages: [], stream: true }) },
      { ...env(), GRANT_ACCOUNTS: "true" });
    expect(r.status).toBe(200);
    await r.text();
    expect(seen[0].auth).toBe("Bearer sk-user");
  });

  it("answers 401 with neither a key nor a token", async () => {
    const r = await ask({ "content-type": "application/json" });
    expect(r.status).toBe(401);
    expect(seen).toHaveLength(0);
  });

  it("answers 401 to a bad token even with an own key: no fall back to anonymous", async () => {
    for (const authorization of ["Bearer not-a-jwt", "Bearer ", "Basic abc"]) {
      const r = await ask(ownKey({ authorization }));
      expect(r.status).toBe(401);
    }
    expect(seen).toHaveLength(0);
  });

  it("keeps the account-only routes at 401", async () => {
    const routes: [string, string][] = [["GET", "/billing/me"], ["POST", "/transcribe-token"], ["POST", "/auth/resend"], ["POST", "/auth/confirm"], ["POST", "/billing/checkout"], ["POST", "/billing/portal"]];
    for (const [method, path] of routes) {
      const r = await app.request(path, { method, headers: ownKey(), ...(method === "POST" ? { body: "{}" } : {}) }, env());
      expect([path, r.status]).toEqual([path, 401]);
    }
    expect(seen).toHaveLength(0);
  });

  it("is limited per address, with Retry-After", async () => {
    const over = { OWN_KEY_REQUESTS_PER_MINUTE: "2" };
    for (let i = 0; i < 2; i++) {
      const r = await ask(ownKey(), over);
      expect(r.status).toBe(200);
      await r.text();
    }
    const limited = await ask(ownKey(), over);
    expect(limited.status).toBe(429);
    expect(Number(limited.headers.get("retry-after"))).toBeGreaterThan(0);
    expect(await limited.json()).toEqual({ error: "slow_down" });
    // Another address has its own count.
    const other = await ask(ownKey({ "x-forwarded-for": "198.51.100.9" }), over);
    expect(other.status).toBe(200);
    await other.text();
  });
});
