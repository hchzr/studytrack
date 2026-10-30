// L'école de l'étudiant·e, **en données** : ses sites (Moodle, Open edX, vidéos
// Kaltura, Ed Discussion, sites propres), sa chaîne de connexion, ses domaines
// (StudyTrack/Domain/Institution.swift).
//
// Le code ne connaît que des sortes de plateformes ; ce qui est propre à une école
// vit ici. L'EPFL est le profil intégré (`.epfl`) et reprend exactement les valeurs
// observées. Une autre école est un autre profil, sans nouveau code.

export interface InstitutionMoodle {
  base: string;
  /** L'identifiant du bouton OAuth (`auth/oauth2/login.php?id=3`). `null` : formulaire classique. */
  oauthProviderID: number | null;
}

export interface InstitutionOpenEdX {
  base: string;
  loginBackend: string | null;
  ssoHost: string | null;
  ssoIdP: string | null;
}

export interface InstitutionVideo {
  host: string;
  kalturaAPI: string;
  kalturaPartner: number;
  wayfHost: string | null;
  identityProvider: string | null;
  passwordIdPHost: string | null;
}

export interface InstitutionEd {
  region: string;
}

export interface InstitutionInit {
  id: string;
  name: string;
  emailDomains: string[];
  moodle?: InstitutionMoodle | null;
  openEdX?: InstitutionOpenEdX | null;
  video?: InstitutionVideo | null;
  ed?: InstitutionEd | null;
  /** Les sites propres à l'école lus en natif (`botafogo`, `explique`). */
  extras?: Record<string, string>;
  studyDomains?: string[];
  calendarURL?: string | null;
}

/// `URL(string:)` : `null` quand l'adresse n'en est pas une.
const url = (text: string): URL | null => {
  try {
    return new URL(text);
  } catch {
    return null;
  }
};

export class Institution {
  id: string;
  name: string;
  /** Les domaines des adresses électroniques : la détection. */
  emailDomains: string[];
  moodle: InstitutionMoodle | null;
  openEdX: InstitutionOpenEdX | null;
  video: InstitutionVideo | null;
  ed: InstitutionEd | null;
  extras: Record<string, string>;
  studyDomains: string[];
  calendarURL: string | null;

  constructor(o: InstitutionInit) {
    this.id = o.id;
    this.name = o.name;
    this.emailDomains = o.emailDomains;
    this.moodle = o.moodle ?? null;
    this.openEdX = o.openEdX ?? null;
    this.video = o.video ?? null;
    this.ed = o.ed ?? null;
    this.extras = o.extras ?? {};
    this.studyDomains = o.studyDomains ?? [];
    this.calendarURL = o.calendarURL ?? null;
  }

  // MARK: Adresses dérivées

  get moodleHost(): string | null {
    return this.moodle ? (url(this.moodle.base)?.host ?? null) : null;
  }

  get coursewareHost(): string | null {
    return this.openEdX ? (url(this.openEdX.base)?.host ?? null) : null;
  }

  get edAPI(): string | null {
    return this.ed ? `https://${this.ed.region}.edstem.org/api` : null;
  }

  get edApp(): string | null {
    return this.ed ? `https://edstem.org/${this.ed.region}` : null;
  }

  moodleURL(path: string): URL | null {
    return this.moodle ? url(this.moodle.base + path) : null;
  }

  coursewareURL(path: string): URL | null {
    return this.openEdX ? url(this.openEdX.base + path) : null;
  }

  videoURL(entryID: string): URL | null {
    return this.video ? url(`https://${this.video.host}/media/t/${entryID}`) : null;
  }

  /** Les hôtes qui appartiennent à l'école (cookies à garder, liens à suivre). */
  get hosts(): string[] {
    const result: string[] = [];
    if (this.moodleHost !== null) result.push(this.moodleHost);
    if (this.coursewareHost !== null) result.push(this.coursewareHost);
    if (this.video) result.push(this.video.host);
    result.push(...Object.values(this.extras).map((value) => url(value)?.host ?? value));
    return result;
  }

  /** Les domaines « racine » de l'école (`epfl.ch`), pour les cookies. */
  get rootDomains(): string[] {
    return this.emailDomains;
  }

  owns(host: string | null): boolean {
    const value = host?.toLowerCase();
    if (!value) return false;
    return this.rootDomains.some((domain) => value === domain || value.endsWith("." + domain))
      || this.hosts.includes(value);
  }

  // MARK: Profils intégrés

