import { describe, it, expect, vi, afterEach } from "vitest";
import { SignJWT } from "jose";
import { issueSessionToken } from "../src/auth.js";
import { createApp } from "../src/app.js";
import { normalizeEmail, isDeviceHash, allow, addressBlocks } from "../src/accountAuth.js";

const env = { SUPABASE_URL: "https://p.supabase.co", SUPABASE_PUBLISHABLE_KEY: "pk", SUPABASE_SERVICE_KEY: "sk", ACCOUNTS_OPEN: "true", SUPABASE_JWT_SECRET: "x".repeat(32) };
const device = "d".repeat(64);
const post = (body: unknown, ip = "1.1.1.1") => ({ method: "POST", headers: { "content-type": "application/json", "x-forwarded-for": ip }, body: JSON.stringify(body) });
const session = { access_token: "acc", refresh_token: "ref", expires_in: 3600, user: { id: "u-new" } };

type Row = { user_id: string; email: string | null; device_hash: string | null; confirmed_at: string | null; replaced_at: string | null; ip_hash?: string | null; net_hash?: string | null; code_signed_in_at?: string | null };
type Fake = {
  rows?: Row[]; users?: Record<string, { is_anonymous: boolean }>; open?: boolean; attach?: () => Response; insertFails?: number; verify?: () => Response;
  /** The live-guest pool (max_guests) is full. */ guestsFull?: boolean;
  /** oc_signup_room fails, as a database hiccup would. */ roomFails?: boolean;
  /** oc_rate_hit fails (schema not applied yet): the backend counts in memory instead. */ rateFails?: boolean;
  /** Shared attempt counters, to stand for Postgres surviving a redeploy. */ hits?: Map<string, number>;
};
/** A fake Supabase: oc_accounts rows in memory, auth users in memory, every call recorded. The two
 *  sign-up guard functions follow schema.sql: at most 2 live guests per address and 6 per network
 *  (guests on the caller's own Mac don't count), and fixed-window attempt counters. */
function supabase(opts: Fake = {}) {
  const rows = (opts.rows ?? []).map((r) => ({ ...r })); // copies: a test's row literal is shared between tests
  const users = { ...(opts.users ?? {}) };
  const calls: { method: string; url: string; body?: any; auth?: string }[] = [];
  const hits = opts.hits ?? new Map<string, number>();
  let insertFailures = opts.insertFails ?? 0;
  let signups = 0;
  vi.stubGlobal("fetch", vi.fn(async (input: any, init: any = {}) => {
    const url = String(input), method = init.method ?? "GET";
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ method, url, body, auth: init.headers?.Authorization });
    const u = new URL(url);
    if (u.pathname === "/rest/v1/rpc/oc_accounts_open") return new Response(JSON.stringify(opts.open ?? true));
    if (u.pathname === "/rest/v1/rpc/oc_signup_room") {
      if (opts.roomFails) return new Response("connection reset", { status: 503 });
      const live = rows.filter((r) => users[r.user_id]?.is_anonymous && !r.replaced_at);
      const others = live.filter((r) => body.p_device === null || r.device_hash !== body.p_device);
      const guests = !opts.guestsFull
        && (body.p_ip_hash === null || others.filter((r) => r.ip_hash === body.p_ip_hash).length < 2)
        && (body.p_net_hash === null || others.filter((r) => r.net_hash === body.p_net_hash).length < 6);
      return new Response(JSON.stringify({ accounts: opts.open ?? true, guests }));
    }
    if (u.pathname === "/rest/v1/rpc/oc_rate_hit") {
      if (opts.rateFails) return new Response('{"code":"PGRST202"}', { status: 404 });
      const n = (hits.get(body.p_key) ?? 0) + 1;
      hits.set(body.p_key, n);
      return new Response(JSON.stringify(n <= body.p_limit ? 0 : 1800));
    }
    if (u.pathname === "/auth/v1/logout") return new Response(null, { status: 204 });
    if (u.pathname === "/rest/v1/oc_accounts") {
      const q = u.searchParams;
      const match = (r: Row) =>
        (!q.get("email") || r.email === q.get("email")!.slice(3)) &&
        (!q.get("device_hash") || r.device_hash === q.get("device_hash")!.slice(3)) &&
        (!q.get("user_id") || r.user_id === q.get("user_id")!.slice(3)) &&
        (q.get("confirmed_at") !== "not.is.null" || r.confirmed_at !== null);
      if (method === "GET") return new Response(JSON.stringify(rows.filter(match)));
      if (method === "POST") {
        if (insertFailures-- > 0) return new Response("nope", { status: 500 });
        rows.push({ email: null, device_hash: null, confirmed_at: null, replaced_at: null, ...body });
        return new Response(JSON.stringify([body]), { status: 201 });
      }
      if (method === "PATCH") { rows.filter(match).forEach((r) => Object.assign(r, body)); return new Response(null, { status: 204 }); }
    }
    if (u.pathname === "/auth/v1/signup") {
      const id = ++signups === 1 ? "u-new" : `u-new-${signups}`;
      users[id] = { is_anonymous: true };
      return new Response(JSON.stringify({ ...session, user: { id } }));
    }
    if (u.pathname === "/auth/v1/user") return opts.attach ? opts.attach() : new Response("{}");
    if (u.pathname === "/auth/v1/otp") return new Response("{}");
    if (u.pathname === "/auth/v1/verify") return opts.verify ? opts.verify() : new Response(JSON.stringify({ ...session, user: { id: "u-old" } }));
    if (u.pathname.startsWith("/auth/v1/admin/users/")) {
      const id = decodeURIComponent(u.pathname.split("/").pop()!);
      if (method === "DELETE") { delete users[id]; return new Response("{}"); }
      return users[id] ? new Response(JSON.stringify({ id, ...users[id] })) : new Response('{"error_code":"user_not_found"}', { status: 404 });
    }
    throw new Error(`unexpected ${method} ${url}`);
  }));
  return { rows, users, calls, hits };
}
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });
const start = (body: unknown, ip?: string, e: Record<string, string> = env) => createApp({ log: null }).request("/auth/start", post(body, ip), e);

