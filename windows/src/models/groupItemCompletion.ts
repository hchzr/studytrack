import { GroupItemKind } from "./enums.ts";
import { defineToOne, newId } from "./relations.ts";
import type { StudyGroup } from "./studyGroup.ts";

export interface GroupItemCompletionInit {
  id?: string;
  group?: StudyGroup | null;
  userID: string;
  displayName: string;
  courseCode: string;
  kind: GroupItemKind;
  itemNumber: string;
  completedAt?: Date;
}

/**
 * « X a fait l'exercice 3.2 (ou la vidéo 1.1) du cours Y » — au sein d'un groupe. Comme
 * l'EPFL publie une seule série par semaine et par matière, deux personnes inscrites au
 * même cours ont forcément les mêmes numéros : la comparaison est toujours possible.
 */
export class GroupItemCompletion {
  static readonly modelName = "GroupItemCompletion";

  id: string;
  declare group: StudyGroup | null;
  userID: string;
  displayName: string;
  courseCode: string;
  /** `exercise` ou `theory` — voir `GroupItemKind`. */
  kindRaw: string;
  /** Numéro affiché : « 3.2 », « 1.1 ». */
  itemNumber: string;
  completedAt: Date;

  constructor(o: GroupItemCompletionInit) {
    this.id = o.id ?? newId();
    this.group = o.group ?? null;
    this.userID = o.userID;
    this.displayName = o.displayName;
    this.courseCode = o.courseCode;
    this.kindRaw = o.kind;
    this.itemNumber = o.itemNumber;
    this.completedAt = o.completedAt ?? new Date();
  }

  get kind(): GroupItemKind {
    return GroupItemKind.fromRaw(this.kindRaw) ?? "exercise";
  }
  set kind(value: GroupItemKind) {
    this.kindRaw = value;
  }
}

defineToOne(GroupItemCompletion, "group", "itemCompletionsStore");
