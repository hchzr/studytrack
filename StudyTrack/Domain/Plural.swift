import Foundation

/// Un nombre et ce qu'il compte, accordé — et traduit.
///
/// Les pluriels s'écrivaient à la main (`série\(n > 1 ? "s" : "")`) : justes en
/// français, mais jamais traduits (une chaîne bâtie ainsi n'est pas une clé
/// du catalogue), et faux en anglais là où le catalogue reprenait l'astuce
/// (« seriess »). Ici, les deux formes sont deux clés du catalogue
/// (`%lld série` / `%lld séries`), et la règle de la langue choisit : en
/// français, 0 et 1 sont au singulier ; en anglais, seul 1 l'est.
enum Plural {
    static func count(_ n: Int, _ one: String.LocalizationValue, _ many: String.LocalizationValue) -> String {
        String(localized: usesSingular(n) ? one : many)
    }

    static func usesSingular(_ n: Int, language: String? = nil) -> Bool {
        let code = language ?? Bundle.main.preferredLocalizations.first ?? "fr"
        return code.hasPrefix("fr") ? abs(n) <= 1 : abs(n) == 1
    }
}