describe("helpers", () => {
  it("emails are trimmed and lower-cased; junk is null", () => {
    expect(normalizeEmail("  Gran@Example.COM ")).toBe("gran@example.com");
    expect(normalizeEmail("nope")).toBeNull();
    expect(normalizeEmail("a@b")).toBeNull();
    expect(normalizeEmail(42)).toBeNull();
  });
  it("device hashes are 64 lowercase hex", () => {
    expect(isDeviceHash(device)).toBe(true);
    expect(isDeviceHash("D".repeat(64))).toBe(false);
    expect(isDeviceHash("d".repeat(63))).toBe(false);
  });
  it("allow counts per key within an hour", () => {
    const hits = new Map<string, number[]>();
    for (let i = 0; i < 5; i++) expect(allow(hits, "ip", 5, 1000)).toBe(true);
    expect(allow(hits, "ip", 5, 1000)).toBe(false);
    expect(allow(hits, "ip", 5, 1000 + 3_600_001)).toBe(true);
  });
});

describe("POST /auth/start", () => {
  it("creates a guest: anonymous user, email attached with redirect, row recorded, session returned", async () => {
    const s = supabase();
    const res = await start({ email: " Gran@Example.com ", device });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "signed_in", session: { access_token: "acc", refresh_token: "ref", expires_in: 3600 }, confirmed: false });
    const attach = s.calls.find((c) => c.url.includes("/auth/v1/user"))!;
    expect(attach.url).toContain("redirect_to=" + encodeURIComponent("http://localhost/auth/confirmed"));
    expect(attach.body).toEqual({ email: "gran@example.com" });
    expect(s.rows).toContainEqual(expect.objectContaining({ user_id: "u-new", email: "gran@example.com", device_hash: device }));
  });
  it("an email with a confirmed account gets a code instead", async () => {
    const s = supabase({ rows: [{ user_id: "u-old", email: "gran@example.com", device_hash: "e".repeat(64), confirmed_at: "2026-10-01T00:00:00Z", replaced_at: null }] });
    const res = await start({ email: "gran@example.com", device });
    expect(await res.json()).toEqual({ status: "code_sent" });
    expect(s.calls.some((c) => c.url.endsWith("/auth/v1/otp"))).toBe(true);
    expect(s.calls.some((c) => c.url.endsWith("/auth/v1/signup"))).toBe(false);
  });
  it("is 402 accounts_full when closed, without touching auth", async () => {
    const s = supabase({ open: false });
    const res = await start({ email: "a@b.co", device });
    expect(res.status).toBe(402);
    expect(await res.json()).toEqual({ error: "accounts_full" });
    expect(s.calls.some((c) => c.url.includes("/auth/v1/"))).toBe(false);
    expect((await start({ email: "a@b.co", device }, "2.2.2.2", { ...env, ACCOUNTS_OPEN: "false" })).status).toBe(402);
  });
  it("is 402 device_limit when the Mac already has two confirmed accounts for other emails", async () => {
    const confirmed = (id: string, email: string): Row => ({ user_id: id, email, device_hash: device, confirmed_at: "2026-10-01T00:00:00Z", replaced_at: null });
    supabase({ rows: [confirmed("u1", "one@x.co"), confirmed("u2", "two@x.co")] });
    const res = await start({ email: "three@x.co", device });
    expect(res.status).toBe(402);
    expect(await res.json()).toEqual({ error: "device_limit" });
  });
  it("a live guest on the Mac is replaced and its auth user deleted", async () => {
    const s = supabase({ rows: [{ user_id: "u-guest", email: "gran@example.com", device_hash: device, confirmed_at: null, replaced_at: null }], users: { "u-guest": { is_anonymous: true } } });
    const res = await start({ email: "gran@example.com", device });
    expect(res.status).toBe(200);
    expect(s.rows.find((r) => r.user_id === "u-guest")!.replaced_at).not.toBeNull();
    expect(s.users["u-guest"]).toBeUndefined();
  });
  it("a clicked-but-unused guest is treated as confirmed, not replaced", async () => {
    const s = supabase({ rows: [{ user_id: "u-clicked", email: "gran@example.com", device_hash: device, confirmed_at: null, replaced_at: null }], users: { "u-clicked": { is_anonymous: false } } });
    const res = await start({ email: "gran@example.com", device });
    expect(await res.json()).toEqual({ status: "code_sent" });
    expect(s.users["u-clicked"]).toBeDefined();
    expect(s.rows[0].confirmed_at).not.toBeNull();
    expect(s.rows[0].replaced_at).toBeNull();
  });
  it("email taken in auth (confirmed elsewhere): the new anonymous user is deleted and a code is sent", async () => {
    const s = supabase({ attach: () => new Response('{"error_code":"email_exists"}', { status: 422 }) });
    const res = await start({ email: "gran@example.com", device });
    expect(await res.json()).toEqual({ status: "code_sent" });
    expect(s.users["u-new"]).toBeUndefined();
  });
  it("attach failure deletes the new anonymous user and answers 502", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const s = supabase({ attach: () => new Response('{"msg":"boom"}', { status: 500 }) });
    const res = await start({ email: "gran@example.com", device });
    expect(res.status).toBe(502);
    expect(await res.json()).toEqual({ error: "auth_unavailable" });
    expect(s.users["u-new"]).toBeUndefined();
    expect(s.rows).toHaveLength(0);
  });
  it("retries the row insert once; a second failure deletes the auth user and answers 502", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const ok = supabase({ insertFails: 1 });
    expect((await start({ email: "a@b.co", device }, "3.3.3.3")).status).toBe(200);
    expect(ok.rows).toHaveLength(1);
    const bad = supabase({ insertFails: 2 });
    expect((await start({ email: "a@b.co", device }, "4.4.4.4")).status).toBe(502);
    expect(bad.users["u-new"]).toBeUndefined();
  });
  it("an attach failure leaves a live guest on the Mac untouched", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const s = supabase({ rows: [{ user_id: "u-guest", email: "old@example.com", device_hash: device, confirmed_at: null, replaced_at: null }], users: { "u-guest": { is_anonymous: true } }, attach: () => new Response('{"msg":"boom"}', { status: 500 }) });
    const res = await start({ email: "gran@example.com", device });
    expect(res.status).toBe(502);
    expect(s.rows.find((r) => r.user_id === "u-guest")!.replaced_at).toBeNull();
    expect(s.users["u-guest"]).toBeDefined();
  });
  it("rejects a bad email or device before any call", async () => {
    const s = supabase();
    expect(await (await start({ email: "nope", device })).json()).toEqual({ error: "bad_email" });
    expect(await (await start({ email: "a@b.co", device: "short" })).json()).toEqual({ error: "bad_request" });
    expect(s.calls).toHaveLength(0);
  });
  it("a classroom behind one address can all start; one email is held to five starts an hour, with Retry-After", async () => {
    supabase();
    const app = createApp({ log: null });
    for (let i = 0; i < 25; i++) expect((await app.request("/auth/start", post({ email: `pupil${i}@school.example`, device }, "9.9.9.9"), env)).status).not.toBe(429);
    for (let i = 0; i < 5; i++) expect((await app.request("/auth/start", post({ email: "same@b.co", device }, `8.8.${i}.8`), env)).status).not.toBe(429);
    const res = await app.request("/auth/start", post({ email: "same@b.co", device }, "8.8.9.8"), env);
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "slow_down" });
    expect(Number(res.headers.get("retry-after"))).toBeGreaterThan(0);
  });
  it("thirty starts an hour from one address", async () => {
    supabase();
    const app = createApp({ log: null });
    for (let i = 0; i < 30; i++) expect((await app.request("/auth/start", post({ email: `p${i}@b.co`, device }, "9.9.9.9"), env)).status).not.toBe(429);
    expect((await app.request("/auth/start", post({ email: "p31@b.co", device }, "9.9.9.9"), env)).status).toBe(429);
  });
  it("the attempt counters live in Postgres, keyed by hashes, so a redeploy does not reset them", async () => {
    const hits = new Map<string, number>();
    const s = supabase({ hits });
    for (let i = 0; i < 5; i++) await createApp({ log: null }).request("/auth/start", post({ email: "same@b.co", device }, `8.8.${i}.8`), env);
    supabase({ hits }); // a fresh process, the same database
    expect((await createApp({ log: null }).request("/auth/start", post({ email: "same@b.co", device }, "8.8.8.1"), env)).status).toBe(429);
    const keys = s.calls.filter((c) => c.url.endsWith("/rpc/oc_rate_hit")).map((c) => c.body.p_key as string);
    expect(keys.length).toBeGreaterThan(0);
    expect(keys.join(" ")).not.toMatch(/same@b\.co|8\.8\./);
  });
  it("without the counter table (schema not applied yet) attempts are still counted, in memory", async () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    supabase({ rateFails: true });
    const app = createApp({ log: null });
    for (let i = 0; i < 5; i++) expect((await app.request("/auth/start", post({ email: "same@b.co", device }, `7.7.${i}.7`), env)).status).not.toBe(429);
    expect((await app.request("/auth/start", post({ email: "same@b.co", device }, "7.7.9.7"), env)).status).toBe(429);
    expect(JSON.stringify(err.mock.calls)).toContain("in memory");
  });
  it("never leaks GoTrue text or logs the email's session", async () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    supabase({ attach: () => new Response('{"msg":"internal secret"}', { status: 500 }) });
    const res = await start({ email: "gran@example.com", device });
    expect(JSON.stringify(await res.json())).not.toContain("secret");
    expect(JSON.stringify(err.mock.calls)).not.toContain("acc");
  });
});

