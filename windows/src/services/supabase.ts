// Client Supabase minimal (Auth + PostgREST), pendant de StudyTrack/Services/SupabaseClient.swift.
//
// Même règle que côté Swift : **un seul rafraîchissement de jeton à la fois**.
// Supabase fait tourner le jeton de rafraîchissement à chaque usage ; deux
// requêtes qui le présentent ensemble font prendre la seconde pour un vol, et la
// session entière est révoquée (« la connexion qui ne tient pas »).

export interface Session {
  access_token: string;
  refresh_token: string;
  /** Secondes depuis l'époque Unix. */
  expires_at: number;
  user: { id: string; email?: string };
}

export interface SessionStore {
  load(): Promise<Session | null>;
  save(session: Session | null): Promise<void>;
}

export class SupabaseError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

export interface RequestOptions {
  method?: string;
  body?: unknown;
  prefer?: string;
  auth?: boolean;
}

export class SupabaseClient {
  private session: Session | null = null;
  private refreshing: Promise<void> | null = null;
  private loaded = false;

  constructor(
    readonly url: string,
    readonly anonKey: string,
    readonly sessions: SessionStore,
    private readonly fetchImpl: typeof fetch = (...a) => fetch(...a),
  ) {}

  private async current(): Promise<Session | null> {
    if (!this.loaded) { this.session = await this.sessions.load(); this.loaded = true; }
    return this.session;
  }

  async userId(): Promise<string | null> {
    return (await this.current())?.user.id ?? null;
  }

  async signInWithPassword(email: string, password: string): Promise<Session> {
    const s = await this.authCall("token?grant_type=password", { email, password });
    await this.setSession(s);
    return s;
  }

  async signOut(): Promise<void> { await this.setSession(null); }

  async setSession(s: Session | null): Promise<void> {
    this.session = s;
    this.loaded = true;
    await this.sessions.save(s);
  }

  async request<T = unknown>(path: string, opts: RequestOptions = {}): Promise<T> {
    const auth = opts.auth ?? true;
    if (auth) {
      const s = await this.current();
      if (!s) throw new SupabaseError(401, "Session absente : connecte-toi dans Réglages › Compte.");
      // Une minute de marge : le jeton ne doit pas expirer en chemin.
      if (s.expires_at * 1000 < Date.now() + 60_000) await this.refresh();
    }
    let res = await this.send(path, opts, auth);
    if (res.status === 401 && auth && this.session) {
      await this.refresh(true);
      res = await this.send(path, opts, auth);
    }
    const text = await res.text();
    if (!res.ok) throw new SupabaseError(res.status, text || res.statusText);
    return (text ? JSON.parse(text) : null) as T;
  }

  private send(path: string, opts: RequestOptions, auth: boolean): Promise<Response> {
    const headers: Record<string, string> = {
      apikey: this.anonKey,
      Authorization: `Bearer ${auth && this.session ? this.session.access_token : this.anonKey}`,
    };
    if (opts.body !== undefined) headers["Content-Type"] = "application/json";
    if (opts.prefer) headers.Prefer = opts.prefer;
    return this.fetchImpl(`${this.url}${path}`, {
      method: opts.method ?? "GET",
      headers,
      body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
    });
  }

  private refresh(force = false): Promise<void> {
    this.refreshing ??= (async () => {
      const s = this.session;
      if (!s) return;
      if (!force && s.expires_at * 1000 >= Date.now() + 60_000) return;
      try {
        await this.setSession(await this.authCall("token?grant_type=refresh_token", { refresh_token: s.refresh_token }));
      } catch (e) {
        // Jeton refusé : la session est perdue, on l'oublie plutôt que de
        // la représenter en boucle.
        if (e instanceof SupabaseError && (e.status === 400 || e.status === 401)) await this.setSession(null);
        throw e;
      }
    })().finally(() => { this.refreshing = null; });
    return this.refreshing;
  }

  private async authCall(path: string, body: unknown): Promise<Session> {
    const res = await this.fetchImpl(`${this.url}/auth/v1/${path}`, {
      method: "POST",
      headers: { apikey: this.anonKey, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const text = await res.text();
    if (!res.ok) throw new SupabaseError(res.status, text || res.statusText);
    const raw = JSON.parse(text) as Session & { expires_in?: number };
    return {
      access_token: raw.access_token,
      refresh_token: raw.refresh_token,
      expires_at: raw.expires_at ?? Math.floor(Date.now() / 1000) + (raw.expires_in ?? 3600),
      user: raw.user,
    };
  }
}
