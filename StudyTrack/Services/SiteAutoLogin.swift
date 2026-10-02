import Foundation

/// Connecte **sans rien demander** les sites EPFL qui partagent la connexion
/// de Moodle : Courseware, MediaSpace, Explique.
///
/// Tous passent par la même authentification EPFL (le compte Microsoft
/// mémorisé par le navigateur de l'app). Une fois Moodle connecté, ouvrir leur
/// page de connexion dans le navigateur invisible suffit souvent : la
/// redirection se fait seule, ou après le seul bouton « EPFL » de la page — que
/// l'on touche à la place de l'étudiant·e. Rien n'est saisi, aucun mot de passe
/// n'est lu : si le site demande vraiment quelque chose, on abandonne en
/// silence et il reste à connecter depuis Profil › Connexions.
@MainActor
enum SiteAutoLogin {

    /// Les sites tentés après Moodle, et le verdict de chacun.
    static func connectAll() async -> [LoginSite: Bool] {
        var result: [LoginSite: Bool] = [:]
        // L'un après l'autre : trois navigateurs invisibles en parallèle se
        // disputeraient les cookies de la même session EPFL.
        for site in [LoginSite.courseware, .mediaspace, .explique] {
            result[site] = await attempt(site)
        }
        let connected = result.filter(\.value).map(\.key.label).sorted()
        AppLog.record(.info, "connexion", "Connexion automatique après Moodle",
                      detail: connected.isEmpty ? "aucun site supplémentaire" : connected.joined(separator: ", "))
        if !connected.isEmpty { await CookieKeeper.save() }
        return result
    }

    /// Une tentative, une quinzaine de secondes au plus.
    static func attempt(_ site: LoginSite) async -> Bool {
        let session = HiddenSiteSession()
        do {
            try await session.load(site.start)
        } catch {
            return false
        }
        var clicked = false
        for _ in 0..<15 {
            if let url = session.currentURL, let host = url.host, host.hasSuffix(site.host),
               !["/login", "/auth", "/user/login"].contains(where: url.path.hasPrefix) {
                if (try? await session.run(site.check)) == "true" { return true }
            }
            // Une page de choix (« Se connecter avec EPFL », « EPFL » dans la
            // liste des établissements) : un seul toucher, jamais de saisie.
            if !clicked, (try? await session.run(ssoButtonScript)) == "clicked" {
                clicked = true
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// Touche le bouton d'authentification EPFL d'une page de connexion, s'il
    /// y en a un et un seul candidat évident. Ne remplit aucun champ.
    private static let ssoButtonScript = #"""
    if (document.querySelector('input[type=password]')) return 'form';
    const candidates = [...document.querySelectorAll('a, button, input[type=submit]')]
      .filter(e => e.offsetParent !== null)
      .filter(e => /(\bEPFL\b|tequila|microsoft|single sign|sso|se connecter avec|sign in with|log ?in with)/i
        .test((e.innerText || e.value || e.getAttribute('aria-label') || e.title || '') + ' ' + (e.getAttribute('href') || '')));
    if (candidates.length === 0) return 'none';
    candidates[0].click();
    return 'clicked';
    """#
}
