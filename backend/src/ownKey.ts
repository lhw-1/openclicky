import type { Context, MiddlewareHandler } from "hono";
import { getEnv, type Env } from "./env.js";
import { requireAuth, type Principal } from "./auth.js";
import { OPENAI_KEY_HEADER } from "./keys.js";
import { addressBlocks, ipOf, keyedHash, waitSeconds } from "./accountAuth.js";

/**
 * Own key, no account (issue #4). A request that brings its own OpenAI key and no token runs as an
 * anonymous "byok" principal: it reaches only the model routes, on the user's keys (resolveProviderKeys
 * switches on the same header, so the backend's keys are never used), and is never metered. The only
 * thing it costs the backend is bandwidth, so it is held to a per-address cap that stops floods.
 *
 * A request that does carry an Authorization header is judged by that header alone: a bad token is
 * a 401, never a quiet fall back to anonymous.
 */

const MINUTE = 60_000;
/** Model calls per address per minute. One spoken answer is 15–30 /tts pieces, so speech has its own, larger cap. */
const DEFAULT_MODEL_PER_MINUTE = 60;
const DEFAULT_TTS_PER_MINUTE = 180;
const hitsByBucket = { model: new Map<string, number[]>(), tts: new Map<string, number[]>() };

/** Kept for the life of the process when no secret is configured, so the subject is still not the raw address. */
let processSalt: string | undefined;
function saltFor(env: Env): string {
  const configured = env.IP_HASH_SALT || env.SESSION_TOKEN_SECRET || env.SUPABASE_SERVICE_KEY;
  if (configured) return configured;
  processSalt ??= Array.from(crypto.getRandomValues(new Uint8Array(32)), (b) => b.toString(16).padStart(2, "0")).join("");
  return processSalt;
}

export const hasOwnOpenAIKey = (c: Context) => Boolean(c.req.header(OPENAI_KEY_HEADER)?.trim());

const perMinute = (raw: string | undefined, fallback: number) => {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
};

/** The anonymous principal for this request: a keyed hash of the address block, never the address itself. */
export async function ownKeyPrincipal(c: Context): Promise<Principal> {
  const host = addressBlocks(ipOf(c)).host;
  return { sub: `byok:${(await keyedHash(saltFor(getEnv(c)), `byok:${host}`)).slice(0, 32)}`, via: "byok" };
}

/** Test hook: forget every count. */
export function resetOwnKeyLimits() {
  hitsByBucket.model.clear();
  hitsByBucket.tts.clear();
}

/**
 * requireAuth for the model routes: a token is checked exactly as before; no token but an own
 * OpenAI key is let through as the anonymous byok principal, rate-limited per address.
 */
export const requireAuthOrOwnKey: MiddlewareHandler<{ Variables: { principal: Principal } }> = async (c, next) => {
  if (c.req.header("authorization") !== undefined || !hasOwnOpenAIKey(c)) return requireAuth(c, next);
  const principal = await ownKeyPrincipal(c);
  const env = getEnv(c);
  const isSpeech = c.req.path === "/tts";
  const limit = isSpeech ? perMinute(env.OWN_KEY_TTS_PER_MINUTE, DEFAULT_TTS_PER_MINUTE) : perMinute(env.OWN_KEY_REQUESTS_PER_MINUTE, DEFAULT_MODEL_PER_MINUTE);
  const retryAfter = waitSeconds(isSpeech ? hitsByBucket.tts : hitsByBucket.model, principal.sub, limit, Date.now(), MINUTE);
  if (retryAfter) {
    console.warn(`own key: ${principal.sub} is over ${limit}/min on ${isSpeech ? "speech" : "model calls"}`);
    return c.json({ error: "slow_down" }, 429, { "Retry-After": String(retryAfter) });
  }
  c.set("principal", principal);
  await next();
};
