import WidgetKit
import AppIntents
import SwiftUI

// MARK: - Prochaine tâche

/// « Que faire maintenant ? », sur l'écran d'accueil et l'écran verrouillé.
///
/// La même réponse que l'accueil et le dock de l'app (`NextActionEngine`, écrit
/// dans l'instantané). Deux gestes sans ouvrir de liste : **✓** coche la tâche
/// (appliqué par l'app à sa prochaine activation), **▶** ouvre l'app sur le
/// chrono de cette tâche. Pendant une session, le widget montre le chrono.
struct NextActionWidget: Widget {
    let kind = "NextActionWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StudyTrackProvider()) { entry in
            NextActionWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Prochaine tâche")
        .description("La prochaine chose à faire, à cocher ou à démarrer d'un toucher — ou le chrono en cours.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct NextActionWidgetView: View {
    let entry: StudyTrackEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: WidgetSnapshot { entry.snapshot ?? .empty }

    var body: some View {
        if let timer = snapshot.timer {
            timerView(timer)
                .widgetURL(WidgetLink.focus)
        } else if let action = snapshot.next {
            actionView(action)
                .widgetURL(action.isDone ? WidgetLink.today : WidgetLink.start(action))
        } else {
            idleView
                .widgetURL(WidgetLink.today)
        }
    }

    // MARK: Chrono

    @ViewBuilder
    private func timerView(_ timer: WidgetTimer) -> some View {
        switch family {
        case .accessoryInline:
            Label {
                if timer.isRunning {
                    Text(timerInterval: timer.effectiveStart...StudyActivityTimer.horizon(from: timer.effectiveStart),
                     countsDown: false)
                } else {
                    Text("En pause · \(WidgetFormat.hours(Int(timer.elapsedWhenPaused)))")
                }
            } icon: {
                Image(systemName: timer.isRunning ? "timer" : "pause.fill")
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(timer.label).font(.headline).lineLimit(1)
                clock(timer).font(.title3.monospacedDigit().weight(.semibold))
                Text(timer.isRunning ? "En cours" : "En pause").font(.caption2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Label(timer.isRunning ? "En cours" : "En pause", systemImage: timer.isRunning ? "timer" : "pause.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(timer.isRunning ? Color.accentColor : Color.orange.widgetInk)
                Text(timer.label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
                clock(timer)
                    .font(.title.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color(hexString: timer.colorHex).widgetInk)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func clock(_ timer: WidgetTimer) -> some View {
        if timer.isRunning {
            Text(timerInterval: timer.effectiveStart...StudyActivityTimer.horizon(from: timer.effectiveStart),
                     countsDown: false)
        } else {
            Text(Duration.seconds(timer.elapsedWhenPaused).formatted(.time(pattern: .hourMinuteSecond)))
        }
    }

    // MARK: Action

    @ViewBuilder
    private func actionView(_ action: WidgetAction) -> some View {
        let tint = Color(hexString: action.colorHex)
        switch family {
        case .accessoryInline:
            Label("\(action.courseCode) · \(action.title)", systemImage: action.isDone ? "checkmark" : action.icon)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(action.isDone ? "Fait ✓" : action.reason).font(.caption2.weight(.semibold))
                Text("\(action.courseCode) · \(action.title)").font(.headline).lineLimit(1)
                Text(action.detail).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemSmall:
            VStack(alignment: .leading, spacing: 4) {
                reasonLabel(action)
                Text(action.courseCode)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint.widgetInk)
                Text(action.title)
                    .font(.headline)
                    .lineLimit(2)
                    .strikethrough(action.isDone)
                Spacer(minLength: 0)
                HStack {
                    completeButton(action)
                    Spacer()
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(tint.widgetInk)
                        .accessibilityLabel("Démarrer le chrono")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint)
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 4) {
                    reasonLabel(action)
                    Text("\(action.courseCode) · \(action.title)")
                        .font(.headline)
                        .lineLimit(1)
                        .strikethrough(action.isDone)
                    Text(action.isDone ? "Coché — l'app passe à la suite à la prochaine ouverture." : action.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        completeButton(action)
                        if !action.isDone {
                            Link(destination: WidgetLink.start(action)) {
                                Label("Démarrer", systemImage: "play.fill")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(tint.opacity(0.18), in: Capsule())
                                    .foregroundStyle(tint.widgetInk)
                            }
                        }
                        Spacer()
                        if snapshot.todoCount > 1 {
                            Text("+\(snapshot.todoCount - 1) ensuite")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func reasonLabel(_ action: WidgetAction) -> some View {
        Label(action.isDone ? "Fait" : action.reason, systemImage: action.isDone ? "checkmark.circle.fill" : action.icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(action.isDone ? Color.green.widgetInk : Color.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func completeButton(_ action: WidgetAction) -> some View {
        if action.canComplete, let kind = action.targetKind, let id = action.targetID {
            Button(intent: CompleteNextActionIntent(kind: kind, targetID: id)) {
                Image(systemName: action.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(action.isDone ? Color.green.widgetInk : Color.secondary)
                    // Le cercle se change en coche : seul retour visible du geste.
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(action.isDone)
            .accessibilityLabel(action.isDone ? "Fait" : "Marquer \(action.title) comme fait")
        }
    }

    // MARK: Rien à faire

    @ViewBuilder
    private var idleView: some View {
        switch family {
        case .accessoryInline:
            Label("Tout est à jour", systemImage: "checkmark.seal")
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("Tout est à jour").font(.headline)
                Text(snapshot.hasContent ? "Rien d'urgent cette semaine" : "Ouvre StudyTrack").font(.caption)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(Color.green.widgetInk)
                Text(snapshot.hasContent ? "Tout est à jour" : "Ouvre StudyTrack")
                    .font(.headline)
                Text(snapshot.hasContent ? "Rien d'urgent cette semaine." : "Pour voir ta prochaine tâche ici.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Cours de la semaine

/// Où en est chaque cours cette semaine — la carte « Cette semaine » de l'accueil.
struct WeekCoursesWidget: Widget {
    let kind = "WeekCoursesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StudyTrackProvider()) { entry in
            WeekCoursesWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WidgetLink.courses)
        }
        .configurationDisplayName("Cours de la semaine")
        .description("Ce qu'il reste à faire dans chaque cours cette semaine.")
        .supportedFamilies([.systemMedium, .systemLarge, .accessoryCircular])
    }
}

struct WeekCoursesWidgetView: View {
    let entry: StudyTrackEntry
    @Environment(\.widgetFamily) private var family

    private var courses: [WidgetCourse] {
        (entry.snapshot?.courses ?? [])
            .sorted { lhs, rhs in
                let left = lhs.total - lhs.done, right = rhs.total - rhs.done
                if (left > 0) != (right > 0) { return left > 0 }
                return left != right ? left > right : lhs.code < rhs.code
            }
    }

    private var overall: (done: Int, total: Int) {
        courses.reduce((0, 0)) { ($0.0 + $1.done, $0.1 + $1.total) }
    }

    var body: some View {
        if family == .accessoryCircular {
            let totals = overall
            Gauge(value: Double(totals.done), in: 0...Double(max(totals.total, 1))) {
                Image(systemName: "books.vertical")
            } currentValueLabel: {
                Text("\(totals.total == 0 ? 0 : totals.done * 100 / totals.total)")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
            .accessibilityLabel("Semaine faite à \(totals.total == 0 ? 0 : totals.done * 100 / totals.total) %")
        } else if courses.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "books.vertical").foregroundStyle(.tint)
                Text("Aucun cours suivi").font(.headline)
                Text("Ajoute tes cours dans StudyTrack.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 6) {
                HStack {
                    Label("Cette semaine", systemImage: "calendar")
                        .font(.caption.weight(.bold))
                    Spacer()
                    let totals = overall
                    Text("\(totals.done)/\(totals.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ForEach(courses.prefix(family == .systemLarge ? 8 : 3)) { course in
                    Link(destination: WidgetLink.course(course.id)) {
                        row(course)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ course: WidgetCourse) -> some View {
        let tint = Color(hexString: course.colorHex)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(course.code)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint.widgetInk)
                Text(course.summary)
                    .font(.caption2)
                    .foregroundStyle(course.total > 0 && course.done == course.total ? Color.green.widgetInk : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if course.total > 0 {
                    Text("\(course.done)/\(course.total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(course.done), total: Double(max(course.total, 1)))
                .tint(tint)
                .opacity(course.total == 0 ? 0.3 : 1)
        }
    }
}

// MARK: - Prochaine évaluation

struct ExamCountdownWidget: Widget {
    let kind = "ExamCountdownWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StudyTrackProvider()) { entry in
            ExamCountdownWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WidgetLink.agenda)
        }
        .configurationDisplayName("Prochaine évaluation")
        .description("Le compte à rebours jusqu'au prochain midterm ou examen.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline])
    }
}

struct ExamCountdownWidgetView: View {
    let entry: StudyTrackEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snapshot = entry.snapshot ?? .empty
        if let date = snapshot.nextExamDate, date >= Calendar.current.startOfDay(for: entry.date) {
            let title = snapshot.nextExamTitle ?? "Évaluation"
            let course = snapshot.nextExamCourse ?? ""
            let countdown = WidgetFormat.countdown(to: date, from: entry.date)
            switch family {
            case .accessoryInline:
                Label("\(course) \(title) · \(countdown)", systemImage: "graduationcap")
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text(countdown).font(.headline)
                    Text("\(course) · \(title)").font(.caption).lineLimit(1)
                    Text(date, style: .date).font(.caption2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Évaluation", systemImage: "graduationcap.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.orange.widgetInk)
                    Text(countdown)
                        .font(.largeTitle.weight(.bold))
                        .contentTransition(.numericText())
                        .widgetAccentable()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(course).font(.caption.weight(.bold))
                    Text(title).font(.caption).lineLimit(2)
                    Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            switch family {
            case .accessoryInline:
                Label("Aucune évaluation prévue", systemImage: "graduationcap")
            default:
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "graduationcap").foregroundStyle(.secondary)
                    Text("Aucune évaluation prévue").font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Centre de contrôle

/// Un bouton « Chrono » pour le Centre de contrôle, l'écran verrouillé et le
/// bouton Action : ouvre StudyTrack sur Focus, sans chercher l'app.
@available(iOS 18.0, *)
struct FocusControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "StudyTrackFocusControl") {
            ControlWidgetButton(action: OpenURLIntent(WidgetLink.focus)) {
                Label("Chrono StudyTrack", systemImage: "timer")
            }
        }
        .displayName("Chrono StudyTrack")
        .description("Ouvre le chrono de StudyTrack.")
    }
}

/// Un interrupteur pause / reprise pour la session en cours.
///
/// Il complète `FocusControl` au lieu de le remplacer : démarrer une session
/// demande de choisir un cours, donc l'app ; la mettre en pause, non. Sans
/// session, l'interrupteur le dit et ne fait rien.
@available(iOS 18.0, *)
struct FocusPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "StudyTrackFocusPauseControl",
                                   provider: FocusTimerValueProvider()) { value in
            ControlWidgetToggle(isOn: value.isRunning, action: ToggleFocusTimerIntent()) {
                Text(value.label)
            } valueLabel: { isOn in
                Label(value.hasSession ? (isOn ? "En cours" : "En pause") : "Aucune session",
                      systemImage: isOn ? "pause.fill" : "play.fill")
            }
            .tint(.indigo)
        }
        .displayName("Pause du chrono")
        .description("Met en pause ou relance la session en cours.")
    }
}

@available(iOS 18.0, *)
struct FocusTimerValue {
    var hasSession: Bool
    var isRunning: Bool
    var label: String
}

/// Lit le chrono dans l'instantané partagé, le même que les widgets.
@available(iOS 18.0, *)
struct FocusTimerValueProvider: ControlValueProvider {
    var previewValue: FocusTimerValue {
        FocusTimerValue(hasSession: true, isRunning: true, label: "CS-250 · Exercices")
    }

    func currentValue() async throws -> FocusTimerValue {
        guard let timer = WidgetBridge.read()?.timer else {
            return FocusTimerValue(hasSession: false, isRunning: false, label: "Chrono")
        }
        return FocusTimerValue(hasSession: true, isRunning: timer.isRunning, label: timer.label)
    }
}