describe("POST /auth/start: guest farming (F-38)", () => {
  const devices = ["a", "b", "c", "e", "f", "0", "1", "2"].map((ch) => ch.repeat(64));
  const liveGuests = (s: ReturnType<typeof supabase>) => s.rows.filter((r) => s.users[r.user_id]?.is_anonymous && !r.replaced_at);

  it("three device hashes from one address do not make three live guests: the third gets a sign-up code", async () => {
    const s = supabase();
    const app = createApp({ log: null });
    const answers = [];
    for (let i = 0; i < 3; i++) answers.push(await (await app.request("/auth/start", post({ email: `farm${i}@x.co`, device: devices[i] }, "203.0.113.7"), env)).json());
    expect(answers.map((a) => a.status)).toEqual(["signed_in", "signed_in", "code_sent"]);
    expect(liveGuests(s)).toHaveLength(2);
    const otp = s.calls.filter((c) => c.url.endsWith("/auth/v1/otp"));
    expect(otp).toHaveLength(1);
    expect(otp[0].body).toEqual({ email: "farm2@x.co", create_user: true });
  });
  it("guests carry keyed hashes of their address and network, never the address", async () => {
    const s = supabase();
    await start({ email: "gran@example.com", device }, "203.0.113.7");
    const row = s.rows[0];
    expect(row.ip_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(row.net_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(row.ip_hash).not.toBe(row.net_hash);
    expect(JSON.stringify(s.calls)).not.toContain("203.0.113");
  });
  it("hopping addresses inside one /24 still meets the network cap", async () => {
    const s = supabase();
    const app = createApp({ log: null });
    const statuses = [];
    for (let i = 0; i < 7; i++) statuses.push((await (await app.request("/auth/start", post({ email: `hop${i}@x.co`, device: devices[i] }, `198.51.100.${i + 1}`), env)).json()).status);
    expect(statuses.slice(0, 6).every((x) => x === "signed_in")).toBe(true);
    expect(statuses[6]).toBe("code_sent");
    expect(liveGuests(s)).toHaveLength(6);
  });
  it("re-entering an email on your own Mac is not held against your address", async () => {
    const s = supabase();
    const app = createApp({ log: null });
    const go = async (email: string, d: string) => (await app.request("/auth/start", post({ email, device: d }, "203.0.113.9"), env)).json();
    expect((await go("me@x.co", devices[0])).status).toBe("signed_in");
    expect((await go("partner@x.co", devices[1])).status).toBe("signed_in");
    expect((await go("me@x.co", devices[0])).status).toBe("signed_in");
    expect(liveGuests(s)).toHaveLength(2);
  });
  it("a full guest pool sends a sign-up code instead of locking newcomers out", async () => {
    const s = supabase({ guestsFull: true });
    const res = await start({ email: "newcomer@x.co", device });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "code_sent" });
    expect(s.calls.some((c) => c.url.endsWith("/auth/v1/signup"))).toBe(false);
  });
  it("a database hiccup is 503 accounts_unavailable, not accounts_full (F-43)", async () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    supabase({ roomFails: true });
    const res = await start({ email: "newcomer@x.co", device });
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "accounts_unavailable" });
    expect(JSON.stringify(err.mock.calls)).toContain("oc_signup_room");
  });
});

