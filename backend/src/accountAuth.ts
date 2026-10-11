import type { Context, Hono } from "hono";
import { getEnv, type Env } from "./env.js";
import { requireAuth, bearerFrom, type Principal } from "./auth.js";
import { SupabaseRest } from "./db.js";
import { GoTrue, GoTrueError, type GoTrueSession } from "./gotrue.js";

/**
 * Email-first accounts. Setup sends only an email and this Mac's device hash: a new email becomes a
 * guest at once (an anonymous Supabase user with the email attached, which mails a confirmation);
 * an email that already has a confirmed account gets a 6-digit code instead. The caps live here and
 * in Postgres, which is why the app never talks to GoTrue for these.
 *
 * Guest farming (deep test F-38): a device hash is whatever the client sends, so the guest caps are
 * per address and per network (oc_signup_room), and an address or a guest pool that is full gets a
 * sign-up code instead of a guest: that still lets a newcomer in, but only with a real mailbox.
 */
const HOUR = 3_600_000;

/** Seconds until `key` may try again (0 when this attempt is allowed and counted), over the last `windowMs` (an hour). */
export function waitSeconds(hits: Map<string, number[]>, key: string, limit: number, now = Date.now(), windowMs = HOUR): number {
  for (const [k, v] of hits) { const live = v.filter((t) => now - t < windowMs); if (live.length) hits.set(k, live); else hits.delete(k); }
  const mine = hits.get(key) ?? [];
  if (mine.length >= limit) return Math.max(1, Math.ceil((mine[0] + windowMs - now) / 1000));
  hits.set(key, [...mine, now]);
  return 0;
}
export function allow(hits: Map<string, number[]>, key: string, limit: number, now = Date.now()): boolean {
  return waitSeconds(hits, key, limit, now) === 0;
}

export function normalizeEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const email = raw.trim().toLowerCase();
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) && email.length <= 254 ? email : null;
}
export const isDeviceHash = (raw: unknown): raw is string => typeof raw === "string" && /^[0-9a-f]{64}$/.test(raw);

/**
 * The blocks an address belongs to: for IPv4 the host and its /24; for IPv6 the /64 one home or
 * phone is given (a host can pick any address inside it) and its /48. Anything unparseable is its
 * own host with no network.
 */
export function addressBlocks(ip: string): { host: string; net: string | null } {
  const mapped = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i.exec(ip);
  const v4 = mapped ? mapped[1] : ip;
  if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(v4) && v4.split(".").every((p) => Number(p) <= 255)) {
    const parts = v4.split(".").map(Number);
    return { host: parts.join("."), net: `${parts.slice(0, 3).join(".")}.0/24` };
  }
  const groups = ipv6Groups(ip.split("%")[0]);
  if (!groups) return { host: ip, net: null };
  return { host: `${groups.slice(0, 4).join(":")}::/64`, net: `${groups.slice(0, 3).join(":")}::/48` };
}

function ipv6Groups(ip: string): string[] | null {
  const halves = ip.toLowerCase().split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(":") : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const missing = 8 - head.length - tail.length;
  if (halves.length === 1 ? missing !== 0 : missing < 1) return null;
  const groups = [...head, ...Array(halves.length === 2 ? missing : 0).fill("0"), ...tail];
  if (!groups.every((g) => /^[0-9a-f]{1,4}$/.test(g))) return null;
  return groups.map((g) => g.replace(/^0+(?=.)/, ""));
}

