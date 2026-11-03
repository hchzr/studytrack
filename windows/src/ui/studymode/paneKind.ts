// Les outils du centre du bureau : un à la fois (StudyDesk.Pane, restreint à
// ce qui existe sur Windows — pas de navigateur intégré, pas de calcul ni de
// musique : le volet d'à côté porte le reste).

export type StudyPane = "desk" | "course" | "exercise" | "notes" | "sheet";

export const STUDY_PANES: { kind: StudyPane; label: string; icon: string; help: string }[] = [
  { kind: "desk", label: "Bureau", icon: "square.grid.2x2", help: "L'accueil du moment" },
  { kind: "course", label: "Le cours", icon: "book", help: "Le site du cours : semaines, polycopié, séries" },
  { kind: "exercise", label: "Exercice", icon: "doc.text", help: "L'énoncé, les questions, la correction" },
  { kind: "notes", label: "Notes", icon: "text.alignleft", help: "Les notes du cours" },
  { kind: "sheet", label: "Fiche", icon: "list.bullet.rectangle", help: "La fiche de révision" },
];