describe("POST /auth/code", () => {
  const code = (body: unknown, ip?: string) => createApp({ log: null }).request("/auth/code", post(body, ip), env);
  it("verifies, stamps confirmation on the row, and returns the session", async () => {
    const s = supabase({ rows: [{ user_id: "u-old", email: "gran@example.com", device_hash: device, confirmed_at: null, replaced_at: null }] });
    const res = await code({ email: "Gran@example.com", code: "123456" });
    expect(await res.json()).toEqual({ status: "signed_in", session: { access_token: "acc", refresh_token: "ref", expires_in: 3600 }, confirmed: true });
    expect(s.rows[0].confirmed_at).not.toBeNull();
  });
  it("creates the row for a confirmed auth user that has none, when accounts are open", async () => {
    const s = supabase();
    const res = await code({ email: "gran@example.com", code: "123456" });
    expect((await res.json()).status).toBe("signed_in");
    expect(s.rows).toContainEqual(expect.objectContaining({ user_id: "u-old", email: "gran@example.com" }));
    expect(s.rows[0].confirmed_at).not.toBeNull();
  });
  it("402 accounts_full, no row and no session, when a row-less user arrives and accounts are closed", async () => {
    const s = supabase({ open: false });
    const res = await code({ email: "gran@example.com", code: "123456" });
    expect(res.status).toBe(402);
    expect(await res.json()).toEqual({ error: "accounts_full" });
    expect(s.rows).toHaveLength(0);
    const s2 = supabase();
    const res2 = await createApp({ log: null }).request("/auth/code", post({ email: "gran@example.com", code: "123456" }, "6.6.6.6"), { ...env, ACCOUNTS_OPEN: "false" });
    expect(res2.status).toBe(402);
    expect(JSON.stringify(await res2.json())).not.toContain("access_token");
    expect(s2.rows).toHaveLength(0);
  });
  it("a row-less user whose insert fails gets 502 and no session", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    supabase({ insertFails: 1 });
    const res = await code({ email: "gran@example.com", code: "123456" });
    expect(res.status).toBe(502);
    expect(JSON.stringify(await res.json())).not.toContain("access_token");
  });
  it("a legacy row with no email gets it on sign-in (F-43)", async () => {
    const s = supabase({ rows: [{ user_id: "u-old", email: null, device_hash: null, confirmed_at: "2026-09-01T00:00:00Z", replaced_at: null }] });
    expect((await code({ email: "gran@example.com", code: "123456" })).status).toBe(200);
    expect(s.rows[0].email).toBe("gran@example.com");
  });
  it("the first sign-in by code signs out every other session on the account; later ones do not (F-42)", async () => {
    const s = supabase({ rows: [{ user_id: "u-old", email: "gran@example.com", device_hash: device, confirmed_at: "2026-10-01T00:00:00Z", replaced_at: null }] });
    expect((await code({ email: "gran@example.com", code: "123456" })).status).toBe(200);
    const logouts = () => s.calls.filter((c) => c.url.endsWith("/auth/v1/logout?scope=others"));
    expect(logouts()).toHaveLength(1);
    expect(logouts()[0].auth).toBe("Bearer acc");
    expect(s.rows[0].code_signed_in_at).toBeTruthy();
    expect((await code({ email: "gran@example.com", code: "123456" }, "6.6.6.7")).status).toBe(200);
    expect(logouts()).toHaveLength(1);
  });
  it("still signs in when signing out the other sessions fails, and logs it", async () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    const s = supabase({ rows: [{ user_id: "u-old", email: "gran@example.com", device_hash: device, confirmed_at: "2026-10-01T00:00:00Z", replaced_at: null }] });
    const realFetch = globalThis.fetch;
    vi.stubGlobal("fetch", vi.fn(async (input: any, init: any) => (String(input).includes("/logout") ? new Response("{}", { status: 500 }) : realFetch(input, init))));
    expect((await code({ email: "gran@example.com", code: "123456" })).status).toBe(200);
    expect(JSON.stringify(err.mock.calls)).toContain("other sessions");
    expect(s.rows[0].code_signed_in_at).toBeTruthy();
  });
  it("a row-less user is not held to the guest pool: a code proves the mailbox", async () => {
    const s = supabase({ guestsFull: true });
    expect((await code({ email: "gran@example.com", code: "123456" })).status).toBe(200);
    expect(s.rows).toContainEqual(expect.objectContaining({ user_id: "u-old", email: "gran@example.com" }));
  });
  it("a database hiccup for a row-less user is 503 accounts_unavailable, not accounts_full (F-43)", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const s = supabase({ roomFails: true });
    const res = await code({ email: "gran@example.com", code: "123456" });
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "accounts_unavailable" });
    expect(s.rows).toHaveLength(0);
  });
  it("a classroom behind one address can all type their codes", async () => {
    supabase();
    const app = createApp({ log: null });
    for (let i = 0; i < 25; i++) expect((await app.request("/auth/code", post({ email: `pupil${i}@school.example`, code: "123456" }, "7.7.7.7"), env)).status).toBe(200);
  });
  it("429 slow_down on the 11th code for one email in an hour, whatever the address", async () => {
    supabase({ rows: [{ user_id: "u-old", email: "gran@example.com", device_hash: device, confirmed_at: "2026-10-01T00:00:00Z", replaced_at: null }] });
    const app = createApp({ log: null });
    for (let i = 0; i < 10; i++) expect((await app.request("/auth/code", post({ email: "gran@example.com", code: "123456" }, `7.7.${i}.7`), env)).status).toBe(200);
    const res = await app.request("/auth/code", post({ email: "gran@example.com", code: "123456" }, "7.7.99.7"), env);
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "slow_down" });
  });
  it("a wrong or expired code is 401 bad_code; a malformed one is 400", async () => {
    supabase({ verify: () => new Response('{"error_code":"otp_expired"}', { status: 403 }) });
    expect(await (await code({ email: "a@b.co", code: "000000" })).json()).toEqual({ error: "bad_code" });
    expect((await code({ email: "a@b.co", code: "12345" }, "5.5.5.5")).status).toBe(400);
  });
});