/** A keyed hash, so neither addresses nor emails are stored, and a leaked table cannot be reversed by brute force. */
export async function keyedHash(secret: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value)));
  return Array.from(mac, (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Hourly limits on sign-in attempts. Guest farming is held back by the live-guest caps in Postgres,
 * not by these, so they can be generous enough for a class or a lab behind one address (F-43): per
 * email they stop a mailbox being flooded with mail or a code being guessed, per address they stop a
 * flood. "send a new code" is another /auth/start, so five per email leaves room for it.
 */
const START_PER_ADDRESS = 30, START_PER_EMAIL = 5;
const CODE_PER_ADDRESS = 60, CODE_PER_EMAIL = 10;
const RESEND_PER_USER = 3, CONFIRM_PER_USER = 10;

type Limit = { key: string; perHour: number };
/** Counts in Postgres, so a deploy does not reset them; in this process's memory when Postgres can't. */
class AttemptCounter {
  private readonly memory = new Map<string, number[]>();
  private lastWarning = 0;
  /** Seconds to wait, or 0 when every limit allows the attempt (it is then counted against each). */
  async wait(db: SupabaseRest, limits: Limit[]): Promise<number> {
    for (const { key, perHour } of limits) {
      let seconds: number;
      try {
        seconds = Number(await db.rpc<number>("oc_rate_hit", { p_key: key, p_limit: perHour, p_window_seconds: HOUR / 1000 })) || 0;
      } catch (e) {
        if (Date.now() - this.lastWarning > 60_000) {
          this.lastWarning = Date.now();
          console.error(`auth: attempt counter unavailable, counting in memory: ${(e as Error).message}`);
        }
        seconds = waitSeconds(this.memory, key, perHour);
      }
      if (seconds > 0) return seconds;
    }
    return 0;
  }
}

type Row = { user_id: string; email: string | null; confirmed_at: string | null; replaced_at: string | null; code_signed_in_at?: string | null };
type Room = { accounts: boolean; guests: boolean };
const clientSession = (s: GoTrueSession) => ({ access_token: s.access_token, refresh_token: s.refresh_token, expires_in: s.expires_in });
export const ipOf = (c: Context) => c.req.header("x-forwarded-for")?.split(",")[0]?.trim() || c.req.header("x-real-ip") || "unknown";
const enc = encodeURIComponent;
const nowIso = () => new Date().toISOString();
const guestDays = (env: Env) => Number(env.GUEST_DAYS) || 14;

async function body(c: Context): Promise<Record<string, unknown>> {
  try { const v = JSON.parse((await c.req.text()) || "{}"); return v && typeof v === "object" ? v as Record<string, unknown> : {}; } catch { return {}; }
}

/** Room for a confirmed account, and for a guest from this address and network (null: not asked). */
export function signupRoom(db: SupabaseRest, env: Env, from: { host: string; net: string | null } | null, device: string | null): Promise<Room> {
  return db.rpc<Room>("oc_signup_room", { p_guest_days: guestDays(env), p_ip_hash: from?.host ?? null, p_net_hash: from?.net ?? null, p_device: device });
}

export function registerAccountAuth(app: Hono<any>) {
  const attempts = new AttemptCounter();

  const clients = (c: Context) => {
    const env = getEnv(c);
    if (!env.SUPABASE_URL || !env.SUPABASE_PUBLISHABLE_KEY || !env.SUPABASE_SERVICE_KEY) return null;
    return {
      env,
      db: new SupabaseRest(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY),
      gt: new GoTrue(env.SUPABASE_URL, env.SUPABASE_PUBLISHABLE_KEY, env.SUPABASE_SERVICE_KEY),
      redirect: env.ACCOUNT_CONFIRM_REDIRECT_URL || `${new URL(c.req.url).origin}/auth/confirmed`,
      // The service key is secret and always set here; IP_HASH_SALT lets it rotate without resetting the caps.
      salt: env.IP_HASH_SALT || env.SUPABASE_SERVICE_KEY,
    };
  };
  type Clients = NonNullable<ReturnType<typeof clients>>;
  const hashedAddress = async (k: Clients, c: Context) => {
    const blocks = addressBlocks(ipOf(c));
    return { host: await keyedHash(k.salt, `ip:${blocks.host}`), net: blocks.net ? await keyedHash(k.salt, `net:${blocks.net}`) : null };
  };
  const notConfigured = (c: Context) => c.json({ error: "sign-in is not configured on this backend" }, 404);
  const slowDown = (c: Context, seconds: number) => c.json({ error: "slow_down" }, 429, { "Retry-After": String(seconds) });
  const failed = (c: Context, where: string, e: unknown) => {
    if (e instanceof GoTrueError && e.status === 429) return c.json({ error: "slow_down" }, 429);
    console.error(`${where}: ${e instanceof GoTrueError ? e.message : (e as Error).message}`);
    return c.json({ error: "auth_unavailable" }, 502);
  };
  /** The caps could not be read: say so, rather than "free accounts are full" (F-43). */
  const accountsUnavailable = (c: Context, where: string, e: unknown) => {
    console.error(`${where}: oc_signup_room: ${(e as Error).message}`);
    return c.json({ error: "accounts_unavailable" }, 503);
  };
  const accountsFull = (c: Context) => c.json({ error: "accounts_full" }, 402);

  /**
   * A code proved this person holds the mailbox. Make sure the account row says so, and the first
   * time, sign out every other session: whoever typed this email on another Mac and had the link
   * clicked for them loses the account here (F-42).
   */
  const finishCodeSignIn = async (c: Context, k: Clients, where: string, session: GoTrueSession, email: string, device: string | null) => {
    const { env, db, gt } = k;
    const id = session.user.id;
    let rows: Row[] | null = null;
    try { rows = await db.select<Row>("oc_accounts", `user_id=eq.${enc(id)}&select=user_id,email,confirmed_at,code_signed_in_at`); }
    catch (e) { console.error(`${where}: account row read: ${(e as Error).message}`); }
    let firstCodeSignIn = true;
    if (rows?.length) {
      const row = rows[0];
      firstCodeSignIn = !row.code_signed_in_at;
      const fields: Record<string, unknown> = {};
      if (!row.confirmed_at) fields.confirmed_at = nowIso();
      if (!row.email) fields.email = email; // a row from before email-first accounts (F-43)
      if (firstCodeSignIn) fields.code_signed_in_at = nowIso();
      if (Object.keys(fields).length) {
        await db.update("oc_accounts", `user_id=eq.${enc(id)}`, fields)
          .catch((e) => console.error(`${where}: account row: ${(e as Error).message}`)); // signed in anyway; oc_confirmed stamps it on first use
      }
    } else {
      // No row: a new confirmed account. A code proved the mailbox, so only the confirmed-account cap applies.
      if (env.ACCOUNTS_OPEN !== "true") return accountsFull(c);
      let room: Room;
      try { room = await signupRoom(db, env, null, null); }
      catch (e) { return accountsUnavailable(c, where, e); }
      if (!room.accounts) return accountsFull(c);
      try {
        if (rows === null) throw new Error("account row unreadable");
        await db.insert("oc_accounts", { user_id: id, email, confirmed_at: nowIso(), code_signed_in_at: nowIso(), ...(device ? { device_hash: device } : {}) });
      } catch (e) {
        return failed(c, where, e);
      }
    }
    if (firstCodeSignIn) {
      await gt.signOutOthers(session.access_token)
        .catch((e) => console.error(`${where}: signing out the other sessions: ${(e as Error).message}`));
    }
    return c.json({ status: "signed_in", session: clientSession(session), confirmed: true });
  };

  app.post("/auth/start", async (c) => {
    const k = clients(c);
    if (!k) return notConfigured(c);
    const req = await body(c);
    const email = normalizeEmail(req.email);
    if (!email) return c.json({ error: "bad_email" }, 400);
    if (!isDeviceHash(req.device)) return c.json({ error: "bad_request" }, 400);
    const device = req.device;
    const { env, db, gt, redirect } = k;
    const from = await hashedAddress(k, c);
    const wait = await attempts.wait(db, [
      { key: `start:ip:${from.host}`, perHour: START_PER_ADDRESS },
      { key: `start:email:${await keyedHash(k.salt, `email:${email}`)}`, perHour: START_PER_EMAIL },
    ]);
    if (wait) return slowDown(c, wait);
    const perDevice = Number(env.MAX_ACCOUNTS_PER_DEVICE) || 2;
    const sendCode = async () => { await gt.sendCode(email); return c.json({ status: "code_sent" }); };
    try {
      if ((await db.select<Row>("oc_accounts", `email=eq.${enc(email)}&confirmed_at=not.is.null&select=user_id&limit=1`)).length) return await sendCode();
      if (env.ACCOUNTS_OPEN !== "true") return accountsFull(c);
      let room: Room;
      try { room = await signupRoom(db, env, from, device); }
      catch (e) { return accountsUnavailable(c, "auth/start", e); }
      if (!room.accounts) return accountsFull(c);

      // Sort this Mac's accounts into confirmed and live guests. auth.users decides: a link clicked
      // since the row was last read is confirmed even though confirmed_at is still empty.
      const onDevice = (await db.select<Row>("oc_accounts", `device_hash=eq.${device}&replaced_at=is.null&select=user_id,email,confirmed_at,replaced_at`)).filter((r) => !r.replaced_at);
      const confirmed: Row[] = [], guests: Row[] = [];
      for (const row of onDevice) {
        if (row.confirmed_at) { confirmed.push(row); continue; }
        const user = await gt.getUser(row.user_id);
        if (user && !user.is_anonymous) {
          await db.update("oc_accounts", `user_id=eq.${enc(row.user_id)}`, { confirmed_at: nowIso() });
          confirmed.push(row);
        } else guests.push(row);
      }
      if (confirmed.some((r) => r.email === email)) return await sendCode();
      if (confirmed.filter((r) => r.email !== email).length >= perDevice) return c.json({ error: "device_limit" }, 402);
      // No guest from here: this address, its network or the whole pool has enough. A code still lets
      // the person in (the app already asks for one), but only someone who can read that mailbox.
      if (!room.guests) { await gt.sendSignupCode(email); return c.json({ status: "code_sent" }); }
      const session = await gt.signUpAnonymously();
      const discard = () => gt.deleteUser(session.user.id).catch((e) => console.error(`auth/start: delete new guest: ${(e as Error).message}`));
      try {
        await gt.attachEmail(session.access_token, email, redirect);
      } catch (e) {
        await discard();
        if (e instanceof GoTrueError && e.code === "email_exists") return await sendCode();
        throw e;
      }
      let recorded = false;
      for (let attempt = 1; attempt <= 2 && !recorded; attempt++) {
        recorded = await db.insert("oc_accounts", { user_id: session.user.id, email, device_hash: device, ip_hash: from.host, net_hash: from.net }).then(() => true, (e) => {
          console.error(`auth/start: oc_accounts insert (try ${attempt}): ${(e as Error).message}`);
          return false;
        });
      }
      if (!recorded) { await discard(); return c.json({ error: "auth_unavailable" }, 502); }
      // Only now that the new guest exists is the old one replaced, so a failure above leaves it untouched.
      for (const guest of guests) {
        await db.update("oc_accounts", `user_id=eq.${enc(guest.user_id)}`, { replaced_at: nowIso() }).catch((e) => console.error(`auth/start: mark replaced guest: ${(e as Error).message}`));
        await gt.deleteUser(guest.user_id).catch((e) => console.error(`auth/start: delete replaced guest: ${(e as Error).message}`));
      }
      return c.json({ status: "signed_in", session: clientSession(session), confirmed: false });
    } catch (e) {
      return failed(c, "auth/start", e);
    }
  });

  app.post("/auth/code", async (c) => {
    const k = clients(c);
    if (!k) return notConfigured(c);
    const req = await body(c);
    const email = normalizeEmail(req.email);
    const code = typeof req.code === "string" ? req.code.trim() : "";
    if (!email || !/^\d{6}$/.test(code)) return c.json({ error: "bad_code" }, 400);
    const from = await hashedAddress(k, c);
    const wait = await attempts.wait(k.db, [
      { key: `code:ip:${from.host}`, perHour: CODE_PER_ADDRESS },
      { key: `code:email:${await keyedHash(k.salt, `email:${email}`)}`, perHour: CODE_PER_EMAIL },
    ]);
    if (wait) return slowDown(c, wait);
    let session: GoTrueSession;
    try { session = await k.gt.verifyCode(email, code); }
    catch (e) {
      if (e instanceof GoTrueError && e.status >= 400 && e.status < 500 && e.status !== 429) return c.json({ error: "bad_code" }, 401);
      return failed(c, "auth/code", e);
    }
    return finishCodeSignIn(c, k, "auth/code", session, email, isDeviceHash(req.device) ? req.device : null);
  });

  // A guest confirms by typing the code from the confirmation mail into the app that holds the guest
  // session, so only someone with both the mailbox and that Mac can confirm (F-42). A link that
  // confirms on its own would hand the account to whoever typed the email.
  app.post("/auth/confirm", requireAuth, async (c) => {
    const k = clients(c);
    if (!k) return notConfigured(c);
    const principal = c.get("principal" as never) as Principal;
    const req = await body(c);
    const code = typeof req.code === "string" ? req.code.trim() : "";
    if (!/^\d{6}$/.test(code)) return c.json({ error: "bad_code" }, 400);
    const { db, gt } = k;
    const wait = await attempts.wait(db, [{ key: `confirm:user:${await keyedHash(k.salt, `user:${principal.sub}`)}`, perHour: CONFIRM_PER_USER }]);
    if (wait) return slowDown(c, wait);
    let email: string;
    try {
      const user = await gt.getUser(principal.sub);
      if (user && !user.is_anonymous) return c.json({ status: "already_confirmed" });
      const [row] = await db.select<Row>("oc_accounts", `user_id=eq.${enc(principal.sub)}&select=user_id,email`);
      if (!row?.email) return c.json({ error: "bad_request" }, 400);
      email = row.email;
    } catch (e) {
      return failed(c, "auth/confirm", e);
    }
    let session: GoTrueSession;
    try { session = await gt.verifyEmailChange(email, code); }
    catch (e) {
      if (e instanceof GoTrueError && e.status >= 400 && e.status < 500 && e.status !== 429) return c.json({ error: "bad_code" }, 401);
      return failed(c, "auth/confirm", e);
    }
    // Two guests can be waiting on one email (someone else typed it too). The code belongs to one of
    // them; the person holding the mailbox gets that account and everyone else on it is signed out.
    if (session.user.id !== principal.sub) console.error("auth/confirm: the code was another guest's with the same email; signing this Mac into that account");
    return finishCodeSignIn(c, k, "auth/confirm", session, email, null);
  });

  app.post("/auth/resend", requireAuth, async (c) => {
    const k = clients(c);
    if (!k) return notConfigured(c);
    const principal = c.get("principal" as never) as Principal;
    if (principal.via !== "supabase") return c.json({ error: "bad_request" }, 400); // a backend session token can't re-attach an email
    const wait = await attempts.wait(k.db, [{ key: `resend:user:${await keyedHash(k.salt, `user:${principal.sub}`)}`, perHour: RESEND_PER_USER }]);
    if (wait) return slowDown(c, wait);
    const token = bearerFrom(c.req.header("authorization"))!;
    const { db, gt, redirect } = k;
    try {
      const user = await gt.getUser(principal.sub);
      if (user && !user.is_anonymous) return c.json({ status: "already_confirmed" });
      const [row] = await db.select<Row>("oc_accounts", `user_id=eq.${enc(principal.sub)}&select=user_id,email`);
      if (!row?.email) return c.json({ error: "bad_request" }, 400);
      await gt.attachEmail(token, row.email, redirect);
      return c.json({ status: "sent" });
    } catch (e) {
      return failed(c, "auth/resend", e);
    }
  });
}
