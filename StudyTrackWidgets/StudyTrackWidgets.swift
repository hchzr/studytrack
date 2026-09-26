import WidgetKit
import ActivityKit
import AppIntents
import SwiftUI
import UIKit

// MARK: - Timeline

struct StudyTrackEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?

    static var placeholder: StudyTrackEntry {
        StudyTrackEntry(date: Date(), snapshot: WidgetSnapshot(
            updatedAt: Date(),
            weekSeconds: 12 * 3600 + 1800,
            streak: 6,
            level: 3,
            xp: 240,
            todoCount: 7,
            todos: [
                WidgetTodo(id: "1", courseCode: "CS-250", title: "Vidéo 2.1 · Récurrences", kind: "Vidéo", colorHex: "#4F46E5"),
                WidgetTodo(id: "2", courseCode: "CS-250", title: "Exercice 2.2", kind: "Exercice", colorHex: "#4F46E5"),
                WidgetTodo(id: "3", courseCode: "MATH-101", title: "Vidéo 1.2 · Continuité", kind: "Vidéo", colorHex: "#0EA5E9")
            ],
            nextExamTitle: "Midterm",
            nextExamCourse: "CS-250",
            nextExamDate: Date().addingTimeInterval(12 * 86400)))
    }
}

struct StudyTrackProvider: TimelineProvider {
    func placeholder(in context: Context) -> StudyTrackEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (StudyTrackEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(StudyTrackEntry(date: Date(), snapshot: WidgetBridge.read()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StudyTrackEntry>) -> Void) {
        let entry = StudyTrackEntry(date: Date(), snapshot: WidgetBridge.read())
        // L'app recharge explicitement les timelines ; ce rafraîchissement périodique
        // n'est qu'un filet de sécurité.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
            ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Widgets

struct StudyTrackWidget: Widget {
    let kind = "StudyTrackWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StudyTrackProvider()) { entry in
            StudyTrackWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                // Un tap ouvre « Aujourd'hui » : c'est là que la liste continue.
                .widgetURL(WidgetLink.today)
        }
        .configurationDisplayName("Cette semaine")
        .description("Ce qu'il te reste à faire et ton temps de travail.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Widget de la session en cours (chrono lancé depuis l'app).
struct StudyTrackTimerWidget: Widget {
    let kind = "StudyTrackTimerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StudyTrackProvider()) { entry in
            StudyTrackTimerWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                // Le widget « temps » mène au chrono, pas à la liste.
                .widgetURL(WidgetLink.focus)
        }
        .configurationDisplayName("Temps de travail")
        .description("Ton temps travaillé sur les 7 derniers jours.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Live Activity : le chrono en cours

/// Chrono en cours, sur l'écran verrouillé et dans l'îlot dynamique.
///
/// Le compteur s'appuie sur `Text(timerInterval:)` : c'est le **système** qui le
/// fait avancer, chaque seconde, sans que l'app envoie quoi que ce soit. Une Live
/// Activity qui recevrait une mise à jour par seconde coûterait de la batterie et
/// du réseau pour un résultat identique.
///
/// **Forme compacte** : l'îlot se contente d'une icône et du temps. Y écrire le
/// code du cours l'élargissait en permanence, pour une information qu'on retrouve
/// dans la forme dépliée — qui, elle, ne coûte rien tant qu'on ne la déplie pas.
struct StudyActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StudyActivityAttributes.self) { context in
            StudyActivityLockView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    // L'anneau remplace l'icône quand la session est en Pomodoro :
                    // il porte la même information — le chrono tourne — et il dit
                    // en plus où en est le bloc.
                    StudyActivityLeading(state: context.state)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StudyActivityTimer(state: context.state, font: .title3, compact: true)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // Le bouton utile, centré, **sans** largeur imposée :
                    // `maxWidth: .infinity` faisait réclamer toute la place.
                    StudyActivityControls(state: context.state, compact: true)
                }
            } compactLeading: {
                // L'état, à gauche ; le temps, à droite. **Ne plus vider ces deux
                // régions** : les laisser vides ne rapetissait pas l'îlot, il
                // n'affichait plus rien du tout.
                StudyActivityLeading(state: context.state, tiny: true)
            } compactTrailing: {
                StudyActivityTimer(state: context.state, font: .caption2, compact: true)
            } minimal: {
                StudyActivityLeading(state: context.state, tiny: true)
            }
            .keylineTint(context.state.isRunning ? .indigo : .orange)
        }
    }
}

