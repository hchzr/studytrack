import Foundation
import Observation

/// Les sessions de groupe : un chrono **commun** à plusieurs membres.
///
/// L'horloge (marche, pause, pauses Pomodoro) vit sur le serveur
/// (`group_sessions.clock`) ; chaque participant la suit sur son chrono, qui
/// garde son propre cours et sa propre cible. Un geste d'un participant (pause,
/// reprise, pause écourtée) réécrit l'horloge ; les autres la reçoivent par le
/// temps réel. À la fin, chacun enregistre **son** temps, depuis son arrivée.
///
/// Mon Mac suit aussi : il reçoit l'état de mon chrono par le relais
/// (`CloudRelay`), et ses gestes reviennent ici, qui les pousse au groupe.
/// Ce dont la session de groupe a besoin de l'app : le compte, le chrono, les réglages du
/// Pomodoro. L'iPhone (`AppContainer`) et le Mac (`MacGroups`) le fournissent.
@MainActor
protocol GroupSessionHost: AnyObject {
    var social: SocialService { get }
    var groupTimerEngine: TimerEngine { get }
    var groupTimerLocked: Bool { get }
    var groupPomodoroDefault: Bool { get }
    var groupPomodoroCycle: PomodoroSettings { get }
    func groupFinishTimer()
}

extension GroupSessionHost {
    var groupTimerState: FocusTimerState? { groupTimerEngine.state }
    var groupTimerHasSession: Bool { groupTimerEngine.hasSession }
}

@MainActor
@Observable
final class GroupSessionService {
    /// La session en cours de chaque groupe suivi (identifiant distant).
    private(set) var live: [String: RemoteGroupSession] = [:]
    /// Le dernier refus du serveur, en clair.
    private(set) var lastError: String?
    private(set) var isWorking = false

    @ObservationIgnored weak var app: (any GroupSessionHost)?
    @ObservationIgnored private var subscriptions: [String: UUID] = [:]
    @ObservationIgnored private var lastPushed: GroupClock?
    /// La session que ce chrono suivait, pour la quitter à sa fermeture.
    @ObservationIgnored private var linked: GroupSessionLink?
    /// Vrai quand la fermeture vient du groupe (la session est finie) : on ne
    /// renvoie rien au serveur.
    @ObservationIgnored private var closingFromGroup = false

    // MARK: Suivre un groupe

