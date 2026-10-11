import type { Context } from "hono";
import { getEnv, type Env } from "./env.js";
import type { AccountContext } from "./account.js";
import type { SpendLedger } from "./ledger.js";

/** The most one /tts call may speak. The app splits answers into pieces well under this (about 350). */
export const SPOKEN_CHARS = 400;
const CACHE_MS = 10 * 60_000;
/** A failed lookup is remembered this long: long enough that a long answer does not re-ask ElevenLabs
 *  for every piece, short enough that the real voice comes back within a minute once it recovers. */
const FAILURE_CACHE_MS = 60_000;
let cached: { at: number; remaining: number; ttl: number } | undefined;
export function resetElevenLabsCache() { cached = undefined; }
const fresh = (now: number) => (cached && now - cached.at < cached.ttl ? cached.remaining : undefined);
/** Spend from the cached remainder so accounts together cannot overspend the plan between refreshes. */
const spendCached = (characters: number) => { if (cached) cached = { ...cached, remaining: Math.max(0, cached.remaining - characters) }; };
const remember = (at: number, remaining: number, ttl = CACHE_MS) => { cached = { at, remaining, ttl }; };

const base = (env: Env) => (env.ELEVENLABS_BASE_URL || "https://api.elevenlabs.io").replace(/\/$/, "");

/** What is left on the ElevenLabs plan this period, minus a safety margin; cached so every answer is not a lookup.
 *  A failed or unreadable lookup counts as nothing left, so the app falls back to the system voice; it is
 *  logged (otherwise every account silently loses the real voice) and remembered for a minute. */
export async function elevenLabsCharsRemaining(env: Env, now = Date.now()): Promise<number> {
  const hit = fresh(now);
  if (hit !== undefined) return hit;
  const failed = (why: string) => {
    console.error(`tts: ElevenLabs subscription lookup failed (${why}); speaking with the Mac voice for the next minute`);
    remember(now, 0, FAILURE_CACHE_MS);
    return 0;
  };
  try {
    const res = await fetch(`${base(env)}/v1/user/subscription`, { headers: { "xi-api-key": env.ELEVENLABS_API_KEY ?? "" } });
    if (!res.ok) return failed(`HTTP ${res.status}`);
    const sub = (await res.json()) as { character_count?: number; character_limit?: number };
    const limit = Number(sub.character_limit ?? 0);
    const margin = Math.ceil(limit * Number(env.TTS_GLOBAL_MARGIN ?? 0.05));
    const remaining = Math.max(0, limit - Number(sub.character_count ?? 0) - margin);
    if (!Number.isFinite(remaining)) return failed("unreadable numbers");
    remember(now, remaining);
    return remaining;
  } catch (e) {
    return failed(e instanceof SyntaxError ? "not JSON" : "network error");
  }
}

export async function speakOnGrant(c: Context, ledger: SpendLedger): Promise<Response> {
  const env = getEnv(c);
  if (!env.ELEVENLABS_API_KEY) return c.json({ error: "tts_budget" }, 402);
  let req: { text?: string } = {};
  try { req = JSON.parse((await c.req.text()) || "{}"); } catch { return c.json({ error: "body must be JSON" }, 400); }
  const text = typeof req.text === "string" ? req.text.trim() : "";
  if (!text) return c.json({ error: "body must be JSON with `text`" }, 400);
  // Trimming here used to answer 200 with only the start of the piece spoken and the rest lost
  // without a word (deep test F-40). Refusing lets the app speak the whole piece with the Mac voice.
  if (text.length > SPOKEN_CHARS) {
    console.error(`tts: refused a ${text.length}-character piece (limit ${SPOKEN_CHARS})`);
    return c.json({ error: "text_too_long" }, 413);
  }
  const account = c.get("account" as never) as AccountContext;
  const remaining = await elevenLabsCharsRemaining(env);
  let reserved: Awaited<ReturnType<SpendLedger["reserveCharacters"]>>;
  try {
    reserved = await ledger.reserveCharacters(account.userId, text.length, account.limits, remaining);
  } catch {
    console.error("tts: character reservation failed");
    return c.json({ error: "tts_budget" }, 402);
  }
  if (!reserved.ok) return c.json({ error: "tts_budget" }, 402); // the app falls back to the Mac's voice, silently
  spendCached(text.length);
  const voiceId = env.ELEVENLABS_VOICE_ID || "21m00Tcm4TlvDq8ikWAM";
  let upstream: Response;
  try {
    upstream = await fetch(`${base(env)}/v1/text-to-speech/${voiceId}`, {
      method: "POST",
      headers: { "xi-api-key": env.ELEVENLABS_API_KEY, "content-type": "application/json", accept: "audio/mpeg" },
      body: JSON.stringify({ text, model_id: "eleven_flash_v2_5", voice_settings: { stability: 0.5, similarity_boost: 0.75 } }),
    });
  } catch {
    console.error("tts: ElevenLabs request failed");
    return c.json({ error: "tts_budget" }, 402);
  }
  if (!upstream.ok || !upstream.body) {
    console.error(`tts: ElevenLabs ${upstream.status}`);
    return c.json({ error: "tts_budget" }, 402);
  }
  return new Response(upstream.body, { headers: { "content-type": "audio/mpeg" } });
}
