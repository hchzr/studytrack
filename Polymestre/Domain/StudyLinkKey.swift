import Foundation

/// Ce qui identifie un document du cours, quelle que soit la forme de son
/// lien : la même section du polycopié s'écrit `…?polycopie=matiere/m_x`,
/// `…?cours=&polycopie=/handout/matiere/m_x` ou `/handout/matiere/m_x` ; la
/// même vidéo Courseware, `…/xblock/block-v1:…` ou `block-v1:…`. Pur, testé.
enum StudyLinkKey {

    /// Une adresse ramenée à ce qui l'identifie : le chemin d'une section du
    /// polycopié, l'identifiant d'un bloc Courseware, sinon l'adresse sans
    /// fragment ni barre finale.
    static func key(_ address: String) -> String {
        if let path = handoutPath(address) { return "poly:" + path }
        if let block = coursewareBlock(address) { return "edx:" + block }
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        while value.hasSuffix("/") { value.removeLast() }
        return value.lowercased()
    }

    /// `…?polycopie=matiere/m_x`, `…?cours=&polycopie=/handout/matiere/m_x`,
    /// `/handout/matiere/m_x` → `/handout/matiere/m_x`.
    static func handoutPath(_ address: String) -> String? {
        if address.hasPrefix("/handout/") { return address.lowercased() }
        guard let components = URLComponents(string: address), components.host?.contains("botafogo") == true,
              let raw = components.queryItems?.first(where: { $0.name == "polycopie" })?.value, !raw.isEmpty else { return nil }
        return "/handout/" + BotafogoLinks.handoutID(raw).lowercased()
    }

    /// `…/jump_to/block-v1:EPFL+X+2025+type@vertical+block@abc` → le bloc.
    static func coursewareBlock(_ address: String) -> String? {
        guard let range = address.range(of: "block-v1:") else { return nil }
        var block = String(address[range.lowerBound...])
        if let end = block.firstIndex(where: { $0 == "?" || $0 == "#" || $0 == "/" }) { block = String(block[..<end]) }
        return block.removingPercentEncoding ?? block
    }
}
