import Foundation

/// Les cartes du bureau d'étude : ce qu'on pose sur la table selon le moment.
///
/// Le Bureau n'est plus une page fixe : c'est un plan de travail où des cartes
/// (la session, l'exercice, la suite, la musique, l'horaire…) sont choisies
/// selon ce qu'on fait, puis rangées comme l'étudiant·e le veut — masquer,
/// agrandir, déplacer — et retenues **par moment**. Pur et testé ; les cartes
/// elles-mêmes sont dans `StudyTrackMac/StudyMode/DeskWidgetViews.swift`.
enum DeskWidgets {

    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// Le cadran de la session.
        case session
        /// L'exercice visé, ses questions.
        case target
        /// La suite de la série.
        case upNext
        /// Les étapes de « Ta session ».
        case steps
        /// Les reprises dues.
        case redo
        /// Le compte à rebours de l'examen.
        case exam
        /// Le lecteur de musique.
        case music
        /// L'horaire du jour.
        case today
        /// Claude : demander, et sa dernière réponse.
        case claude
        /// Choisir sur quoi travailler (session libre).
        case courses
        /// L'état des comptes de l'école.
        case accounts

        var id: String { rawValue }
    }

    enum Size: String, Codable, CaseIterable {
        case small, medium, large

        var next: Size {
            switch self {
            case .small: return .medium
            case .medium: return .large
            case .large: return .small
            }
        }

        /// La largeur d'une carte (la hauteur suit son contenu).
        var width: Double {
            switch self {
            case .small: return 300
            case .medium: return 420
            case .large: return 640
            }
        }
    }

    struct Placement: Codable, Equatable, Identifiable {
        var kind: Kind
        var size: Size
        var hidden = false
        var id: String { kind.rawValue }
    }

    /// Ce que le bureau sait pour choisir ses cartes.
    struct Context: Equatable {
        var moment: DeskMoment
        var hasCourse: Bool
        var hasSeries = false
        var redosDue = 0
        /// Jours avant le prochain examen (`nil` : aucun).
        var daysToExam: Int?
    }

    /// Les examens à moins de trois semaines méritent leur carte.
    static let examHorizonDays = 21

    /// Les cartes d'un moment, dans l'ordre où elles servent.
    static func defaults(_ c: Context) -> [Placement] {
        func p(_ kind: Kind, _ size: Size) -> Placement { Placement(kind: kind, size: size) }
        guard c.hasCourse else {
            // Session libre : choisir, puis ce que la journée réserve.
            return [p(.courses, .medium), p(.today, .medium), p(.session, .small), p(.music, .small), p(.claude, .small), p(.accounts, .small)]
        }
        var list: [Placement] = [p(.session, .medium), p(.target, .medium)]
        if c.redosDue > 0 { list.append(p(.redo, .medium)) }
        if c.moment == .revision || (c.daysToExam.map { $0 >= 0 && $0 <= examHorizonDays } ?? false) { list.append(p(.exam, .small)) }
        list.append(p(.steps, .medium))
        if c.hasSeries { list.append(p(.upNext, .medium)) }
        list.append(contentsOf: [p(.music, .small), p(.claude, .small), p(.today, .small), p(.accounts, .small)])
        return list
    }

    /// Les cartes montrées : ce que l'étudiant·e a rangé (ordre, taille, masquées),
    /// puis les cartes que le moment propose et qu'elle n'a jamais vues. Une carte
    /// que le moment ne propose plus (pas de reprise due) disparaît, même rangée :
    /// le moment décide de ce qui existe, l'étudiant·e de l'ordre et de la taille.
    static func merged(defaults: [Placement], stored: [Placement]?) -> [Placement] {
        guard let stored else { return defaults }
        let offered = Set(defaults.map(\.kind))
        // Une carte rangée reste ; une carte du moment qui n'a pas été vue s'ajoute.
        var result = stored.filter { offered.contains($0.kind) }
        for placement in defaults where !result.contains(where: { $0.kind == placement.kind }) && !stored.contains(where: { $0.kind == placement.kind }) {
            result.append(placement)
        }
        return result
    }

    /// Déplace la carte `kind` d'un cran (`-1` : avant, `+1` : après), parmi les cartes montrées.
    static func moved(_ kind: Kind, by step: Int, in list: [Placement]) -> [Placement] {
        guard let index = list.firstIndex(where: { $0.kind == kind }) else { return list }
        let visible = list.indices.filter { !list[$0].hidden }
        guard let position = visible.firstIndex(of: index) else { return list }
        let target = position + step
        guard visible.indices.contains(target) else { return list }
        var result = list
        result.swapAt(index, visible[target])
        return result
    }

    /// La largeur d'une carte dans `available` points : sa taille, sans jamais
    /// dépasser la place (le volet d'à côté ouvert rétrécit le centre).
    static func width(of size: Size, available: Double, margin: Double = 80) -> Double {
        min(size.width, max(240, available - margin))
    }

    static func resized(_ kind: Kind, in list: [Placement]) -> [Placement] {
        list.map { $0.kind == kind ? Placement(kind: kind, size: $0.size.next, hidden: $0.hidden) : $0 }
    }

    static func toggled(_ kind: Kind, in list: [Placement]) -> [Placement] {
        list.map { $0.kind == kind ? Placement(kind: kind, size: $0.size, hidden: !$0.hidden) : $0 }
    }

    static func encode(_ list: [Placement]) -> Data? { try? JSONEncoder().encode(list) }

    static func decode(_ data: Data?) -> [Placement]? {
        data.flatMap { try? JSONDecoder().decode([Placement].self, from: $0) }
    }

    /// La clé de rangement : un bureau par moment.
    static func storageKey(_ moment: DeskMoment) -> String { "desk.widgets.\(moment.rawValue)" }
}