  static epfl = new Institution({
    id: "epfl", name: "EPFL", emailDomains: ["epfl.ch"],
    moodle: { base: "https://moodle.epfl.ch", oauthProviderID: 3 },
    openEdX: { base: "https://courseware.epfl.ch", loginBackend: "edx-oauth2",
               ssoHost: "id.openlearnity.org", ssoIdP: "epfl-ol" },
    video: { host: "mediaspace.epfl.ch", kalturaAPI: "https://api.cast.switch.ch", kalturaPartner: 113,
             wayfHost: "wayf.switch.ch", identityProvider: "https://idp.epfl.ch/idp/shibboleth",
             passwordIdPHost: "eduid.ch" },
    ed: { region: "eu" },
    extras: { botafogo: "https://botafogo.epfl.ch", explique: "https://explique.epfl.ch" },
    studyDomains: ["epfl.ch", "kaltura.com", "switch.ch", "edstem.org", "edusercontent.com", "openlearnity.org",
                   "login.microsoftonline.com", "login.live.com", "msauth.net", "msftauth.net"],
    calendarURL: "https://www.epfl.ch/education/studies/reglement-et-procedure/calendrier-academique/",
  });

  /** Une école sans rien de connu : le mode étude, le chrono, les notes, Claude marchent. */
  static generic = new Institution({ id: "generic", name: "Mon école", emailDomains: [] });

  static builtIn: Institution[] = [Institution.epfl];

  /** L'école d'une adresse (« prenom.nom@epfl.ch » → EPFL). */
  static detect(email: string, among: Institution[] = Institution.builtIn): Institution | null {
    const parts = email.split("@");
    const domain = parts[parts.length - 1]?.toLowerCase();
    if (domain === undefined) return null;
    return among.find((profile) => profile.emailDomains.some((d) => domain === d || domain.endsWith("." + d))) ?? null;
  }

  // MARK: L'école en cours

  /** L'école choisie (réglage partagé ; l'EPFL par défaut, comme avant). */
  static current: Institution = Institution.loadCurrent();

  static readonly storageKey = "institution.profile";

  static loadCurrent(): Institution {
    try {
      const raw = globalThis.localStorage?.getItem(Institution.storageKey);
      if (raw === undefined || raw === null) return Institution.epfl;
      return Institution.fromJSON(JSON.parse(raw)) ?? Institution.epfl;
    } catch {
      return Institution.epfl;
    }
  }

  static save(profile: Institution): void {
    Institution.current = profile;
    try {
      globalThis.localStorage?.setItem(Institution.storageKey, JSON.stringify(profile.toJSON()));
    } catch {
      // Pas de stockage (tests, aperçu) : le profil reste en mémoire.
    }
  }

  /** `Codable` : ce que JSON garde d'un profil. */
  toJSON(): Record<string, unknown> {
    return {
      id: this.id,
      name: this.name,
      emailDomains: this.emailDomains,
      moodle: this.moodle,
      openEdX: this.openEdX,
      video: this.video,
      ed: this.ed,
      extras: this.extras,
      studyDomains: this.studyDomains,
      calendarURL: this.calendarURL,
    };
  }

  static fromJSON(raw: unknown): Institution | null {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
    const o = raw as Record<string, unknown>;
    if (typeof o.id !== "string" || typeof o.name !== "string" || !Array.isArray(o.emailDomains)) return null;
    const objectOrNull = <T>(value: unknown): T | null =>
      value !== null && typeof value === "object" && !Array.isArray(value) ? (value as T) : null;
    const strings = (value: unknown): string[] => Array.isArray(value) ? value.filter((x): x is string => typeof x === "string") : [];
    return new Institution({
      id: o.id,
      name: o.name,
      emailDomains: strings(o.emailDomains),
      moodle: objectOrNull<InstitutionMoodle>(o.moodle),
      openEdX: objectOrNull<InstitutionOpenEdX>(o.openEdX),
      video: objectOrNull<InstitutionVideo>(o.video),
      ed: objectOrNull<InstitutionEd>(o.ed),
      extras: objectOrNull<Record<string, string>>(o.extras) ?? {},
      studyDomains: strings(o.studyDomains),
      calendarURL: typeof o.calendarURL === "string" ? o.calendarURL : null,
    });
  }

  // MARK: Raccourcis pour les clients

  /** L'hôte de chaque plateforme (repli sur l'EPFL pour un profil incomplet). */
  get moodleHostName(): string { return this.moodleHost ?? "moodle.epfl.ch"; }
  get moodleBase(): string { return this.moodle?.base ?? "https://moodle.epfl.ch"; }
  get coursewareHostName(): string { return this.coursewareHost ?? "courseware.epfl.ch"; }
  get coursewareBase(): string { return this.openEdX?.base ?? "https://courseware.epfl.ch"; }
  get videoHostName(): string { return this.video?.host ?? "mediaspace.epfl.ch"; }
  get edRegion(): string { return this.ed?.region ?? "eu"; }
  get expliqueBase(): string { return this.extras["explique"] ?? "https://explique.epfl.ch"; }
}

export type InstitutionEquatable = Institution;
