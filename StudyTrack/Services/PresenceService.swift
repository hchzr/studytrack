import Foundation
import Observation
import SwiftData

/// Publie « je travaille sur … » vers les groupes, et le retire quand j'arrête.
///
/// Le principe est un **battement** : la ligne distante porte un `updated_at`, et
/// les autres considèrent que je travaille tant qu'il est récent. C'est ce qui rend
/// la présence honnête — un téléphone qui se met en veille, une app tuée ou un
/// réseau coupé finissent par m'éteindre tout seuls, sans fausse déclaration.
///
/// Corollaire assumé : écran verrouillé, le battement s'arrête au bout de quelques
/// minutes et je disparais du direct — alors que le chrono, lui, tourne toujours.
/// La durée de travail enregistrée reste juste ; seule la présence s'éteint.
///
/// La classe n'est **pas** `@MainActor` dans son ensemble : `AppContainer` la
/// construit depuis un initialiseur non isolé. Seuls les deux points d'entrée le
/// sont, puisque ce sont eux qui touchent l'interface.
@Observable
final class PresenceService {

    /// Le battement en cours, s'il y en a un.
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    /// Ce que je suis en train de publier — réutilisé par chaque battement.
    @ObservationIgnored private var current: PresenceEntry?

    private(set) var isSharing = false
    /// Dernier refus du serveur, en clair.
    ///
    /// La première version avalait tout avec `try?` : une table `presence` absente
    /// côté Supabase donnait exactement le même résultat qu'une présence qui
    /// fonctionne — rien à l'écran. Un échec silencieux est un bogue de plus.
    private(set) var lastError: String?
    /// Ce qui a été publié en dernier, pour que l'écran puisse le montrer.
    private(set) var publishedSummary: String?

    init() {}

    /// Annonce une session de travail, ou l'arrête avec `nil`.
    @MainActor
    func announce(_ entry: PresenceEntry?,
                  context: ModelContext,
                  social: SocialService) {
        heartbeat?.cancel()
        heartbeat = nil
        current = entry

        let groupIDs = Self.shareableGroupIDs(context: context, social: social)

        guard let entry, !groupIDs.isEmpty, social.isSignedIn else {
            // Rien à annoncer, ou rien à qui l'annoncer. Il faut malgré tout
            // **effacer** ce qui reste, sinon un membre demeure « en train de
            // travailler » pendant un quart d'heure après avoir appuyé sur stop.
            //
            // Mais seulement si quelque chose avait été publié : changer de cours
            // sans chrono en marche ne doit pas produire une requête réseau.
            guard isSharing else { return }
            isSharing = false
            publishedSummary = nil
            Task {
                try? await social.publishPresence(nil, groupIDs: groupIDs)
            }
            return
        }

        isSharing = true

        heartbeat = Task { [weak self] in
            // Un premier envoi immédiat : attendre cinq minutes avant d'apparaître
            // rendrait la fonctionnalité inutile pour les sessions courtes.
            await self?.publish(entry, groupIDs: groupIDs, social: social)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(PresenceEntry.heartbeat))
                if Task.isCancelled { break }
                guard let self, let current = self.current else { break }
                await self.publish(current, groupIDs: groupIDs, social: social)
            }
        }
    }

    /// Publie une fois et retient le verdict.
    @MainActor
    private func publish(_ entry: PresenceEntry,
                         groupIDs: [String],
                         social: SocialService) async {
        do {
            try await social.publishPresence(entry, groupIDs: groupIDs)
            lastError = nil
            publishedSummary = "\(entry.activityLabel.isEmpty ? "Travail en cours" : entry.activityLabel) · \(groupIDs.count) groupe\(groupIDs.count > 1 ? "s" : "")"
        } catch {
            lastError = GroupSync.explain(error)
            publishedSummary = nil
        }
    }

    /// Arrête tout, par exemple quand le chrono est terminé.
    @MainActor
    func stop(context: ModelContext, social: SocialService) {
        announce(nil, context: context, social: social)
    }

    /// Les groupes où la présence a un sens : distants, et dont je suis membre.
    ///
    /// Publier vers un groupe non synchronisé n'aurait aucune destination, et
    /// publier vers un groupe que j'ai quitté n'aurait aucun lecteur.
    static func shareableGroupIDs(context: ModelContext, social: SocialService) -> [String] {
        let groups = (try? context.fetch(FetchDescriptor<StudyGroup>())) ?? []
        return groups.compactMap { group in
            guard let remoteID = group.remoteID else { return nil }
            guard group.members.contains(where: \.isMe) else { return nil }
            return remoteID
        }
    }
}
