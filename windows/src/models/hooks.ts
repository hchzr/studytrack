// Les formats JSON dont les modèles portent la valeur brute mais dont le code vit
// dans le domaine (`RevisionSheet`, `StudyMap`).
//
// Les modèles ne dépendent pas des moteurs : le module qui porte ces types
// s'enregistre ici (`registerCourseCodecs`) et `Course.revisionSheet` /
// `Course.studyMap` s'en servent. Sans enregistrement, le JSON brut est rendu
// tel quel (objet quelconque) — assez pour ne rien perdre, pas pour calculer.

/** Ce que `Course.studyMap` attend d'une carte d'étude (`StudyMap`). */
export interface StudyMapLike {
  isEmpty: boolean;
  enrichedAt?: Date | null;
  encoded(): string;
}

/** Ce que `Course.revisionSheet` attend d'une fiche (`RevisionSheet`). */
export interface RevisionSheetLike {
  encoded(): string;
}

export interface CourseCodecs {
  decodeRevisionSheet(raw: string): RevisionSheetLike | null;
  /** `StudyMap.decode(raw) ?? StudyMap()`. */
  decodeStudyMap(raw: string): StudyMapLike;
}

function tryParse(raw: string): Record<string, unknown> | null {
  if (raw === "") return null;
  try {
    const value = JSON.parse(raw);
    return value !== null && typeof value === "object" ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/** Repli : un objet JSON qui se ré-encode tel qu'il est. */
const rawCodecs: CourseCodecs = {
  decodeRevisionSheet(raw) {
    const value = tryParse(raw);
    return value && { ...value, encoded: () => JSON.stringify(value) };
  },
  decodeStudyMap(raw) {
    const value = tryParse(raw);
    return {
      ...(value ?? {}),
      isEmpty: value === null || Object.keys(value).length === 0,
      enrichedAt: null,
      encoded: () => (value ? JSON.stringify(value) : ""),
    };
  },
};

let current: CourseCodecs = rawCodecs;

export function registerCourseCodecs(codecs: CourseCodecs): void {
  current = codecs;
}

export const courseCodecs = (): CourseCodecs => current;
