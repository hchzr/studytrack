// Relations entre modèles, avec l'entretien des inverses que SwiftData fait seul :
// poser `item.course = course` ajoute `item` à `course.theoryItems`, et
// l'assigner ailleurs l'en retire. Sans ça, `course.theoryItems` resterait vide
// tant qu'on ne l'a pas rempli à la main, et les deux côtés divergeraient.
//
// Une relation « un » est un accesseur sur le prototype (stockage `_nom`), une
// relation « plusieurs » aussi (stockage `_nom`, tableau vivant). Les tableaux se
// comportent comme des ensembles : jamais deux fois le même objet.

/** Règle de suppression côté parent (`@Relationship(deleteRule:)`). */
export type DeleteRule = "cascade" | "nullify";

export interface Relation {
  /** Classe parent (porte le tableau) et classe enfant (porte la référence « un »). */
  parent: string;
  list: string;
  child: string;
  one: string;
  rule: DeleteRule;
}

/**
 * Toutes les relations du schéma, recopiées des `@Relationship` Swift. Le test
 * `models.test.ts` les recoupe avec `schema.ts` (règles de suppression des tables
 * synchronisées).
 */
export const relations: readonly Relation[] = [
  { parent: "AcademicTerm", list: "courses", child: "Course", one: "term", rule: "nullify" },
  { parent: "Course", list: "theoryItems", child: "TheoryItem", one: "course", rule: "cascade" },
  { parent: "Course", list: "series", child: "ExerciseSeries", one: "course", rule: "cascade" },
  { parent: "Course", list: "sessions", child: "StudySession", one: "course", rule: "cascade" },
  { parent: "Course", list: "exams", child: "Exam", one: "course", rule: "cascade" },
  { parent: "Course", list: "pastExams", child: "PastExam", one: "course", rule: "cascade" },
  { parent: "Course", list: "savedResources", child: "SavedResource", one: "course", rule: "cascade" },
  { parent: "Course", list: "linkedTasks", child: "LinkedTask", one: "course", rule: "cascade" },
  { parent: "Course", list: "plannedSessionsStore", child: "PlannedSession", one: "course", rule: "nullify" },
  { parent: "Course", list: "linkedEvents", child: "LinkedCalendarEvent", one: "course", rule: "cascade" },
  { parent: "ExerciseSeries", list: "exercises", child: "Exercise", one: "series", rule: "cascade" },
  { parent: "Exercise", list: "subQuestions", child: "SubQuestion", one: "exercise", rule: "cascade" },
  { parent: "Exercise", list: "targetedSessions", child: "StudySession", one: "exercise", rule: "nullify" },
  { parent: "Exercise", list: "targetedTasks", child: "LinkedTask", one: "exercise", rule: "nullify" },
  { parent: "Exercise", list: "mistakesStore", child: "Mistake", one: "exercise", rule: "cascade" },
  { parent: "SubQuestion", list: "children", child: "SubQuestion", one: "parent", rule: "cascade" },
  { parent: "TheoryItem", list: "targetedSessions", child: "StudySession", one: "theoryItem", rule: "nullify" },
  { parent: "TheoryItem", list: "targetedTasks", child: "LinkedTask", one: "video", rule: "nullify" },
  { parent: "StudyGroup", list: "members", child: "GroupMember", one: "group", rule: "cascade" },
  { parent: "StudyGroup", list: "completions", child: "GroupSeriesCompletion", one: "group", rule: "cascade" },
  { parent: "StudyGroup", list: "itemCompletions", child: "GroupItemCompletion", one: "group", rule: "cascade" },
];

type Any = Record<string, any>;
type Ctor = { prototype: object };

/** Une référence « un » : `Child.one`, inverse `Parent.list`. */
export function defineToOne(child: Ctor, one: string, list: string): void {
  const slot = `_${one}`;
  Object.defineProperty(child.prototype, one, {
    configurable: true,
    enumerable: true,
    get(this: Any) { return this[slot] ?? null; },
    set(this: Any, value: Any | null | undefined) {
      const next = value ?? null;
      const old = this[slot] ?? null;
      if (old === next) return;
      if (old) {
        const siblings: Any[] = old[list];
        const at = siblings.indexOf(this);
        if (at >= 0) siblings.splice(at, 1);
      }
      this[slot] = next;
      if (next && !(next[list] as Any[]).includes(this)) (next[list] as Any[]).push(this);
    },
  });
}

/**
 * Une relation « plusieurs » : `Parent.list`, inverse `Child.one`. Le getter rend
 * le tableau **vivant** ; l'assigner remplace la liste en mettant à jour les
 * inverses (les retirés perdent leur parent, les ajoutés quittent l'ancien).
 * `alias` : un second nom pour le même tableau (`theoryItemsStore`).
 */
export function defineToMany(parent: Ctor, list: string, one: string, alias?: string): void {
  const slot = `_${list}`;
  const get = function (this: Any): Any[] { return (this[slot] ??= []); };
  const set = function (this: Any, value: Any[]) {
    const next = [...new Set(value)];
    const old: Any[] = this[slot] ?? [];
    for (const gone of old) {
      if (!next.includes(gone) && gone[`_${one}`] === this) gone[`_${one}`] = null;
    }
    for (const added of next) {
      const previous = added[`_${one}`] ?? null;
      if (previous && previous !== this) {
        const siblings: Any[] = previous[list];
        const at = siblings.indexOf(added);
        if (at >= 0) siblings.splice(at, 1);
      }
      added[`_${one}`] = this;
    }
    this[slot] = next;
  };
  Object.defineProperty(parent.prototype, list, { configurable: true, enumerable: true, get, set });
  if (alias) Object.defineProperty(parent.prototype, alias, { configurable: true, enumerable: false, get, set });
}

/** UUID en minuscules, comme les rend Postgres et comme les stocke la synchronisation. */
export const newId = (): string => globalThis.crypto.randomUUID();