describe("POST /auth/resend", () => {
  it("needs a token", async () => {
    supabase();
    expect((await createApp({ log: null }).request("/auth/resend", { method: "POST" }, env)).status).toBe(401);
  });

  const token = () => new SignJWT({ role: "authenticated" }).setProtectedHeader({ alg: "HS256" }).setAudience("authenticated").setSubject("u-guest").setIssuedAt().setExpirationTime("10m").sign(new TextEncoder().encode(env.SUPABASE_JWT_SECRET));
  const resend = async () => createApp({ log: null }).request("/auth/resend", { method: "POST", headers: { authorization: `Bearer ${await token()}` } }, env);
  const guestRow: Row = { user_id: "u-guest", email: "gran@example.com", device_hash: device, confirmed_at: null, replaced_at: null };
  it("re-sends the confirmation link for a guest, attaching with the caller's own token", async () => {
    const jwt = await token();
    const s = supabase({ rows: [guestRow], users: { "u-guest": { is_anonymous: true } } });
    const res = await createApp({ log: null }).request("/auth/resend", { method: "POST", headers: { authorization: `Bearer ${jwt}` } }, env);
    expect(await res.json()).toEqual({ status: "sent" });
    const attach = s.calls.find((c) => c.url.includes("/auth/v1/user") && c.method === "PUT")!;
    expect(attach.body).toEqual({ email: "gran@example.com" });
    expect(attach.auth).toBe(`Bearer ${jwt}`);
  });
  it("says already_confirmed when the user is no longer anonymous", async () => {
    const s = supabase({ rows: [guestRow], users: { "u-guest": { is_anonymous: false } } });
    expect(await (await resend()).json()).toEqual({ status: "already_confirmed" });
    expect(s.calls.some((c) => c.url.includes("/auth/v1/user"))).toBe(false);
  });
  it("429 on the 4th resend for one user", async () => {
    supabase({ rows: [guestRow], users: { "u-guest": { is_anonymous: true } } });
    const jwt = await token();
    const app = createApp({ log: null });
    const go = () => app.request("/auth/resend", { method: "POST", headers: { authorization: `Bearer ${jwt}` } }, env);
    for (let i = 0; i < 3; i++) expect((await go()).status).toBe(200);
    const res = await go();
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "slow_down" });
  });
  it("a backend session token gets 400 bad_request without calling GoTrue", async () => {
    const s = supabase();
    const { token: st } = await issueSessionToken({ sub: "u-guest" }, { ...env, SESSION_TOKEN_SECRET: "s".repeat(40) });
    const res = await createApp({ log: null }).request("/auth/resend", { method: "POST", headers: { authorization: `Bearer ${st}` } }, { ...env, SESSION_TOKEN_SECRET: "s".repeat(40) });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "bad_request" });
    expect(s.calls).toHaveLength(0);
  });
});

