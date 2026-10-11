import type { AgentConfig } from "./config.js";

/**
 * Headers every backend call carries: the bearer token plus the user's own provider keys when
 * they brought them (bring your own key). The backend uses those keys instead of its own for
 * that request and meters nothing; without them the request runs under the user's plan. An own
 * key needs no account, so with no token no Authorization header is sent at all: the backend
 * refuses an empty or bad one rather than reading it as "no account".
 */
export function backendHeaders(cfg: Pick<AgentConfig, "token" | "openaiApiKey" | "anthropicApiKey">, extra: Record<string, string> = {}): Record<string, string> {
  return {
    ...extra,
    ...(cfg.token ? { authorization: `Bearer ${cfg.token}` } : {}),
    ...(cfg.openaiApiKey ? { "x-openclicky-openai-key": cfg.openaiApiKey } : {}),
    ...(cfg.anthropicApiKey ? { "x-openclicky-anthropic-key": cfg.anthropicApiKey } : {}),
  };
}

/** A backend call can be authorised: a token, or the user's own OpenAI key (which needs no account). */
export const canCallBackend = (cfg: Pick<AgentConfig, "token" | "openaiApiKey">): boolean => Boolean(cfg.token || cfg.openaiApiKey);

export const MISSING_CREDENTIALS = "missing token: set OPENCLICKY_TOKEN or pass --token, or bring your own OpenAI key (OPENCLICKY_OPENAI_KEY)";
