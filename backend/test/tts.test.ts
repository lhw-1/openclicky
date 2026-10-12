import { describe, it, expect, vi, afterEach, beforeEach } from "vitest";
import { Hono } from "hono";
import { speakOnGrant, elevenLabsCharsRemaining, resetElevenLabsCache } from "../src/tts.js";
import { requireAccount } from "../src/account.js";
import { MemorySpendLedger } from "../src/ledger.js";

beforeEach(() => resetElevenLabsCache());
afterEach(() => vi.unstubAllGlobals());

function stub(subscription: { character_count: number; character_limit: number }) {
  const f = vi.fn(async (url: string) =>
    url.includes("/v1/user/subscription")
      ? new Response(JSON.stringify(subscription), { headers: { "content-type": "application/json" } })
      : new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "audio/mpeg" } }),
  );
  vi.stubGlobal("fetch", f);
  return f;
}

function app(ledger: MemorySpendLedger) {
  const a = new Hono();
  a.use("*", async (c, next) => { c.set("principal" as never, { sub: "u1", via: "supabase" } as never); await next(); });
  a.use("*", requireAccount(() => ledger));
  a.post("/tts", (c) => speakOnGrant(c, ledger));
  return a;
}
const env = { ELEVENLABS_API_KEY: "xi" };
const say = (a: Hono, text = "Click Battery.") => a.request("/tts", { method: "POST", body: JSON.stringify({ text }) }, env);

describe("elevenLabsCharsRemaining", () => {
  it("is the plan's remainder minus a 5% margin", async () => {
    stub({ character_count: 1000, character_limit: 10_000 });
    expect(await elevenLabsCharsRemaining(env)).toBe(10_000 - 1000 - 500);
  });

  it("is 0 when the subscription lookup throws", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("network down"); }));
    expect(await elevenLabsCharsRemaining(env)).toBe(0);
  });

  it("logs a failed lookup and remembers it for a minute instead of asking ElevenLabs on every piece", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const f = vi.fn(async () => new Response("unauthorized", { status: 401 }));
    vi.stubGlobal("fetch", f);
    expect(await elevenLabsCharsRemaining(env, 1_000)).toBe(0);
    expect(await elevenLabsCharsRemaining(env, 30_000)).toBe(0);
    expect(f).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(log.mock.calls)).toContain("401");
    stub({ character_count: 0, character_limit: 10_000 });
    expect(await elevenLabsCharsRemaining(env, 62_000)).toBe(10_000 - 500);
    log.mockRestore();
  });

  it("is 0 when the subscription lookup returns non-JSON", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("<html>oops</html>", { status: 200 })));
    expect(await elevenLabsCharsRemaining(env)).toBe(0);
  });
});