describe("POST /auth/confirm (a guest types the code from the confirmation mail, F-42)", () => {
  const token = () => new SignJWT({ role: "authenticated" }).setProtectedHeader({ alg: "HS256" }).setAudience("authenticated").setSubject("u-guest").setIssuedAt().setExpirationTime("10m").sign(new TextEncoder().encode(env.SUPABASE_JWT_SECRET));
  const confirm = async (body: unknown, app = createApp({ log: null })) =>
    app.request("/auth/confirm", { method: "POST", headers: { authorization: `Bearer ${await token()}`, "content-type": "application/json", "x-forwarded-for": "1.2.3.4" }, body: JSON.stringify(body) }, env);
  const guestRow: Row = { user_id: "u-guest", email: "gran@example.com", device_hash: device, confirmed_at: null, replaced_at: null };
  const guestSession = () => new Response(JSON.stringify({ ...session, access_token: "acc-confirmed", user: { id: "u-guest" } }));

  it("needs the guest's session", async () => {
    supabase();
    expect((await createApp({ log: null }).request("/auth/confirm", { method: "POST", body: '{"code":"123456"}' }, env)).status).toBe(401);
  });
  it("confirms the pending email with the code, signs out every other session, and returns the confirmed session", async () => {
    const s = supabase({ rows: [guestRow], users: { "u-guest": { is_anonymous: true } }, verify: guestSession });
    const res = await confirm({ code: "123456" });
    expect(await res.json()).toEqual({ status: "signed_in", session: { access_token: "acc-confirmed", refresh_token: "ref", expires_in: 3600 }, confirmed: true });
    const verify = s.calls.find((c) => c.url.endsWith("/auth/v1/verify"))!;
    expect(verify.body).toEqual({ type: "email_change", email: "gran@example.com", token: "123456" });
    expect(s.calls.find((c) => c.url.endsWith("/auth/v1/logout?scope=others"))!.auth).toBe("Bearer acc-confirmed");
    expect(s.rows[0].confirmed_at).toBeTruthy();
    expect(s.rows[0].code_signed_in_at).toBeTruthy();
  });
  it("a wrong code is 401 bad_code and changes nothing", async () => {
    const s = supabase({ rows: [guestRow], users: { "u-guest": { is_anonymous: true } }, verify: () => new Response('{"error_code":"otp_expired"}', { status: 403 }) });
    const res = await confirm({ code: "000000" });
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "bad_code" });
    expect(s.rows[0].confirmed_at).toBeNull();
    expect((await confirm({ code: "12" })).status).toBe(400);
  });
  it("says already_confirmed when the account is confirmed already", async () => {
    const s = supabase({ rows: [guestRow], users: { "u-guest": { is_anonymous: false } } });
    expect(await (await confirm({ code: "123456" })).json()).toEqual({ status: "already_confirmed" });
    expect(s.calls.some((c) => c.url.endsWith("/auth/v1/verify"))).toBe(false);
  });
  it("ten tries an hour per guest", async () => {
    supabase({ rows: [guestRow], users: { "u-guest": { is_anonymous: true } }, verify: () => new Response('{"error_code":"otp_expired"}', { status: 403 }) });
    const app = createApp({ log: null });
    for (let i = 0; i < 10; i++) expect((await confirm({ code: "000000" }, app)).status).toBe(401);
    expect((await confirm({ code: "000000" }, app)).status).toBe(429);
  });
});

