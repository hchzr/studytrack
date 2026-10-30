// Branchement des formats JSON du domaine sur les modèles : `Course.revisionSheet`
// et `Course.studyMap` doivent se décoder en `RevisionSheet` / `StudyMap`, sinon
// ils restent des objets bruts et rien ne peut être calculé.
//
// Ce module s'enregistre à l'import : l'entrée de l'app doit l'importer une fois
// (`import "./domain/registerCodecs.ts"`) avant de lire un cours.

import { registerCourseCodecs } from "../models/hooks.ts";
import { RevisionSheet } from "./revisionSheet.ts";
import { StudyMap } from "./studyMap.ts";

registerCourseCodecs({
  decodeRevisionSheet(raw: string): RevisionSheet | null {
    return RevisionSheet.decode(raw);
  },
  /** `StudyMap.decode(raw) ?? StudyMap()`. */
  decodeStudyMap(raw: string): StudyMap {
    return StudyMap.decode(raw) ?? new StudyMap();
  },
});
