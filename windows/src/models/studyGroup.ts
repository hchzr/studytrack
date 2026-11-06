import { DateUtils } from "../domain/dateUtils.ts";
import { GroupItemKind, GroupRole } from "./enums.ts";
import { GroupItemCompletion } from "./groupItemCompletion.ts";
import { defineToMany, defineToOne, newId } from "./relations.ts";
import type { ModelStore } from "./store.ts";
import { trimAll } from "./util.ts";

export interface StudyGroupInit {
  id?: string;
  remoteID?: string | null;
  name: string;
  details?: string;
  courseCode?: string;
  courseCodes?: string[];
  inviteCode?: string;
  isAdmin?: boolean;
}

/** Groupe d'étude (cache local d'un groupe distant Supabase). */
export class StudyGroup {
  static readonly modelName = "StudyGroup";

  id: string;
  /** Identifiant côté Supabase (`null` si le groupe n'est pas encore synchronisé). */
  remoteID: string | null;
  name: string;
  details: string;
  /**
   * Ancien champ mono-matière, conservé pour ne pas perdre les groupes déjà enregistrés.
   * `subjectCodes` reste la seule source de vérité à l'usage.
   */
  courseCode: string;
  /**
   * Les matières que le groupe travaille. Un groupe d'entraide porte presque toujours sur
   * **plusieurs** cours : c'est la même promo, pas la même matière.
   */
  courseCodes: string[];
  inviteCode: string;
  isAdmin: boolean;
  createdAt: Date;
  lastSyncedAt: Date | null = null;

  declare members: GroupMember[];
  declare membersStore: GroupMember[];
  declare completions: GroupSeriesCompletion[];
  declare completionsStore: GroupSeriesCompletion[];
  /** Avancement **exercice par exercice** des membres. */
  declare itemCompletions: GroupItemCompletion[];
  declare itemCompletionsStore: GroupItemCompletion[];

  constructor(o: StudyGroupInit) {
    this.id = o.id ?? newId();
    this.remoteID = o.remoteID ?? null;
    this.name = o.name;
    this.details = o.details ?? "";
    this.courseCode = o.courseCode ?? "";
    this.courseCodes = o.courseCodes ?? [];
    this.inviteCode = (o.inviteCode ?? "") === "" ? StudyGroup.generateInviteCode() : o.inviteCode!;
    this.isAdmin = o.isAdmin ?? true;
    this.createdAt = new Date();
  }

  static generateInviteCode(): string {
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let suffix = "";
    for (let i = 0; i < 4; i++) suffix += alphabet[Math.floor(Math.random() * alphabet.length)];
    return `EPFL-${suffix}`;
  }

  /**
   * Normalise un code saisi ou reçu par lien : majuscules, sans espaces. Un code collé
   * depuis un message arrive souvent en minuscules ou entouré d'espaces.
   */
  static normalizeInviteCode(raw: string): string {
    return trimAll(raw).replace(/ /g, "").toUpperCase();
  }

  /** Lien d'invitation partageable, compris par l'app elle-même. */
  get inviteLink(): string {
    return `polymestre://join?code=${this.inviteCode}`;
  }

  /**
   * Message prêt à envoyer : le code **et** le lien (le code seul oblige à un aller-retour ;
   * le lien seul ne fonctionne pas partout).
   */
  get inviteMessage(): string {
    let text = `Rejoins « ${this.name} » sur Polymestre avec le code ${this.inviteCode}.`;
    if (this.subjectCodes.length !== 0) {
      text += `\nMatières : ${this.subjectCodes.join(", ")}.`;
    }
    text += `\n${this.inviteLink}`;
    return text;
  }

  /**
   * Les matières du groupe, sans doublon ni casse multiple. Repli sur l'ancien champ
   * mono-matière : un groupe créé avant les matières multiples continue à fonctionner.
   */
  get subjectCodes(): string[] {
    return StudyGroup.normalize([...this.courseCodes, ...(this.courseCode === "" ? [] : [this.courseCode])]);
  }
  set subjectCodes(value: string[]) {
    // Le champ historique est **absorbé** par la liste définitive. Sans ça, `courseCode`
    // restait renseigné et le getter le réinjectait : une matière retirée réapparaissait.
    this.courseCode = "";
    this.courseCodes = StudyGroup.normalize(value);
  }

  /** Nettoie une liste de codes : majuscules, sans doublon, ordre conservé. */
  static normalize(codes: string[]): string[] {
    const seen = new Set<string>();
    const result: string[] = [];
    for (const raw of codes) {
      const code = trimAll(raw).toUpperCase();
      if (code === "" || seen.has(code)) continue;
      seen.add(code);
      result.push(code);
    }
    return result;
  }

