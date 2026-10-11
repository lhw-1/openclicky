import { describe, it, expect, vi } from "vitest";
import { GoTrue, GoTrueError } from "../src/gotrue.js";

function fake(reply: (url: string, init: RequestInit) => Response) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetchImpl = vi.fn(async (url: any, init: any) => { calls.push({ url: String(url), init }); return reply(String(url), init); });
  return { gt: new GoTrue("https://p.supabase.co/", "pk", "sk", fetchImpl as any), calls };
}
const session = { access_token: "a", refresh_token: "r", expires_in: 3600, user: { id: "u1" } };
const headers = (i: RequestInit) => i.headers as Record<string, string>;

describe("GoTrue", () => {
  it("signs up anonymously with the publishable key", async () => {
    const { gt, calls } = fake(() => new Response(JSON.stringify(session)));
    expect(await gt.signUpAnonymously()).toEqual(session);
    expect(calls[0].url).toBe("https://p.supabase.co/auth/v1/signup");
    expect(headers(calls[0].init).apikey).toBe("pk");
    expect(calls[0].init.body).toBe("{}");
  });
  it("attaches an email as the user, with redirect_to", async () => {
    const { gt, calls } = fake(() => new Response("{}"));
    await gt.attachEmail("tok", "gran@example.com", "https://api/auth/confirmed");
    expect(calls[0].url).toBe("https://p.supabase.co/auth/v1/user?redirect_to=" + encodeURIComponent("https://api/auth/confirmed"));
    expect(calls[0].init.method).toBe("PUT");
    expect(headers(calls[0].init).Authorization).toBe("Bearer tok");
    expect(JSON.parse(String(calls[0].init.body))).toEqual({ email: "gran@example.com" });
  });
  it("sends a code without creating users", async () => {
    const { gt, calls } = fake(() => new Response("{}"));
    await gt.sendCode("gran@example.com");
    expect(calls[0].url).toBe("https://p.supabase.co/auth/v1/otp");
    expect(JSON.parse(String(calls[0].init.body))).toEqual({ email: "gran@example.com", create_user: false });
  });
  it("verifies a code as type email", async () => {
    const { gt, calls } = fake(() => new Response(JSON.stringify(session)));
    expect(await gt.verifyCode("gran@example.com", "123456")).toEqual(session);
    expect(JSON.parse(String(calls[0].init.body))).toEqual({ type: "email", email: "gran@example.com", token: "123456" });
  });
  it("sends a sign-up code that may create the user", async () => {
    const { gt, calls } = fake(() => new Response("{}"));
    await gt.sendSignupCode("gran@example.com");
    expect(calls[0].url).toBe("https://p.supabase.co/auth/v1/otp");
    expect(JSON.parse(String(calls[0].init.body))).toEqual({ email: "gran@example.com", create_user: true });
  });
  it("verifies a guest's confirmation code as type email_change", async () => {
    const { gt, calls } = fake(() => new Response(JSON.stringify(session)));
    expect(await gt.verifyEmailChange("gran@example.com", "123456")).toEqual(session);
    expect(JSON.parse(String(calls[0].init.body))).toEqual({ type: "email_change", email: "gran@example.com", token: "123456" });
  });
  it("signs out the user's other sessions with the kept session's own token (empty 204 reply)", async () => {
    const { gt, calls } = fake(() => new Response(null, { status: 204 }));
    await gt.signOutOthers("keep-me");
    expect(calls[0].url).toBe("https://p.supabase.co/auth/v1/logout?scope=others");
    expect(calls[0].init.method).toBe("POST");
    expect(headers(calls[0].init).Authorization).toBe("Bearer keep-me");
  });
  it("reads and deletes users with the service key", async () => {
    const { gt, calls } = fake((url, init) => init.method === "DELETE" ? new Response("{}") : new Response(JSON.stringify({ id: "u1", is_anonymous: true, email: "" })));
    expect(await gt.getUser("u1")).toEqual({ id: "u1", is_anonymous: true, email: null });
    await gt.deleteUser("u1");
    expect(calls[0].url).toBe("https://p.supabase.co/auth/v1/admin/users/u1");
    expect(headers(calls[0].init).Authorization).toBe("Bearer sk");
    expect(calls[1].init.method).toBe("DELETE");
  });
  it("getUser answers null for a missing user", async () => {
    const { gt } = fake(() => new Response('{"code":404,"error_code":"user_not_found"}', { status: 404 }));
    expect(await gt.getUser("gone")).toBeNull();
  });
  it("failures carry status and error_code, never the response text", async () => {
    const { gt } = fake(() => new Response('{"code":422,"error_code":"email_exists","msg":"secret detail"}', { status: 422 }));
    const err = await gt.attachEmail("t", "a@b.co", "x").catch((e) => e);
    expect(err).toBeInstanceOf(GoTrueError);
    expect(err).toMatchObject({ status: 422, code: "email_exists" });
    expect(String(err.message)).not.toContain("secret detail");
  });
  it("a 2xx body that is not JSON throws bad_response without quoting the body", async () => {
    const { gt } = fake(() => new Response("<html>secret page</html>", { status: 200 }));
    const err = await gt.signUpAnonymously().catch((e) => e);
    expect(err).toBeInstanceOf(GoTrueError);
    expect(err).toMatchObject({ status: 200, code: "bad_response" });
    expect(String(err.message)).not.toContain("secret");
  });
});
