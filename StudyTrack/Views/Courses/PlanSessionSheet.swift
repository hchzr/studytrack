import SwiftUI
import SwiftData

/// Planifie une session d'étude personnelle et l'écrit dans le calendrier système.
///
/// C'est le seul endroit où une session personnelle se crée : avant, seuls les
/// groupes savaient en planifier une, et rien n'arrivait dans l'agenda du système.
struct PlanSessionSheet: View {
    let course: Course

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app

    @State private var title = "Session d'étude"
    @State private var start = DateUtils.addDays(1, to: Date())
    @State private var minutes = 90
    @State private var location = ""
    @State private var writeToCalendar = true
    @State private var calendarProblem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    TextField("Titre", text: $title)
                    DatePicker("Début", selection: $start,
                               displayedComponents: [.date, .hourAndMinute])
                    Stepper("Durée : \(minutes) min", value: $minutes, in: 15...480, step: 15)
                    TextField("Lieu (optionnel)", text: $location)
                }

                Section {
                    Toggle("Ajouter à mon calendrier", isOn: $writeToCalendar)
                        .disabled(!app.calendar.hasAccess)
                } header: {
                    Text("Calendrier")
                } footer: {
                    if !app.calendar.hasAccess {
                        Text("Autorise le calendrier (Réglages › Horaire et calendrier) pour l'y voir aussi.")
                    }
                }

                if let calendarProblem {
                    Section {
                        Label(calendarProblem, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.orange.accessibleInk)
                    }
                }
            }
            .carnetBackground()
            .navigationTitle("Planifier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Planifier") { save() }
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let session = PlannedSession(course: course,
                                     title: trimmedTitle.isEmpty ? "Session d'étude" : trimmedTitle,
                                     startsAt: start,
                                     durationMinutes: minutes,
                                     location: location.trimmingCharacters(in: .whitespaces))
        context.insert(session)
        PlannedSessionActions.scheduleReminder(for: session, app: app)

        if writeToCalendar, app.calendar.hasAccess {
            let spec = CalendarEventSpec(title: session.title,
                                         startsAt: session.startsAt,
                                         endsAt: session.endsAt,
                                         location: session.location,
                                         notes: "Session d'étude planifiée dans StudyTrack — \(course.displayCode).",
                                         calendarTitle: "StudyTrack")
            if let identifier = app.calendar.createEvent(spec) {
                session.externalCalendarEventID = identifier
            } else {
                // La planification n'est pas perdue si le calendrier refuse : la
                // session existe dans StudyTrack. On le dit et on laisse la feuille
                // ouverte, pour que le message soit lu.
                try? context.save()
                Haptics.warning()
                calendarProblem = "La session est planifiée dans StudyTrack, mais le calendrier a refusé l'événement. Tu peux réessayer, ou planifier sans calendrier."
                return
            }
        }

        try? context.save()
        Haptics.success()
        dismiss()
    }
}

/// Ce qu'une session planifiée entraîne ailleurs — calendrier système et rappel —
/// et qu'il faut défaire avec elle. Partagé par les trois écrans qui en suppriment.
enum PlannedSessionActions {
    @MainActor
    static func delete(_ session: PlannedSession, context: ModelContext, app: AppContainer) {
        if !session.externalCalendarEventID.isEmpty {
            app.calendar.deleteEvent(identifier: session.externalCalendarEventID)
        }
        app.notifications.cancelSession(id: session.id)
        context.delete(session)
        try? context.save()
        Haptics.tap()
    }

    /// Le rappel local, 15 minutes avant — pour toute session à venir.
    @MainActor
    static func scheduleReminder(for session: PlannedSession, app: AppContainer) {
        app.notifications.scheduleSessionReminder(id: session.id,
                                                  title: session.title,
                                                  date: session.startsAt,
                                                  location: session.location)
    }
}
