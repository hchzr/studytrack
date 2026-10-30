import { SavedResourceKind } from "./enums.ts";
import { defineToOne, newId } from "./relations.ts";
import type { Course } from "./course.ts";

export interface SavedResourceInit {
  course: Course | null;
  title: string;
  address?: string;
  kind: SavedResourceKind;
  fileName?: string;
  fileData?: Uint8Array | null;
}

/**
 * Une ressource gardée sous la main : une fiche-résumé, un formulaire, un PDF du cours,
 * une section du polycopié, un lien. Soit une **adresse**, soit un **fichier** ajouté par
 * l'étudiant·e.
 */
export class SavedResource {
  static readonly modelName = "SavedResource";

  /** `SavedResource.Kind`. */
  static readonly Kind = SavedResourceKind;

  id = newId();
  declare course: Course | null;
  title: string;
  /** L'adresse (ou le chemin du polycopié) ; vide pour un fichier ajouté. */
  address: string;
  kindRaw: string;
  /** Le nom du fichier ajouté (son extension dit comment l'ouvrir). */
  fileName: string;
  /** Le contenu du fichier : hors des colonnes synchronisées (Storage), voir `excludedFields`. */
  fileData: Uint8Array | null;
  addedAt = new Date();
  /** Épinglée en tête (la fiche-résumé qu'on rouvre sans cesse). */
  isPinned = false;

  constructor(o: SavedResourceInit) {
    this.course = o.course;
    this.title = o.title;
    this.address = o.address ?? "";
    this.kindRaw = o.kind;
    this.fileName = o.fileName ?? "";
    this.fileData = o.fileData ?? null;
  }

  get kind(): SavedResourceKind {
    return SavedResourceKind.fromRaw(this.kindRaw) ?? "web";
  }
  set kind(value: SavedResourceKind) {
    this.kindRaw = value;
  }

  get isFile(): boolean { return this.fileData !== null; }
}

defineToOne(SavedResource, "course", "savedResources");