  addSubject(code: string): void {
    this.subjectCodes = [...this.subjectCodes, code];
  }

  removeSubject(code: string): void {
    const target = code.toUpperCase();
    this.subjectCodes = this.subjectCodes.filter((c) => c !== target);
    this.courseCode = this.courseCode.toUpperCase() === target ? "" : this.courseCode;
    for (const member of this.members) {
      member.courseCodes = member.courseCodes.filter((c) => c.toUpperCase() !== target);
    }
  }

  /** Le groupe travaille-t-il cette matière ? */
  tracks(code: string): boolean {
    return this.subjectCodes.includes(code.toUpperCase());
  }

  /**
   * Mes matières communes : celles du groupe que je suis réellement. Un groupe peut
   * travailler cinq matières dont je n'en suis que deux.
   */
  mySubjectCodes(myTrackedCourses: Iterable<string>): string[] {
    const mine = new Set(myTrackedCourses);
    return this.subjectCodes.filter((c) => mine.has(c));
  }

  get displayName(): string {
    return this.courseCode === "" ? this.name : `${this.courseCode} · ${this.name}`;
  }
}

defineToMany(StudyGroup, "members", "group", "membersStore");
defineToMany(StudyGroup, "completions", "group", "completionsStore");
defineToMany(StudyGroup, "itemCompletions", "group", "itemCompletionsStore");

export interface GroupMemberInit {
  id?: string;
  group?: StudyGroup | null;
  userID: string;
  displayName: string;
  weeklySeconds?: number;
  totalSeconds?: number;
  completedSeriesCount?: number;
  isMe?: boolean;
  isAnonymous?: boolean;
  role?: GroupRole;
  courseCodes?: string[];
}

/** Membre d'un groupe, avec ses statistiques agrégées. */
export class GroupMember {
  static readonly modelName = "GroupMember";

  id: string;
  declare group: StudyGroup | null;
  userID: string;
  displayName: string;
  weeklySeconds: number;
  totalSeconds: number;
  completedSeriesCount: number;
  isMe: boolean;
  isAnonymous: boolean;
  /** `admin` ou `member` — voir `GroupRole`. */
  roleRaw: string;
  /** Les matières du groupe que ce membre suit. */
  courseCodes: string[];

  constructor(o: GroupMemberInit) {
    this.id = o.id ?? newId();
    this.group = o.group ?? null;
    this.userID = o.userID;
    this.displayName = o.displayName;
    this.weeklySeconds = o.weeklySeconds ?? 0;
    this.totalSeconds = o.totalSeconds ?? 0;
    this.completedSeriesCount = o.completedSeriesCount ?? 0;
    this.isMe = o.isMe ?? false;
    this.isAnonymous = o.isAnonymous ?? false;
    this.roleRaw = o.role ?? "member";
    this.courseCodes = o.courseCodes ?? [];
  }

  get role(): GroupRole {
    return GroupRole.fromRaw(this.roleRaw) ?? "member";
  }
  set role(value: GroupRole) {
    this.roleRaw = value;
  }

  /**
   * Ce membre administre-t-il le groupe ?
   *
   * Le second terme n'est pas une politesse : `roleRaw` est arrivé **après**
   * `StudyGroup.isAdmin`. Pour un groupe créé avant, la migration a mis le nouvel attribut
   * à sa valeur par défaut — « member » — y compris pour le créateur, qui perdait ses droits
   * sur son propre groupe. Le drapeau local du groupe tranche tant que le serveur n'a rien dit.
   */
  get isAdmin(): boolean {
    if (this.role === "admin") return true;
    return this.isMe && (this.group?.isAdmin ?? false);
  }

  get shownName(): string { return this.isAnonymous ? "Anonyme" : this.displayName; }
  get weeklyLabel(): string { return DateUtils.hoursLabel(this.weeklySeconds); }
  get totalLabel(): string { return DateUtils.hoursLabel(this.totalSeconds); }
  get initials(): string {
    return this.displayName.split(" ").filter((p) => p !== "").slice(0, 2)
      .map((p) => Array.from(p)[0].toUpperCase()).join("");
  }

  /** Ce membre suit-il cette matière du groupe ? */
  follows(code: string): boolean {
    return this.courseCodes.length === 0 || this.courseCodes.some((c) => c.toUpperCase() === code.toUpperCase());
  }
}

defineToOne(GroupMember, "group", "membersStore");

export interface GroupSeriesCompletionInit {
  id?: string;
  group?: StudyGroup | null;
  userID: string;
  displayName: string;
  courseCode: string;
  seriesNumber: number;
  totalSeries?: number;
  completedAt?: Date;
}