/// Ce qui occupe la gauche de l'îlot : l'anneau du bloc, sinon l'état.
///
/// Une seule région, deux contenus possibles, pour ne pas élargir l'îlot : un
/// anneau **et** une icône côte à côte coûtent une place que la forme repliée n'a
/// pas.
struct StudyActivityLeading: View {
    let state: StudyActivityAttributes.ContentState
    var tiny: Bool = false

    var body: some View {
        if let pomodoro = state.pomodoro {
            StudyActivityPomodoroRing(pomodoro: pomodoro,
                                      isRunning: state.isRunning,
                                      tiny: tiny)
        } else {
            StudyActivityStateIcon(state: state, tiny: tiny)
        }
    }
}

/// L'anneau du bloc Pomodoro.
///
/// `ProgressView(timerInterval:)` est le même mécanisme que `Text(timerInterval:)`
/// pour le compteur : c'est le **système** qui remplit l'anneau, seconde après
/// seconde, à partir des deux bornes du bloc. L'app n'envoie rien pendant ce
/// temps-là — une mise à jour par seconde coûterait de la batterie pour un
/// résultat identique.
///
/// En pause, et sur un bloc arrivé à terme, il n'y a pas d'intervalle à animer :
/// l'anneau est alors dessiné **figé**, à la fraction déjà faite. Un anneau qui
/// continuerait de se remplir pendant une pause mentirait — le chrono compte le
/// travail, et une pause n'en est pas.
struct StudyActivityPomodoroRing: View {
    let pomodoro: ActivityPomodoro
    let isRunning: Bool
    var tiny: Bool = false

    private var tint: Color {
        if pomodoro.isBlockComplete { return .orange }
        return isRunning ? .green : .orange
    }

    var body: some View {
        Group {
            if let interval = pomodoro.interval {
                ProgressView(timerInterval: interval, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.circular)
            } else {
                // Figé : la fraction déjà faite, sans animation.
                ProgressView(value: pomodoro.frozenProgress)
                    .progressViewStyle(.circular)
            }
        }
        .tint(tint)
        .frame(width: tiny ? 18 : 30, height: tiny ? 18 : 30)
        .accessibilityLabel("\(pomodoro.label), \(Int(pomodoro.frozenProgress * 100)) %")
    }
}

/// L'état du chrono en une icône : elle remplace le liseré de couleur, qui
/// élargissait l'îlot d'un cadre.
struct StudyActivityStateIcon: View {
    let state: StudyActivityAttributes.ContentState
    var tiny: Bool = false

    var body: some View {
        Image(systemName: state.isRunning ? "play.circle.fill" : "pause.circle.fill")
            .font(tiny ? .system(size: 11) : .title3)
            .foregroundStyle(state.isRunning ? .green : .orange)
            .accessibilityLabel(state.isRunning ? "Chrono en cours" : "Chrono en pause")
    }
}

/// « CS-250 · Exercices · 3.2 » — tout sur une ligne, tronquée au milieu.
///
/// Le nom complet du cours est écarté : dans l'îlot, il chassait le reste. Il
/// reste lisible dans l'écran verrouillé, où la place ne manque pas.
enum StudyActivityTitle {
    static func text(for attributes: StudyActivityAttributes) -> String {
        var parts = [attributes.courseCode, attributes.taskLabel]
        if let target = attributes.target, !target.isEmpty { parts.append(target) }
        return parts.joined(separator: " · ")
    }
}

/// « Vidéo · 2.1 » — la version courte, pour l'écran verrouillé.
enum StudyActivitySubtitle {
    static func text(for attributes: StudyActivityAttributes) -> String {
        var parts = [attributes.taskLabel]
        if let target = attributes.target, !target.isEmpty { parts.append(target) }
        return parts.joined(separator: " · ")
    }
}

/// Les boutons du chrono, dans l'îlot et sur l'écran verrouillé.
///
/// Ils exécutent des `LiveActivityIntent`, qui tournent dans le **processus de
/// l'app** : mettre en pause ou enregistrer une session depuis l'écran verrouillé
/// ne demande donc pas d'ouvrir l'app.
struct StudyActivityControls: View {
    let state: StudyActivityAttributes.ContentState
    var compact: Bool = false

