import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { backendHeaders, canCallBackend } from "../src/backendHeaders.js";
import { resolveConfig, repoRoot } from "../src/config.js";
import { renderCodexConfig } from "../src/codexHome.js";

describe("backendHeaders", () => {
  it("adds the bearer token and, when present, the user's provider keys", () => {
    expect(backendHeaders({ token: "t" })).toEqual({ authorization: "Bearer t" });
    expect(backendHeaders({ token: "t", openaiApiKey: "sk-user", anthropicApiKey: "ak-user" }, { "content-type": "application/json" })).toEqual({
      "content-type": "application/json",
      authorization: "Bearer t",
      "x-openclicky-openai-key": "sk-user",
      "x-openclicky-anthropic-key": "ak-user",
    });
  });

  it("sends no Authorization header for an own key with no account (issue #4)", () => {
    expect(backendHeaders({ openaiApiKey: "sk-user" })).toEqual({ "x-openclicky-openai-key": "sk-user" });
    expect(backendHeaders({ token: "" })).toEqual({});
    expect(canCallBackend({ openaiApiKey: "sk-user" })).toBe(true);
    expect(canCallBackend({ token: "t" })).toBe(true);
    expect(canCallBackend({})).toBe(false);
  });

  it("points Codex at OpenAI on the own key, or at the backend on the token", () => {
    const template = fs.readFileSync(path.join(repoRoot(), "config", "codex-config.toml"), "utf8");
    const base = { root: "/r", backendUrl: "http://b/", workspace: "/w", userSkillsActive: "/s" };
    const viaBackend = renderCodexConfig(template, base);
    expect(viaBackend).toContain('base_url = "http://b/v1"\nenv_key = "OPENCLICKY_SESSION_TOKEN"');
    const direct = renderCodexConfig(template, { ...base, ownOpenAIKey: true });
    expect(direct).toContain('base_url = "https://api.openai.com/v1"\nenv_key = "OPENCLICKY_OPENAI_KEY"');
    expect(direct).not.toContain("http://b");
    // Own keys never travel to the backend as headers any more.
    expect(direct).not.toContain("env_http_headers");
    expect(viaBackend).not.toContain("env_http_headers");
    expect(direct).not.toContain("{{");
  });

  it("reads the keys from the environment", () => {
    const cfg = resolveConfig({}, { HOME: "/tmp", OPENCLICKY_OPENAI_KEY: "sk-env", OPENCLICKY_ANTHROPIC_KEY: "ak-env" });
    expect(cfg.openaiApiKey).toBe("sk-env");
    expect(cfg.anthropicApiKey).toBe("ak-env");
    expect(resolveConfig({}, { HOME: "/tmp" }).openaiApiKey).toBeUndefined();
  });

});
