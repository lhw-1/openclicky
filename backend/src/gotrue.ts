/**
 * The Supabase Auth (GoTrue) calls the backend makes for email-first accounts. The app never talks
 * to GoTrue for these: the backend fronts them so it can enforce the caps. Errors keep GoTrue's
 * status and error_code only — its message text never leaves this file.
 */
export type GoTrueSession = { access_token: string; refresh_token: string; expires_in: number; user: { id: string } };

export class GoTrueError extends Error {
  constructor(readonly status: number, readonly code: string) {
    super(`GoTrue ${status} ${code}`);
  }
}

export class GoTrue {
  private readonly base: string;
  constructor(url: string, private readonly publishableKey: string, private readonly serviceKey: string,
    private readonly fetchImpl: typeof fetch = (...args) => fetch(...args)) {
    this.base = `${url.replace(/\/+$/, "")}/auth/v1`;
  }

  private async call(path: string, init: { method?: string; body?: unknown; token?: string; admin?: boolean }): Promise<unknown> {
    const key = init.admin ? this.serviceKey : this.publishableKey;
    const res = await this.fetchImpl(`${this.base}${path}`, {
      method: init.method ?? "POST",
      headers: { "content-type": "application/json", apikey: key, Authorization: `Bearer ${init.token ?? key}` },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
    });
    const text = await res.text();
    if (!res.ok) {
      let code = `http_${res.status}`;
      try { const j = JSON.parse(text) as { error_code?: string }; if (j.error_code) code = j.error_code; } catch { /* keep http_<status> */ }
      throw new GoTrueError(res.status, code);
    }
    if (!text) return undefined;
    try { return JSON.parse(text); } catch { throw new GoTrueError(res.status, "bad_response"); }
  }

  signUpAnonymously(): Promise<GoTrueSession> {
    return this.call("/signup", { body: {} }) as Promise<GoTrueSession>;
  }
  /** GoTrue mails a confirmation link to `email`; clicking it makes the anonymous user permanent. Calling it again re-sends. */
  async attachEmail(accessToken: string, email: string, redirectTo: string): Promise<void> {
    await this.call(`/user?redirect_to=${encodeURIComponent(redirectTo)}`, { method: "PUT", body: { email }, token: accessToken });
  }
  async sendCode(email: string): Promise<void> {
    await this.call("/otp", { body: { email, create_user: false } });
  }
  /** A code for an email with no account yet: the user is created by GoTrue but only confirmed by the code. */
  async sendSignupCode(email: string): Promise<void> {
    await this.call("/otp", { body: { email, create_user: true } });
  }
  verifyCode(email: string, code: string): Promise<GoTrueSession> {
    return this.call("/verify", { body: { type: "email", email, token: code } }) as Promise<GoTrueSession>;
  }
  /** The code in a guest's confirmation mail: confirms the pending email and returns a session for that user. */
  verifyEmailChange(email: string, code: string): Promise<GoTrueSession> {
    return this.call("/verify", { body: { type: "email_change", email, token: code } }) as Promise<GoTrueSession>;
  }
  /** Signs out every session of the token's user except the token's own (refresh tokens stop working). */
  async signOutOthers(accessToken: string): Promise<void> {
    await this.call("/logout?scope=others", { token: accessToken });
  }
  async getUser(userId: string): Promise<{ id: string; is_anonymous: boolean; email: string | null } | null> {
    try {
      const u = (await this.call(`/admin/users/${encodeURIComponent(userId)}`, { method: "GET", admin: true })) as { id: string; is_anonymous?: boolean; email?: string };
      return { id: u.id, is_anonymous: Boolean(u.is_anonymous), email: u.email || null };
    } catch (e) {
      if (e instanceof GoTrueError && e.status === 404) return null;
      throw e;
    }
  }
  async deleteUser(userId: string): Promise<void> {
    await this.call(`/admin/users/${encodeURIComponent(userId)}`, { method: "DELETE", admin: true });
  }
}