    var body: some View {
        // L'îlot n'a pas la place de tout : l'enregistrement reste sur l'écran
        // verrouillé, où il y a de quoi aligner trois commandes. Ne garder ici que
        // ce qui se fait pendant la session — cocher, mettre en pause.
        HStack(spacing: 10) {
            if !compact {
                Button(intent: FinishFocusTimerIntent()) {
                    Image(systemName: "stop.fill")
                }
                .tint(.red)
                .accessibilityLabel("Enregistrer la session")
            }

            // « Question suivante » : le geste réel d'une série. Il n'apparaît que
            // s'il reste une case à cocher — un bouton qui ne fait rien est pire
            // qu'un bouton absent. Avec le compte à côté, on sait ce qu'il coche.
            if state.hasNextQuestion {
                Button(intent: NextQuestionIntent()) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                        if let label = state.questionsLabel {
                            Text(label).monospacedDigit()
                        }
                    }
                }
                .tint(.blue)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Cocher la question suivante")
                .accessibilityValue(state.questionsLabel ?? "")
            }

            if state.isRunning {
                Button(intent: PauseFocusTimerIntent()) {
                    Image(systemName: "pause.fill")
                }
                .tint(.indigo)
                .accessibilityLabel("Mettre en pause")
            } else {
                Button(intent: ResumeFocusTimerIntent()) {
                    Image(systemName: "play.fill")
                }
                .tint(.green)
                .accessibilityLabel("Reprendre")
            }
        }
        .font(compact ? .caption2.weight(.bold) : .footnote.weight(.bold))
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(compact ? .mini : .small)
    }
}

/// Pastille d'état : le chrono tourne-t-il, ou est-il en pause ?
///
/// Sans elle, rien ne distinguait une session en cours d'une session suspendue :
/// le compteur affichait la même chose dans les deux cas.
struct StudyActivityState: View {
    let state: StudyActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.isRunning ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(state.isRunning ? "en cours" : "en pause")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.isRunning ? "Chrono en cours" : "Chrono en pause")
    }
}

