import Foundation
import UserNotifications

/// Planificateur de notifications locales : rappels de session, échéances, récap hebdo.
final class NotificationScheduler {

    private let center = UNUserNotificationCenter.current()

    // MARK: Autorisation

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: Sessions planifiées

    func scheduleSessionReminder(id: UUID, title: String, date: Date, minutesBefore: Int = 15, location: String = "") {
        let fireDate = date.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        guard fireDate > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Session d'étude dans \(minutesBefore) min"
        content.body = location.isEmpty ? title : "\(title) · \(location)"
        content.sound = .default
        add(identifier: "session-\(id.uuidString)", content: content, date: fireDate)
    }

    // MARK: Évaluations

    func scheduleExamReminders(id: UUID, title: String, examDate: Date, daysBefore: [Int] = [3, 1]) {
        for days in daysBefore {
            let fireDate = DateUtils.addDays(-days, to: examDate)
            guard fireDate > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Échéance dans \(days) jour\(days > 1 ? "s" : "")"
            content.body = title
            content.sound = .default
            add(identifier: "exam-\(id.uuidString)-\(days)", content: content, date: fireDate)
        }
    }

    // MARK: Pomodoro

    static let pomodoroIdentifier = "pomodoro-focus"

    /// Sonne à la fin du bloc de concentration, même app fermée.
    ///
    /// Le mode Pomodoro n'annonçait jamais sa fin : la barre se remplissait, puis
    /// rien. Une notification locale planifiée à l'instant exact du terme est ce
    /// qui rend le mode utile quand l'écran est verrouillé.
    func schedulePomodoroEnd(at date: Date, breakMinutes: Int) {
        cancel(identifier: Self.pomodoroIdentifier)
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Bloc terminé"
        content.body = "Pause de \(breakMinutes) min, puis on reprend."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow),
                                                        repeats: false)
        let request = UNNotificationRequest(identifier: Self.pomodoroIdentifier,
                                            content: content,
                                            trigger: trigger)
        Task { try? await center.add(request) }
    }

    func cancelPomodoro() {
        cancel(identifier: Self.pomodoroIdentifier)
    }

    // MARK: Rappel quotidien

    func scheduleDailyReminder(hour: Int, body: String) {
        center.removePendingNotificationRequests(withIdentifiers: ["daily-reminder"])
        let content = UNMutableNotificationContent()
        content.title = "StudyTrack"
        content.body = body
        content.sound = .default
        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: "daily-reminder", content: content, trigger: trigger)
        Task { try? await center.add(request) }
    }

    // MARK: Récap hebdomadaire

    func scheduleWeeklyRecap(weekday: Int = 1, hour: Int = 19, body: String) {
        center.removePendingNotificationRequests(withIdentifiers: ["weekly-recap"])
        let content = UNMutableNotificationContent()
        content.title = "Récap de la semaine"
        content.body = body
        content.sound = .default
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: "weekly-recap", content: content, trigger: trigger)
        Task { try? await center.add(request) }
    }

    // MARK: Annulation

    func cancel(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func cancelSession(id: UUID) {
        cancel(identifier: "session-\(id.uuidString)")
    }

    func cancelExam(id: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: ["exam-\(id.uuidString)-3",
                                                                   "exam-\(id.uuidString)-1"])
    }

    /// Retire les rappels **planifiés par les données** (sessions, évaluations,
    /// quotidien, hebdo) — pas le Pomodoro en cours, qui appartient au chrono.
    func cancelScheduled() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0 != Self.pomodoroIdentifier }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }

    // MARK: Interne

    private func add(identifier: String, content: UNMutableNotificationContent, date: Date) {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        Task { try? await center.add(request) }
    }

    /// Replanifie tous les rappels à partir des données actuelles.
    ///
    /// Appelé quand l'app passe en arrière-plan : c'est ce qui fait qu'une
    /// évaluation ajoutée ou une session planifiée a bien son rappel, sans que
    /// l'étudiant·e ait à appuyer sur un bouton dans les réglages.
    func rescheduleAll(sessions: [PlannedSession],
                       exams: [Exam],
                       settings: SettingsStore,
                       weeklySummary: String) async {
        guard await authorizationStatus() == .authorized else { return }
        await cancelScheduled()
        for session in sessions where !session.isPast {
            scheduleSessionReminder(id: session.id,
                                    title: session.title,
                                    date: session.startsAt,
                                    location: session.location)
        }
        for exam in exams where exam.date > Date() {
            scheduleExamReminders(id: exam.id,
                                  title: "\(exam.course?.code ?? "") · \(exam.title)",
                                  examDate: exam.date)
        }
        if settings.dailyReminderEnabled {
            scheduleDailyReminder(hour: settings.dailyReminderHour,
                                  body: "Pensez à consulter ce qui reste à faire cette semaine.")
        }
        if settings.weeklyRecapEnabled {
            scheduleWeeklyRecap(weekday: 1, hour: 19, body: weeklySummary)
        }
    }
}

import SwiftData

extension NotificationScheduler {
    /// Relit la base et replanifie tout. Point d'entrée unique pour l'app.
    @MainActor
    func rescheduleFromStore(context: ModelContext, settings: SettingsStore) async {
        let planned = (try? context.fetch(FetchDescriptor<PlannedSession>())) ?? []
        let exams = (try? context.fetch(FetchDescriptor<Exam>())) ?? []
        let sessions = (try? context.fetch(FetchDescriptor<StudySession>())) ?? []
        let weekStart = DateUtils.dateRange(days: 7).start
        let weekSeconds = sessions
            .filter { $0.startedAt >= weekStart }
            .reduce(0) { $0 + $1.durationSeconds }
        await rescheduleAll(sessions: planned,
                            exams: exams,
                            settings: settings,
                            weeklySummary: "Cette semaine : \(DateUtils.hoursLabel(seconds: weekSeconds)) de travail.")
    }
}
