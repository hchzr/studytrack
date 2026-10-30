// Un nombre et ce qu'il compte, accordé (StudyTrack/Domain/Plural.swift).
//
// Les pluriels s'écrivaient à la main (`série${n > 1 ? "s" : ""}`) : justes en
// français, faux en anglais. Ici l'appelant donne les deux formes, et la règle de
// la langue choisit : en français, 0 et 1 sont au singulier ; en anglais, seul 1
// l'est.

/** Langue de l'interface (`Bundle.main.preferredLocalizations.first`) : français par défaut. */
let preferredLanguage = "fr";

export function setPreferredLanguage(code: string): void {
  preferredLanguage = code;
}

export function getPreferredLanguage(): string {
  return preferredLanguage;
}

export const Plural = {
  count(n: number, one: string, many: string): string {
    return Plural.usesSingular(n) ? one : many;
  },

  usesSingular(n: number, language?: string): boolean {
    const code = language ?? preferredLanguage;
    return code.startsWith("fr") ? Math.abs(n) <= 1 : Math.abs(n) === 1;
  },
};
