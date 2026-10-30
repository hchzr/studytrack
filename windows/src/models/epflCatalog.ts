// Catalogue de sections EPFL (programmes d'études). Sert uniquement à aider l'étudiant·e à
// se situer : la section choisie est stockée dans les réglages et recopiée sur chaque cours
// (`Course.sectionCode`). La liste est indicative et peut être complétée librement.

/** Une section EPFL. */
export interface EPFLSection {
  readonly code: string;
  readonly name: string;
  readonly faculty: string;
  /** `id` : le code. */
  readonly id: string;
  readonly displayName: string;
  readonly subtitle: string;
}

const section = (code: string, name: string, faculty: string): EPFLSection => ({
  code, name, faculty, id: code, displayName: name, subtitle: `${faculty} · ${code}`,
});

/** `folding(options: [.diacriticInsensitive, .caseInsensitive])`. */
const fold = (s: string): string => s.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

const ciEqual = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();

export const EPFLCatalog = {
  sections: [
    // Faculté ENAC
    section("AR", "Architecture", "ENAC"),
    section("GC", "Génie civil", "ENAC"),
    section("SIE", "Sciences et ingénierie de l'environnement", "ENAC"),

    // Faculté STI
    section("GM", "Génie mécanique", "STI"),
    section("MT", "Microtechnique", "STI"),
    section("MX", "Science et ingénierie des matériaux", "STI"),
    section("EL", "Génie électrique et électronique", "STI"),

    // Faculté IC
    section("IN", "Informatique", "IC"),
    section("SC", "Systèmes de communication", "IC"),

    // Faculté SB
    section("MA", "Mathématiques", "SB"),
    section("PH", "Physique", "SB"),
    section("CGC", "Chimie et génie chimique", "SB"),
    section("SV", "Ingénierie des sciences du vivant", "SB"),

    // Faculté CDH
    section("DH", "Humanités digitales", "CDH"),

    // Faculté MTEI
    section("MTE", "Management, technologie et entrepreneuriat", "MTEI"),

    // Masters inter-facultaires
    section("INGM", "Ingénierie mathématique", "SB"),
    section("DS", "Data science", "IC"),
    section("CYS", "Cybersécurité", "IC"),
    section("NX", "Neuro-X", "SV"),
    section("QS", "Quantum science and engineering", "SB"),
    section("EN", "Energy science and technology", "STI"),
    section("MS", "Materials science and engineering", "STI"),
    section("SMT", "Sustainable management and technology", "MTEI"),
    section("MNE", "Micro- et nanotechnologies", "STI"),
    section("ROB", "Robotics", "STI"),
    section("BIO", "Bioengineering", "SV"),
    section("AM", "Applied mathematics", "SB"),
    section("COM", "Communication systems", "IC"),
  ] as readonly EPFLSection[],

  section(code: string): EPFLSection | null {
    return EPFLCatalog.sections.find((s) => ciEqual(s.code, code)) ?? null;
  },

  search(query: string): EPFLSection[] {
    const trimmed = query.replace(/^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu, "");
    if (trimmed === "") return [...EPFLCatalog.sections];
    const needle = fold(trimmed);
    return EPFLCatalog.sections.filter((s) =>
      fold(s.name).includes(needle) || ciEqual(s.code, trimmed) || ciEqual(s.faculty, trimmed));
  },

  sectionsInFaculty(faculty: string): EPFLSection[] {
    return EPFLCatalog.sections.filter((s) => s.faculty === faculty);
  },
};