describe("speakOnGrant", () => {
  it("speaks with ElevenLabs and counts characters", async () => {
    stub({ character_count: 0, character_limit: 1_000_000 });
    const ledger = new MemorySpendLedger();
    const res = await say(app(ledger));
    expect(res.headers.get("content-type")).toBe("audio/mpeg");
    const s = await ledger.summary("u1", { monthlyMicro: 10e6, dailyMicro: 2e6, globalMonthlyMicro: 1e9, ttsCharsMonthly: 20000, guestTotalMicro: 1_000_000, guestDays: 14, guestTtsChars: 2_000 });
    expect(s.ttsCharsMonth).toBe("Click Battery.".length);
  });

  it("answers tts_budget when ElevenLabs' allowance is used up", async () => {
    stub({ character_count: 9_999, character_limit: 10_000 });
    const res = await say(app(new MemorySpendLedger()), "A long answer.");
    expect(res.status).toBe(402);
    expect(await res.json()).toEqual({ error: "tts_budget" });
  });

  it("answers 413 text_too_long for 600 characters of Hindi, never 200 with partial audio, and spends nothing", async () => {
    const f = stub({ character_count: 0, character_limit: 1_000_000 });
    const ledger = new MemorySpendLedger();
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const hindi = "नमस्ते दुनिया ".repeat(43).slice(0, 600);
    const res = await say(app(ledger), hindi);
    expect(res.status).toBe(413);
    expect(await res.json()).toEqual({ error: "text_too_long" });
    expect(f.mock.calls.some(([url]) => String(url).includes("text-to-speech"))).toBe(false);
    const s = await ledger.summary("u1", { monthlyMicro: 10e6, dailyMicro: 2e6, globalMonthlyMicro: 1e9, ttsCharsMonthly: 20000, guestTotalMicro: 1_000_000, guestDays: 14, guestTtsChars: 2_000 });
    expect(s.ttsCharsMonth).toBe(0);
    expect(JSON.stringify(log.mock.calls)).toContain("600");
    log.mockRestore();
  });

  it("speaks a piece of exactly 400 characters whole", async () => {
    const f = stub({ character_count: 0, character_limit: 1_000_000 });
    const res = await say(app(new MemorySpendLedger()), "a".repeat(400));
    expect(res.status).toBe(200);
    const ttsCall = f.mock.calls.find(([url]) => String(url).includes("text-to-speech"))!;
    expect(JSON.parse((ttsCall as unknown as [string, RequestInit])[1].body as string).text.length).toBe(400);
  });

  it("answers tts_budget, not 500, when the subscription lookup throws", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("boom"); }));
    const res = await say(app(new MemorySpendLedger()));
    expect(res.status).toBe(402);
    expect(await res.json()).toEqual({ error: "tts_budget" });
  });

  it("answers tts_budget without upstream text or the key when text-to-speech throws", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.stubGlobal("fetch", vi.fn(async (url: string) => {
      if (url.includes("/v1/user/subscription")) return new Response(JSON.stringify({ character_count: 0, character_limit: 1_000_000 }));
      throw new Error("upstream said xi leaked");
    }));
    const res = await say(app(new MemorySpendLedger()));
    const body = await res.text();
    expect(res.status).toBe(402);
    expect(JSON.parse(body)).toEqual({ error: "tts_budget" });
    expect(body).not.toContain("leaked");
    expect(JSON.stringify(log.mock.calls)).not.toContain("xi leaked");
    log.mockRestore();
  });

  it("answers tts_budget, not 500, when the ledger reservation rejects", async () => {
    stub({ character_count: 0, character_limit: 1_000_000 });
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const ledger = new MemorySpendLedger();
    vi.spyOn(ledger, "reserveCharacters").mockRejectedValue(new Error("rpc down xi"));
    const res = await say(app(ledger));
    expect(res.status).toBe(402);
    expect(await res.json()).toEqual({ error: "tts_budget" });
    expect(JSON.stringify(log.mock.calls)).not.toContain("rpc down");
    log.mockRestore();
  });

  it("spends the cached plan remainder so accounts together cannot overspend between refreshes", async () => {
    stub({ character_count: 250, character_limit: 1000 });
    const a = app(new MemorySpendLedger());
    const text = "a".repeat(300);
    expect((await say(a, text)).status).toBe(200);
    expect((await say(a, text)).status).toBe(200);
    const third = await say(a, text);
    expect(third.status).toBe(402);
    expect(await third.json()).toEqual({ error: "tts_budget" });
  });

  it("speaks with OpenAI once ElevenLabs' shared plan is used up, and still counts the characters", async () => {
    const f = vi.fn(async (url: string) =>
      url.includes("/v1/user/subscription")
        ? new Response(JSON.stringify({ character_count: 9_999, character_limit: 10_000 }))
        : new Response(new Uint8Array([4, 5, 6]), { headers: { "content-type": "audio/mpeg" } }),
    );
    vi.stubGlobal("fetch", f);
    const ledger = new MemorySpendLedger();
    const res = await app(ledger).request("/tts", { method: "POST", body: JSON.stringify({ text: "A long answer." }) },
      { ...env, OPENAI_API_KEY: "sk-test", OPENAI_TTS_MODEL: "gpt-4o-mini-tts", OPENAI_TTS_VOICE: "marin" });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("audio/mpeg");
    const speech = f.mock.calls.find(([url]) => String(url).endsWith("/audio/speech"))!;
    expect(String(speech[0])).toBe("https://api.openai.com/v1/audio/speech");
    expect(JSON.parse((speech as unknown as [string, RequestInit])[1].body as string)).toMatchObject({ model: "gpt-4o-mini-tts", voice: "marin", input: "A long answer." });
    expect(f.mock.calls.some(([url]) => String(url).includes("text-to-speech"))).toBe(false);
    const s = await ledger.summary("u1", { monthlyMicro: 10e6, dailyMicro: 2e6, globalMonthlyMicro: 1e9, ttsCharsMonthly: 20000, guestTotalMicro: 1_000_000, guestDays: 14, guestTtsChars: 10_000 });
    expect(s.ttsCharsMonth).toBe("A long answer.".length);
  });

  it("speaks with OpenAI when an ElevenLabs request fails", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const f = vi.fn(async (url: string) => {
      if (url.includes("/v1/user/subscription")) return new Response(JSON.stringify({ character_count: 0, character_limit: 1_000_000 }));
      if (url.includes("text-to-speech")) return new Response("busy", { status: 503 });
      return new Response(new Uint8Array([7]), { headers: { "content-type": "audio/mpeg" } });
    });
    vi.stubGlobal("fetch", f);
    const res = await app(new MemorySpendLedger()).request("/tts", { method: "POST", body: JSON.stringify({ text: "Hello." }) }, { ...env, OPENAI_API_KEY: "sk-test" });
    expect(res.status).toBe(200);
    expect(f.mock.calls.some(([url]) => String(url).endsWith("/audio/speech"))).toBe(true);
    log.mockRestore();
  });

  it("speaks with OpenAI alone when there is no ElevenLabs key", async () => {
    const f = vi.fn(async () => new Response(new Uint8Array([8]), { headers: { "content-type": "audio/mpeg" } }));
    vi.stubGlobal("fetch", f);
    const res = await app(new MemorySpendLedger()).request("/tts", { method: "POST", body: JSON.stringify({ text: "Hi." }) }, { OPENAI_API_KEY: "sk-test" });
    expect(res.status).toBe(200);
    expect(f).toHaveBeenCalledTimes(1);
  });

  it("still holds each account to its own character limit when OpenAI speaks", async () => {
    vi.stubGlobal("fetch", vi.fn(async (url: string) =>
      url.includes("/v1/user/subscription")
        ? new Response(JSON.stringify({ character_count: 10_000, character_limit: 10_000 }))
        : new Response(new Uint8Array([9]), { headers: { "content-type": "audio/mpeg" } })));
    const ledger = new MemorySpendLedger();
    const a = new Hono();
    a.use("*", async (c, next) => { c.set("principal" as never, { sub: "u1", via: "supabase" } as never); await next(); });
    a.use("*", requireAccount(() => ledger));
    a.use("*", async (c, next) => {
      const account = c.get("account" as never) as { limits: { ttsCharsMonthly: number } };
      account.limits = { ...account.limits, ttsCharsMonthly: 10 };
      await next();
    });
    a.post("/tts", (c) => speakOnGrant(c, ledger));
    const res = await a.request("/tts", { method: "POST", body: JSON.stringify({ text: "More than ten characters." }) }, { ...env, OPENAI_API_KEY: "sk-test" });
    expect(res.status).toBe(402);
  });
});