/// Vue de l'écran verrouillé et de la bannière.
///
/// Trois informations, dans l'ordre où on les cherche : combien de temps, sur
/// quoi, et de quoi il s'agit. Les commandes sont à droite, assez grandes pour
/// être touchées sans regarder.
struct StudyActivityLockView: View {
    let context: ActivityViewContext<StudyActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // L'anneau du bloc, quand la session est en Pomodoro : ici la place ne
            // manque pas, il accompagne le reste au lieu de le remplacer.
            if let pomodoro = context.state.pomodoro {
                VStack(spacing: 2) {
                    StudyActivityPomodoroRing(pomodoro: pomodoro,
                                              isRunning: context.state.isRunning)
                    Text(pomodoro.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(context.state.isRunning ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(context.attributes.courseCode)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    Text(StudyActivitySubtitle.text(for: context.attributes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                StudyActivityTimer(state: context.state, font: .title2)

                // Les sous-questions : la barre dit l'avancement d'un coup d'œil,
                // le compte dit exactement où on en est. Rien ne s'affiche quand la
                // cible n'a pas de sous-questions.
                if let label = context.state.questionsLabel,
                   let progress = context.state.questionsProgress {
                    HStack(spacing: 6) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                            .frame(width: 64)
                        Text(label)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Sous-questions faites : \(label)")
                }
            }

            Spacer(minLength: 8)

            StudyActivityControls(state: context.state)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Le compteur : vivant tant que la session tourne, figé en pause.
///
/// `showsHours: false` en forme compacte : à partir d'une heure, le compteur
/// système écrirait « 1:10:48 » et élargirait l'îlot. « 70:48 » tient dans la
/// largeur d'origine, et reste juste.
struct StudyActivityTimer: View {
    let state: StudyActivityAttributes.ContentState
    var font: Font
    /// Vrai dans l'îlot replié, où la place est comptée.
    var compact: Bool = false

    var body: some View {
        Group {
            if let since = state.countingSince {
                // Le système fait avancer ce texte tout seul, à partir de l'instant
                // reculé du total déjà écoulé : la reprise ne repart donc pas de zéro.
                //
                // La fin de l'intervalle est **bornée**, et c'est important : SwiftUI
                // réserve la largeur du plus grand texte possible dans l'intervalle.
                // Avec `Date.distantFuture`, il réservait la place d'un nombre
                // d'heures démesuré — d'où une région repliée très large. Une
                // journée est déjà plus qu'une session d'étude.
                Text(timerInterval: since...Self.horizon(from: since),
                     countsDown: false,
                     showsHours: !compact)
            } else {
                Text(Self.frozen(state.frozenTotal, compact: compact))
            }
        }
        .font(font.monospacedDigit().weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// La borne haute de l'intervalle du chrono : une journée.
    ///
    /// Elle n'est pas là pour arrêter le temps — le système continue d'avancer —
    /// mais pour dire à SwiftUI jusqu'où le texte peut grandir, donc quelle largeur
    /// réserver.
    static func horizon(from start: Date) -> Date {
        start.addingTimeInterval(24 * 3600)
    }

    private static func frozen(_ seconds: TimeInterval, compact: Bool) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0, !compact {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", hours * 60 + minutes, secs)
    }
}

// MARK: - Live Activity : le jour d'examen

/// L'examen du jour, sur l'écran verrouillé et dans l'îlot.
///
/// Aucune commande : il n'y a rien à faire sur un examen, seulement à savoir quand
/// et où. Le compte à rebours est un `Text(timerInterval:)` qui descend, donc le
/// système l'anime seul — l'app ne publie qu'aux changements de phase.
struct ExamActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ExamActivityAttributes.self) { context in
            ExamActivityLockView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.courseCode, systemImage: "graduationcap.fill")
                        .font(.caption.weight(.bold))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExamActivityCountdown(attributes: context.attributes,
                                          state: context.state,
                                          font: .title3)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Text(context.attributes.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if let room = context.attributes.room {
                            Text("· \(room)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(context.attributes.examDate, style: .time)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                    }
                }
            } compactLeading: {
                Image(systemName: "graduationcap.fill")
                    .foregroundStyle(.orange)
            } compactTrailing: {
                ExamActivityCountdown(attributes: context.attributes,
                                      state: context.state,
                                      font: .caption2)
            } minimal: {
                Image(systemName: "graduationcap.fill")
                    .foregroundStyle(.orange)
            }
            .keylineTint(.orange)
        }
    }
}

/// Le temps qui reste avant l'épreuve — ou le fait qu'elle a commencé.
struct ExamActivityCountdown: View {
    let attributes: ExamActivityAttributes
    let state: ExamActivityState
    var font: Font

    var body: some View {
        Group {
            switch state.phase {
            case .upcoming:
                // Borné en amont : SwiftUI réserve la largeur du plus grand texte
                // de l'intervalle, et une borne trop lointaine réserverait la place
                // d'un nombre d'heures démesuré.
                Text(timerInterval: Date()...attributes.examDate, countsDown: true)
            case .running:
                Text("en cours")
            case .over:
                Text("terminé")
            }
        }
        .font(font.monospacedDigit().weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// Écran verrouillé : quand, quoi, où. Rien d'autre.
struct ExamActivityLockView: View {
    let context: ActivityViewContext<ExamActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "graduationcap.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(context.attributes.courseCode)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    Text(context.attributes.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ExamActivityCountdown(attributes: context.attributes,
                                      state: context.state,
                                      font: .title2)
                HStack(spacing: 6) {
                    Text(context.attributes.examDate,
                         format: .dateTime.weekday(.abbreviated).hour().minute())
                        .font(.caption2)
                    if let room = context.attributes.room {
                        Text("· \(room)")
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

@main
struct StudyTrackWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NextActionWidget()
        WeekCoursesWidget()
        ExamCountdownWidget()
        StudyTrackWidget()
        StudyTrackTimerWidget()
        StudyActivityWidget()
        ExamActivityWidget()
        if #available(iOS 18.0, *) {
            FocusControl()
        }
    }
}

// MARK: - Vues

struct StudyTrackWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StudyTrackEntry

    // Tailles conservées, mais elles suivent la taille de texte du lecteur.
    @ScaledMetric(relativeTo: .largeTitle) private var heroSmall: CGFloat = 30
    @ScaledMetric(relativeTo: .title) private var heroMedium: CGFloat = 26
    @ScaledMetric(relativeTo: .title2) private var heroLarge: CGFloat = 22

    var body: some View {
        if let snapshot = entry.snapshot, snapshot.hasContent {
            switch family {
            case .systemSmall: small(snapshot)
            case .systemLarge: large(snapshot)
            default: medium(snapshot)
            }
        } else {
            emptyState
        }
    }

    // MARK: Vide

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "timer")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Ouvre StudyTrack")
                .font(.caption.weight(.semibold))
            Text("Tes données apparaîtront ici.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Small

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(snapshot)
            Spacer(minLength: 0)
            Text(WidgetFormat.hours(snapshot.weekSeconds))
                .font(.system(size: heroSmall, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text("cette semaine")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            footer(snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: Medium

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                header(snapshot)
                Spacer(minLength: 0)
                Text(WidgetFormat.hours(snapshot.weekSeconds))
                    .font(.system(size: heroMedium, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("cette semaine")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                footer(snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            todoList(snapshot, limit: 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Large

    private func large(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                header(snapshot)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(WidgetFormat.hours(snapshot.weekSeconds))
                        .font(.system(size: heroLarge, weight: .bold, design: .rounded))
                    Text("cette semaine")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            todoList(snapshot, limit: 5)

            if let title = snapshot.nextExamTitle, let date = snapshot.nextExamDate {
                Spacer(minLength: 0)
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "graduationcap.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.orange.widgetInk)
                    Text([snapshot.nextExamCourse, title].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(WidgetFormat.countdown(to: date))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.orange.widgetInk)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Fragments

    private func header(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.caption2)
                .foregroundStyle(.tint)
            Text("StudyTrack")
                .font(.caption.weight(.bold))
            Spacer(minLength: 4)
            if snapshot.streak > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill").font(.caption2)
                    Text("\(snapshot.streak)").font(.caption2.weight(.bold))
                }
                .foregroundStyle(Color.orange.widgetInk)
            }
        }
    }

    private func footer(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 4) {
            Image(systemName: snapshot.todoCount == 0 ? "checkmark.circle.fill" : "list.bullet")
                .font(.caption2)
            Text(snapshot.todoCount == 0 ? "À jour" : "\(snapshot.todoCount) à faire")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(snapshot.todoCount == 0 ? Color.green.widgetInk : Color.secondary)
    }

    private func todoList(_ snapshot: WidgetSnapshot, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if snapshot.todos.isEmpty {
                Text("Rien à faire cette semaine.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.todos.prefix(limit)) { todo in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color(hexString: todo.colorHex))
                            .frame(width: 3, height: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(todo.courseCode)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color(hexString: todo.colorHex).widgetInk)
                            Text(todo.title)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if snapshot.todoCount > limit {
                    Text("+ \(snapshot.todoCount - limit) autres")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Widget compact centré sur le temps de travail.
struct StudyTrackTimerWidgetView: View {
    let entry: StudyTrackEntry

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 32

    var body: some View {
        if let snapshot = entry.snapshot, snapshot.hasContent {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "clock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                    Text("7 derniers jours")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Text(WidgetFormat.hours(snapshot.weekSeconds))
                    .font(.system(size: heroSize, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    if snapshot.streak > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "flame.fill").font(.caption2)
                            Text("\(snapshot.streak) j").font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(Color.orange.widgetInk)
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").font(.caption2)
                        Text("Niv. \(snapshot.level)").font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(Color.yellow.widgetInk)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Ouvre StudyTrack")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Aides locales (le widget ne dépend pas des types de l'app)

extension Color {
    /// Encre lisible pour du texte de cette teinte, sur le fond du widget.
    ///
    /// L'extension ne peut pas importer la couche `Palette` de l'app : elle
    /// utilise le solveur partagé et sa propre surface de référence.
    var widgetInk: Color {
        Color(uiColor: UIColor { traits in
            let style = traits.userInterfaceStyle
            let tc = UITraitCollection(userInterfaceStyle: style)
            let hue = UIColor(self).resolvedColor(with: tc).contrastRGB
            let surface = ContrastSurface.widgetRGB(for: style)
            return ColorContrast.accessibleVariant(of: hue,
                                                   against: surface,
                                                   target: ColorContrast.textTarget).uiColor
        })
    }
}

extension Color {
    /// Équivalent local de `Color(hex:)` de l'app.
    init(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        if cleaned.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        } else {
            r = 0.4; g = 0.35; b = 0.9
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
