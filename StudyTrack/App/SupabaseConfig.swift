import Foundation

/// Configuration Supabase, **compilée dans l'app**.
///
/// L'URL du projet et la clé anonyme ne sont pas des réglages d'utilisateur : ce
/// sont des constantes de build. Les demander dans les réglages obligeait chaque
/// étudiant·e à les trouver avant de pouvoir se connecter — et la clé anonyme est
/// publique par conception, puisqu'elle n'autorise que ce que les politiques RLS
/// de la base permettent.
///
/// Définies par `SUPABASE_URL` et `SUPABASE_ANON_KEY` dans les réglages de build
/// (voir README §5) et injectées par `Support/Info.plist`.
enum SupabaseConfig {
    /// Le domaine du projet, **sans schéma**.
    ///
    /// Un fichier `.xcconfig` traite `//` comme un début de commentaire :
    /// `https://xyz.supabase.co` y serait tronqué à `https:`. On stocke donc le
    /// domaine seul et on compose l'URL ici.
    static var host: String { value(for: "SupabaseHost") }

    static let anonKey = value(for: "SupabaseAnonKey")

    /// L'URL complète, ou une chaîne vide si la build n'est pas configurée.
    static var urlString: String {
        isUsable(host) ? "https://\(host)" : ""
    }

    /// Vrai quand la build porte une vraie configuration.
    ///
    /// Une build sans configuration reste **pleinement utilisable** : le suivi, le
    /// temps et l'agenda fonctionnent, les groupes sont simplement indisponibles,
    /// et l'interface le dit au lieu de montrer des champs vides.
    static var isConfigured: Bool {
        isUsable(host) && isUsable(anonKey)
    }

    /// Une valeur est-elle une vraie configuration ?
    ///
    /// Une variable de build non définie laisse littéralement `$(SUPABASE_URL)`
    /// dans l'Info.plist : c'est une absence, pas une valeur. Le test est ici, pur
    /// et testable, plutôt qu'enfoui dans la lecture du bundle.
    static func isUsable(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("$(")
    }

    private static func value(for key: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