/** « X a terminé la série N du cours Y » — alimente la matrice d'avancement. */
export class GroupSeriesCompletion {
  static readonly modelName = "GroupSeriesCompletion";

  id: string;
  declare group: StudyGroup | null;
  userID: string;
  displayName: string;
  courseCode: string;
  seriesNumber: number;
  totalSeries: number;
  completedAt: Date;

  constructor(o: GroupSeriesCompletionInit) {
    this.id = o.id ?? newId();
    this.group = o.group ?? null;
    this.userID = o.userID;
    this.displayName = o.displayName;
    this.courseCode = o.courseCode;
    this.seriesNumber = o.seriesNumber;
    this.totalSeries = o.totalSeries ?? 4;
    this.completedAt = o.completedAt ?? new Date();
  }
}

defineToOne(GroupSeriesCompletion, "group", "completionsStore");

/**
 * Données de démonstration pour les groupes. **Debug uniquement**, et seulement sur demande
 * explicite : cette fonction a déjà créé un faux groupe « Buddies BA4 » chez de vrais
 * utilisateurs, parce qu'elle était appelée sans condition à l'ouverture de l'onglet Groupes.
 */
export const GroupDemoData = {
  seedIfNeeded(store: ModelStore): void {
    if (store.fetchCount(StudyGroup) !== 0) return;

    const group = new StudyGroup({
      name: "Buddies BA4",
      details: "Groupe d'entraide pour le semestre.",
      courseCode: "",
      courseCodes: ["CS-250", "MATH-101", "PHYS-101"],
      inviteCode: "EPFL-4F2A",
      isAdmin: true,
    });
    store.insert(group);

    const members: [string, string, number, number, number, boolean, GroupRole][] = [
      ["me", "Moi", 9 * 3600 + 1800, 74 * 3600, 3, true, "admin"],
      ["u-alice", "Alice Moreau", 12 * 3600, 96 * 3600, 5, false, "admin"],
      ["u-bob", "Bob Favre", 7 * 3600 + 900, 61 * 3600, 4, false, "member"],
      ["u-chloe", "Chloé Dupraz", 6 * 3600, 58 * 3600, 4, false, "member"],
      ["u-dan", "Dan Rossier", 4 * 3600 + 1200, 41 * 3600, 2, false, "member"],
    ];
    for (const m of members) {
      const entry = new GroupMember({
        group,
        userID: m[0],
        displayName: m[1],
        weeklySeconds: m[2],
        totalSeconds: m[3],
        completedSeriesCount: m[4],
        role: m[6],
        courseCodes: group.subjectCodes,
      });
      entry.isMe = m[5];
      store.insert(entry);
    }

    const completions: [string, string, string, number][] = [
      ["u-alice", "Alice Moreau", "CS-250", 1],
      ["u-alice", "Alice Moreau", "CS-250", 2],
      ["u-alice", "Alice Moreau", "MATH-101", 1],
      ["u-bob", "Bob Favre", "CS-250", 1],
      ["u-bob", "Bob Favre", "CS-250", 2],
      ["u-chloe", "Chloé Dupraz", "MATH-101", 1],
      ["me", "Moi", "CS-250", 1],
    ];
    for (const c of completions) {
      store.insert(new GroupSeriesCompletion({
        group, userID: c[0], displayName: c[1], courseCode: c[2], seriesNumber: c[3],
      }));
    }

    const items: [string, string, string, GroupItemKind, string][] = [
      ["me", "Moi", "CS-250", "exercise", "3.1"],
      ["me", "Moi", "CS-250", "exercise", "3.2"],
      ["me", "Moi", "CS-250", "theory", "3.1"],
      // Des numéros qui existent réellement dans les cours d'exemple : un numéro inconnu
      // du référentiel est ignoré au calcul, et la démonstration paraîtrait incohérente.
      ["u-alice", "Alice Moreau", "CS-250", "exercise", "3.1"],
      ["u-alice", "Alice Moreau", "CS-250", "exercise", "3.2"],
      ["u-alice", "Alice Moreau", "CS-250", "exercise", "1.1"],
      ["u-alice", "Alice Moreau", "CS-250", "theory", "3.1"],
      ["u-alice", "Alice Moreau", "CS-250", "theory", "3.2"],
      ["u-bob", "Bob Favre", "CS-250", "exercise", "3.1"],
    ];
    for (const i of items) {
      store.insert(new GroupItemCompletion({
        group, userID: i[0], displayName: i[1], courseCode: i[2], kind: i[3], itemNumber: i[4],
      }));
    }

    store.save();
  },
};
