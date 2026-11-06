// Port de Polymestre/Domain/SupabaseSession.swift : la session Supabase telle
// qu'elle survit à un lancement. Type valeur et pur — la décision « ce jeton
// est-il encore bon ? » se teste sans réseau ni trousseau.

/** `StoredSession` : la session gardée entre deux lancements. */
export interface StoredSessionInit {
  accessToken: string;
  refreshToken?: string | null;
  userID?: string | null;
  email?: string | null;
  expiresAt: Date;
}

/** `ISO8601` de référence d'Apple (2001-01-01T00:00:00Z), pour `Codable` par défaut. */
const referenceEpoch = Date.UTC(2001, 0, 1) / 1000;

export class StoredSession {
  accessToken: string;
  refreshToken: string | null;
  userID: string | null;
  email: string | null;
  /** Instant où `accessToken` cesse d'être accepté par le serveur. */
  expiresAt: Date;

  /** Marge avant l'expiration réelle (un jeton valable 3 s ne l'est plus le temps du départ). */
  static readonly leeway = 60;

  constructor(o: StoredSessionInit) {
    this.accessToken = o.accessToken;
    this.refreshToken = o.refreshToken ?? null;
    this.userID = o.userID ?? null;
    this.email = o.email ?? null;
    this.expiresAt = o.expiresAt;
  }

  /** L'identifiant de l'utilisateur (`sub`) lu dans un jeton d'accès JWT. */
  static subjectOfJWT(token: string): string | null {
    const parts = token.split(".");
    if (parts.length < 2) return null;
    let payload = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    while (payload.length % 4 !== 0) payload += "=";
    try {
      const binary = atob(payload);
      const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
      const value: unknown = JSON.parse(new TextDecoder().decode(bytes));
      if (value === null || typeof value !== "object") return null;
      const subject = (value as Record<string, unknown>)["sub"];
      return typeof subject === "string" && subject !== "" ? subject : null;
    } catch {
      return null;
    }
  }

  isExpired(now: Date = new Date()): boolean {
    return this.expiresAt.getTime() <= now.getTime() + StoredSession.leeway * 1000;
  }

  /** Un jeton utilisable, même expiré, tant qu'on peut le rafraîchir. */
  get isUsable(): boolean {
    return this.accessToken !== "";
  }

  /** `==` de Swift : deux sessions identiques se comparent. */
  equals(other: StoredSession): boolean {
    return this.accessToken === other.accessToken
      && this.refreshToken === other.refreshToken
      && this.userID === other.userID
      && this.email === other.email
      && this.expiresAt.getTime() === other.expiresAt.getTime();
  }

  /** `JSONEncoder` par défaut : les dates en secondes depuis 2001. */
  encoded(): string {
    return JSON.stringify({
      accessToken: this.accessToken,
      ...(this.refreshToken !== null ? { refreshToken: this.refreshToken } : {}),
      ...(this.userID !== null ? { userID: this.userID } : {}),
      ...(this.email !== null ? { email: this.email } : {}),
      expiresAt: this.expiresAt.getTime() / 1000 - referenceEpoch,
    });
  }

  static decode(raw: string): StoredSession | null {
    if (raw === "") return null;
    try {
      const value = JSON.parse(raw) as Record<string, unknown>;
      if (typeof value["accessToken"] !== "string" || typeof value["expiresAt"] !== "number") return null;
      const string = (key: string): string | null => (typeof value[key] === "string" ? (value[key] as string) : null);
      return new StoredSession({
        accessToken: value["accessToken"] as string,
        refreshToken: string("refreshToken"),
        userID: string("userID"),
        email: string("email"),
        expiresAt: new Date((value["expiresAt"] as number) * 1000 + referenceEpoch * 1000),
      });
    } catch {
      return null;
    }
  }
}
