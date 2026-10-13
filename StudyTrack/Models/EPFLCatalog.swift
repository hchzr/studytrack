import Foundation

/// Une section EPFL (programme d'études).
struct EPFLSection: Identifiable, Hashable {
    let code: String
    let name: String
    let faculty: String

    var id: String { code }
    var displayName: String { name }
    var subtitle: String { "\(faculty) · \(code)" }
}

/// Catalogue de sections EPFL.
///
/// Sert uniquement à aider l'étudiant·e à se situer : la section choisie est
/// stockée dans les réglages et recopiée sur chaque cours (`Course.sectionCode`).
/// La liste est indicative et peut être complétée librement depuis l'app.
enum EPFLCatalog {

    static let sections: [EPFLSection] = [
        // Faculté ENAC
        EPFLSection(code: "AR", name: "Architecture", faculty: "ENAC"),
        EPFLSection(code: "GC", name: "Génie civil", faculty: "ENAC"),
        EPFLSection(code: "SIE", name: "Sciences et ingénierie de l'environnement", faculty: "ENAC"),

        // Faculté STI
        EPFLSection(code: "GM", name: "Génie mécanique", faculty: "STI"),
        EPFLSection(code: "MT", name: "Microtechnique", faculty: "STI"),
        EPFLSection(code: "MX", name: "Science et ingénierie des matériaux", faculty: "STI"),
        EPFLSection(code: "EL", name: "Génie électrique et électronique", faculty: "STI"),

        // Faculté IC
        EPFLSection(code: "IN", name: "Informatique", faculty: "IC"),
        EPFLSection(code: "SC", name: "Systèmes de communication", faculty: "IC"),

        // Faculté SB
        EPFLSection(code: "MA", name: "Mathématiques", faculty: "SB"),
        EPFLSection(code: "PH", name: "Physique", faculty: "SB"),
        EPFLSection(code: "CGC", name: "Chimie et génie chimique", faculty: "SB"),
        EPFLSection(code: "SV", name: "Ingénierie des sciences du vivant", faculty: "SB"),

        // Faculté CDH
        EPFLSection(code: "DH", name: "Humanités digitales", faculty: "CDH"),

        // Faculté MTEI
        EPFLSection(code: "MTE", name: "Management, technologie et entrepreneuriat", faculty: "MTEI"),

        // Masters inter-facultaires
        EPFLSection(code: "INGM", name: "Ingénierie mathématique", faculty: "SB"),
        EPFLSection(code: "DS", name: "Data science", faculty: "IC"),
        EPFLSection(code: "CYS", name: "Cybersécurité", faculty: "IC"),
        EPFLSection(code: "NX", name: "Neuro-X", faculty: "SV"),
        EPFLSection(code: "QS", name: "Quantum science and engineering", faculty: "SB"),
        EPFLSection(code: "EN", name: "Energy science and technology", faculty: "STI"),
        EPFLSection(code: "MS", name: "Materials science and engineering", faculty: "STI"),
        EPFLSection(code: "SMT", name: "Sustainable management and technology", faculty: "MTEI"),
        EPFLSection(code: "MNE", name: "Micro- et nanotechnologies", faculty: "STI"),
        EPFLSection(code: "ROB", name: "Robotics", faculty: "STI"),
        EPFLSection(code: "BIO", name: "Bioengineering", faculty: "SV"),
        EPFLSection(code: "AM", name: "Applied mathematics", faculty: "SB"),
        EPFLSection(code: "COM", name: "Communication systems", faculty: "IC")
    ]

    static func section(code: String) -> EPFLSection? {
        sections.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }

    static func search(_ query: String) -> [EPFLSection] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return sections }
        let needle = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return sections.filter {
            $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(needle)
                || $0.code.caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.faculty.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    static func sections(inFaculty faculty: String) -> [EPFLSection] {
        sections.filter { $0.faculty == faculty }
    }
}