describe("GET /auth/config", () => {
  const config = async () => (await createApp({ log: null }).request("/auth/config", {}, env)).json();
  it("stays open while confirmed accounts have room, even with the guest pool full", async () => {
    supabase({ guestsFull: true });
    expect((await config()).accountsOpen).toBe(true);
    supabase({ open: false });
    expect((await config()).accountsOpen).toBe(false);
  });
  it("a database hiccup leaves accountsOpen unknown (null), not 'full' (F-43)", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    supabase({ roomFails: true });
    expect((await config()).accountsOpen).toBeNull();
  });
});

describe("addressBlocks", () => {
  it("IPv4: the host, and its /24", () => {
    expect(addressBlocks("203.0.113.7")).toEqual({ host: "203.0.113.7", net: "203.0.113.0/24" });
    expect(addressBlocks("::ffff:203.0.113.7")).toEqual({ host: "203.0.113.7", net: "203.0.113.0/24" });
  });
  it("IPv6: the /64 a single home gets, and its /48", () => {
    expect(addressBlocks("2001:db8:1:2:aaaa::1")).toEqual({ host: "2001:db8:1:2::/64", net: "2001:db8:1::/48" });
    expect(addressBlocks("2001:DB8:1:2:bbbb:cccc:dddd:eeee")).toEqual({ host: "2001:db8:1:2::/64", net: "2001:db8:1::/48" });
    expect(addressBlocks("2001:db8::1")).toEqual({ host: "2001:db8:0:0::/64", net: "2001:db8:0::/48" });
  });
  it("anything else is its own host with no network", () => {
    expect(addressBlocks("unknown")).toEqual({ host: "unknown", net: null });
  });
});
