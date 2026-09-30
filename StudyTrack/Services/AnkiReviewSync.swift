import Foundation
import SwiftData

/// Relève le temps passé dans Anki et l'enregistre en sessions étiquetées « Anki ».
///
/// L'étudiant·e ne saisit rien : dès qu'AnkiConnect est joignable, chaque
/// passage au premier plan rapatrie les révisions faites depuis le dernier
/// relevé. Anki fermé ou hors réseau n'est pas une erreur — on réessaiera au
/// prochain passage, sans bruit.
enum AnkiReviewSync {

    /// Pas plus d'un relevé toutes les dix minutes : `didBecomeActive` arrive
    /// souvent, et AnkiConnect n'a rien de nouveau à dire entre deux.
    static let minimumInterval: TimeInterval = 10 * 60

    struct Outcome {
        var sessionsAdded: Int
        var seconds: Int
    }

    @MainActor
    @discardableResult
    static func syncIfDue(context: ModelContext, settings: SettingsStore, force: Bool = false) async -> Outcome? {
        let web = AnkiWebSync.shared
        guard web.isSignedIn || settings.isAnkiConfigured else { return nil }
        if !force, let last = settings.ankiLastSync, Date().timeIntervalSince(last) < minimumInterval { return nil }
        return try? await sync(context: context, settings: settings)
    }

    /// Les révisions arrivent d'AnkiWeb (la copie de la collection, relue si le
    /// serveur a changé) ; à défaut, d'AnkiConnect sur le réseau local.
    @MainActor
    static func sync(context: ModelContext, settings: SettingsStore) async throws -> Outcome {
        var reviews: [AnkiReview] = []
        let web = AnkiWebSync.shared
        if web.isSignedIn {
            try await web.refreshMirror()
            await web.pushPending()
            reviews = web.newReviews()
        } else {
            reviews = try await connectReviews(settings: settings)
        }

        let drafts = AnkiReviewImport.sessions(from: reviews)
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        let known = Set(((try? context.fetch(FetchDescriptor<StudySession>())) ?? [])
            .filter(\.isFromAnki).map(\.externalKey))
        let keys = courses.map { (code: $0.code, shortName: $0.shortName, name: $0.name) }

        var added = 0
        var seconds = 0
        for draft in drafts where !known.contains(draft.key) {
            let course = AnkiReviewImport.courseIndex(forDeck: draft.deck, courses: keys).map { courses[$0] }
            let session = StudySession(course: course,
                                       taskType: .flashcards,
                                       startedAt: draft.start,
                                       durationSeconds: draft.seconds,
                                       isManual: false,
                                       note: "Anki · \(draft.deck) · \(draft.reviewCount) carte\(draft.reviewCount > 1 ? "s" : "")")
            session.sourceRaw = "anki"
            session.externalKey = draft.key
            context.insert(session)
            added += 1
            seconds += draft.seconds
        }
        if added > 0 { try? context.save() }

        if !web.isSignedIn, let last = reviews.map(\.id).max() { settings.ankiLastReviewID = Double(last) + 1 }
        settings.ankiLastSync = Date()
        AppLog.record(.info, "anki", "\(added) session(s) Anki relevée(s), \(seconds) s")
        return Outcome(sessionsAdded: added, seconds: seconds)
    }

    /// AnkiConnect (Anki Desktop sur le réseau local), l'ancienne voie.
    @MainActor
    private static func connectReviews(settings: SettingsStore) async throws -> [AnkiReview] {
        let endpoint = settings.ankiEndpoint
        let decks = try await AnkiService.deckNames(endpoint: endpoint)
        // Premier relevé : le semestre en cours suffit (30 jours au plus tôt).
        let floor = Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970 * 1000
        let startID = settings.ankiLastReviewID > 0 ? settings.ankiLastReviewID : floor
        var reviews: [AnkiReview] = []
        for deck in decks where deck != "Default" || decks.count == 1 {
            let outcome = try await AnkiService.call("cardReviews",
                                                     params: ["deck": deck, "startID": Int64(startID)],
                                                     endpoint: endpoint)
            reviews += AnkiReviewImport.reviews(from: outcome, deck: deck)
        }
        return reviews
    }
}