    /// Suit la session d'un groupe (son écran, ou le chrono qui y est lié).
    func watch(groupID: String) {
        guard subscriptions[groupID] == nil, let realtime = app?.social.realtime else {
            Task { await refresh(groupID: groupID) }
            return
        }
        subscriptions[groupID] = realtime.subscribe(groupID: groupID, sessions: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(groupID: groupID) }
        }
        Task { await refresh(groupID: groupID) }
    }

    func unwatch(groupID: String) {
        // Le groupe auquel le chrono est lié reste suivi : ses pauses doivent arriver.
        guard linked?.groupID != groupID, let id = subscriptions.removeValue(forKey: groupID) else { return }
        app?.social.realtime?.unsubscribe(id)
    }

    /// Relit la session d'un groupe et l'applique au chrono s'il y est lié.
    func refresh(groupID: String) async {
        guard let app, app.social.isSignedIn else { return }
        do {
            let session = try await app.social.fetchLiveSession(groupID: groupID)
            live[groupID] = session
            lastError = nil
            apply(session, groupID: groupID)
        } catch {
            lastError = GroupErrorExplainer.explain(raw: String(describing: error))
        }
    }

    /// Retour au premier plan : la session liée a pu bouger pendant la veille.
    func resume() {
        guard let groupID = app?.groupTimerState?.groupSession?.groupID else { return }
        watch(groupID: groupID)
        Task { await refresh(groupID: groupID) }
    }

    private func apply(_ session: RemoteGroupSession?, groupID: String) {
        guard let app, let link = app.groupTimerState?.groupSession, link.groupID == groupID else { return }
        guard let session, session.id == link.sessionID, session.isLive else {
            // La session est finie (ou en a remplacé une autre) : chacun
            // enregistre son temps.
            closingFromGroup = true
            if app.groupTimerLocked {
                // Le verrou tient : on quitte le groupe, la session continue.
                app.groupTimerEngine.detachGroup()
                let left = linked
                linked = nil
                lastPushed = nil
                if let left { Task { try? await app.social.leaveGroupSession(sessionID: left.sessionID) } }
            } else {
                app.groupFinishTimer()
            }
            closingFromGroup = false
            return
        }
        guard session.updated_by != app.social.userID, session.clock != lastPushed else { return }
        lastPushed = session.clock
        app.groupTimerEngine.applyGroupClock(session.clock)
    }

    // MARK: Gestes

    /// Lance une session ensemble — ou rejoint celle qu'un autre vient de lancer.
    func start(group: StudyGroup) async {
        guard let app, let groupID = group.remoteID else { return }
        isWorking = true
        defer { isWorking = false }
        let engine = app.groupTimerEngine
        do {
            // L'horloge part du chrono ouvert ici, sinon d'un chrono qui démarre.
            var clockSource = engine.state
            if clockSource == nil || !engine.hasSession {
                var fresh = FocusTimerState(sessionStartedAt: Date(), pomodoro: app.groupPomodoroDefault)
                fresh.cycle = app.groupPomodoroCycle
                fresh.start()
                clockSource = fresh
            }
            let session = try await app.social.createGroupSession(groupID: groupID, clock: GroupClock(clockSource!))
            let link = GroupSessionLink(sessionID: session.id, groupID: groupID, groupName: group.name)
            if session.host_id == app.social.userID, session.clock == GroupClock(clockSource!) {
                engine.hostGroupSession(link, courseID: engine.state?.courseID, taskType: engine.state?.taskType ?? .exercise,
                                        targetID: engine.state?.targetID)
                lastPushed = session.clock
            } else {
                await join(session, group: group)
            }
            linked = link
            live[groupID] = session
            watch(groupID: groupID)
            Haptics.success()
        } catch {
            lastError = GroupErrorExplainer.explain(raw: String(describing: error))
            Haptics.warning()
        }
    }

    /// Rejoint la session en cours d'un groupe, sur son propre travail.
    func join(_ session: RemoteGroupSession, group: StudyGroup) async {
        guard let app, let groupID = group.remoteID else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await app.social.joinGroupSession(sessionID: session.id, groupID: groupID)
            let link = GroupSessionLink(sessionID: session.id, groupID: groupID, groupName: group.name)
            let engine = app.groupTimerEngine
            engine.joinGroupSession(link, clock: session.clock, courseID: engine.state?.courseID,
                                    taskType: engine.state?.taskType ?? .exercise, targetID: engine.state?.targetID)
            linked = link
            lastPushed = session.clock
            watch(groupID: groupID)
            await refresh(groupID: groupID)
            Haptics.success()
        } catch {
            lastError = GroupErrorExplainer.explain(raw: String(describing: error))
            Haptics.warning()
        }
    }

    /// Termine la session **pour tout le monde** (chacun enregistre son temps).
    func endForEveryone(groupID: String) async {
        guard let app, let session = live[groupID] else { return }
        try? await app.social.updateGroupSession(id: session.id, clock: nil, ended: true)
        await refresh(groupID: groupID)
    }

    // MARK: Le chrono a changé

    /// Appelé par le chrono à chaque changement : un geste d'ici (ou de mon Mac)
    /// part au groupe ; une fermeture quitte la session.
    func timerDidChange(_ change: TimerEngine.Change) {
        guard let app else { return }
        if case .closed = change {
            guard let link = linked else { return }
            linked = nil
            lastPushed = nil
            let fromGroup = closingFromGroup
            Task {
                try? await app.social.leaveGroupSession(sessionID: link.sessionID)
                // Le dernier qui part ferme la session.
                if !fromGroup, let session = try? await app.social.fetchLiveSession(groupID: link.groupID),
                   session.id == link.sessionID, session.present.isEmpty {
                    try? await app.social.updateGroupSession(id: session.id, clock: nil, ended: true)
                }
                self.unwatch(groupID: link.groupID)
                await self.refresh(groupID: link.groupID)
            }
            return
        }
        guard let state = app.groupTimerState, let link = state.groupSession else { return }
        linked = link
        switch change {
        case .gesture, .remote:
            let clock = GroupClock(state)
            guard clock != lastPushed else { return }
            lastPushed = clock
            Task { try? await app.social.updateGroupSession(id: link.sessionID, clock: clock) }
        default:
            break
        }
    }
}
