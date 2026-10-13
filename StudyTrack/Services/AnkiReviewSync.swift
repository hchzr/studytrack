import Foundation
import SwiftData

/// Relève le temps passé dans Anki et l'enregistre en sessions étiquetées « Anki ».
///
/// L'étudiant·e ne saisit rien : connecté·e à AnkiWeb, chaque passage au
/// premier plan rapatrie les révisions faites depuis le dernier relevé. Hors
/// réseau n'est pas une erreur — on réessaiera au prochain passage, sans bruit.
/// `@MainActor` : le contexte reçu est celui de l'écran ; l'écrire après un
/// `await` depuis un autre fil corrompait SwiftData.
@MainActor
enum AnkiReviewSync {

    /// Pas plus d'un relevé toutes les dix minutes : `didBecomeActive` arrive
    /// souvent, et AnkiWeb n'a rien de nouveau à dire entre deux.
    static let minimumInterval: TimeInterval = 10 * 60

    struct Outcome {
        var sessionsAdded: Int
        var seconds: Int
    }

    @MainActor
    @discardableResult
    static func syncIfDue(context: ModelContext, settings: SettingsStore, force: Bool = false) async -> Outcome? {
        let web = AnkiWebSync.shared
        guard web.isSignedIn else { return nil }
        if !force, let last = settings.ankiLastSync, Date().timeIntervalSince(last) < minimumInterval { return nil }
        return try? await sync(context: context, settings: settings)
    }

    /// Les révisions arrivent d'AnkiWeb (la copie de la collection, relue si le
    /// serveur a changé).
    @MainActor
    static func sync(context: ModelContext, settings: SettingsStore) async throws -> Outcome {
        let web = AnkiWebSync.shared
        try await web.refreshMirror()
        await web.pushPending()
        let reviews = web.newReviews()

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

        settings.ankiLastSync = Date()
        AppLog.record(.info, "anki", "\(added) session(s) Anki relevée(s), \(seconds) s")
        return Outcome(sessionsAdded: added, seconds: seconds)
    }
}
