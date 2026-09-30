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
        let now = Date()
        let snapshot = WidgetBridge.read()
        var entries = [StudyTrackEntry(date: now, snapshot: snapshot)]
        // Une seconde entrée à minuit : « Demain » devient « Aujourd'hui », « J-3 »
        // devient « J-2 » à l'heure juste, sans attendre un rechargement que le
        // système peut repousser.
        let calendar = Calendar.current
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            entries.append(StudyTrackEntry(date: midnight, snapshot: snapshot))
        }
        // Une pause Pomodoro qui finit : le widget quitte le compte à rebours à
        // l'instant exact, au lieu de rester sur « 0:00 ».
        if let breakEnd = snapshot?.timer?.breakEndsAt, breakEnd > now {
            entries.append(StudyTrackEntry(date: breakEnd, snapshot: snapshot))
            entries.sort { $0.date < $1.date }
        }
        // L'app recharge explicitement les timelines ; ce rafraîchissement périodique
        // n'est qu'un filet de sécurité.
        let next = calendar.date(byAdding: .minute, value: 30, to: now)
            ?? now.addingTimeInterval(1800)
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}

// MARK: - Live Activity : le chrono en cours

/// Chrono en cours, sur l'écran verrouillé et dans l'îlot dynamique.
///
/// « Carnet de verre » : de l'encre sur un papier sombre, la couleur du cours en
/// liseré et dans l'anneau, le temps en serif. Le compteur s'appuie sur
/// `Text(timerInterval:)` : c'est le **système** qui le fait avancer.
///
/// **Forme compacte** : un point (ou l'anneau du bloc) à la couleur du cours,
/// et le temps. Le reste vit dans la forme dépliée.
struct StudyActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StudyActivityAttributes.self) { context in
            StudyActivityLockView(context: context)
                .activityBackgroundTint(Paper.night.opacity(0.92))
                .activitySystemActionForegroundColor(Paper.cream)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        StudyActivityLeading(state: context.state)
                        Text(StudyActivityTitle.course(context))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StudyActivityTint.color(context.state))
                            .lineLimit(1)
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StudyActivityTimer(state: context.state,
                                       font: .system(.title2, design: .serif), compact: false)
                        .foregroundStyle(Paper.cream)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(StudyActivitySubtitle.text(context))
                            .font(.system(.body, design: .serif))
                            .foregroundStyle(Paper.cream)
                            .lineLimit(1)
                        HStack(spacing: 10) {
                            StudyActivityProgressLine(state: context.state)
                            Spacer(minLength: 4)
                            StudyActivityControls(state: context.state, compact: true)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                StudyActivityLeading(state: context.state, tiny: true)
            } compactTrailing: {
                StudyActivityTimer(state: context.state, font: .caption2, compact: true)
                    .foregroundStyle(StudyActivityTint.color(context.state))
            } minimal: {
                StudyActivityLeading(state: context.state, tiny: true)
            }
            .keylineTint(StudyActivityTint.color(context.state))
        }
    }
}

/// Le papier et l'encre du widget : l'extension ne voit pas `Carnet`.
enum Paper {
    static let cream = Color(hexString: "#EDE6D6")
    static let creamSecondary = Color(hexString: "#A89F8D")
    static let night = Color(hexString: "#1A1712")
    static let ruleNight = Color(hexString: "#3A342A")
    static let ground = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(Color(hexString: "#211E18")) : UIColor(Color(hexString: "#FFFDF8")) })
    static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(Color(hexString: "#EDE6D6")) : UIColor(Color(hexString: "#1D1B16")) })
    static let inkSecondary = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(Color(hexString: "#A89F8D")) : UIColor(Color(hexString: "#6B655A")) })
    static let rule = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(Color(hexString: "#353027")) : UIColor(Color(hexString: "#E6DFD0")) })
    static let wrong = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(Color(hexString: "#E7836F")) : UIColor(Color(hexString: "#A33A2A")) })
    static let correct = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(Color(hexString: "#8FC58A")) : UIColor(Color(hexString: "#3F7A3F")) })

    /// La couleur d'un cours adoucie pour le papier, comme `Carnet.tint`.
    static func tint(_ hex: String) -> Color {
        let base = UIColor(Color(hexString: hex))
        return Color(uiColor: UIColor { traits in
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            if traits.userInterfaceStyle == .dark {
                return UIColor(hue: h, saturation: min(s, 0.45), brightness: max(b, 0.82), alpha: 1)
            }
            return UIColor(hue: h, saturation: min(s * 0.62, 0.62), brightness: min(b * 0.74, 0.62), alpha: 1)
        })
    }

    /// Sur le papier sombre de l'activité : la teinte de nuit, quel que soit le
    /// réglage du téléphone.
    static func nightTint(_ hex: String) -> Color {
        let base = UIColor(Color(hexString: hex))
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(s, 0.45), brightness: max(b, 0.85))
    }
}

/// La couleur de la session : le cours, turquoise en pause Pomodoro, ambre
/// quand le chrono est arrêté.
enum StudyActivityTint {
    static func color(_ state: StudyActivityAttributes.ContentState) -> Color {
        if state.pomodoro?.isOnBreak == true { return Color(hexString: "#7CC7C0") }
        if !state.isRunning { return Color(hexString: "#E0B04E") }
        return state.colorHex.map(Paper.nightTint) ?? Paper.cream
    }
}

/// Ce qui occupe la gauche de l'îlot : l'anneau du bloc, sinon un point.
struct StudyActivityLeading: View {
    let state: StudyActivityAttributes.ContentState
    var tiny: Bool = false

    var body: some View {
        if let pomodoro = state.pomodoro {
            StudyActivityPomodoroRing(pomodoro: pomodoro,
                                      isRunning: state.isRunning,
                                      tint: StudyActivityTint.color(state),
                                      tiny: tiny)
        } else {
            ZStack {
                Circle().fill(StudyActivityTint.color(state).opacity(0.22))
                if state.isRunning {
                    Circle().fill(StudyActivityTint.color(state))
                        .padding(tiny ? 4 : 7)
                } else {
                    Image(systemName: "pause.fill")
                        .font(.system(size: tiny ? 7 : 10, weight: .bold))
                        .foregroundStyle(StudyActivityTint.color(state))
                }
            }
            .frame(width: tiny ? 16 : 26, height: tiny ? 16 : 26)
            .accessibilityLabel(state.isRunning ? "Chrono en cours" : "Chrono en pause")
        }
    }
}

/// L'anneau du bloc Pomodoro, rempli par le **système** (`ProgressView(timerInterval:)`).
///
/// En pause, et sur un bloc arrivé à terme, l'anneau est dessiné **figé** à la
/// fraction déjà faite : un anneau qui avancerait pendant une pause mentirait.
struct StudyActivityPomodoroRing: View {
    let pomodoro: ActivityPomodoro
    let isRunning: Bool
    var tint: Color
    var tiny: Bool = false

    var body: some View {
        Group {
            if let breakInterval = pomodoro.breakInterval, Date() < breakInterval.upperBound {
                ProgressView(timerInterval: breakInterval, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.circular)
            } else if let interval = pomodoro.interval {
                ProgressView(timerInterval: interval, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.circular)
            } else {
                ProgressView(value: pomodoro.frozenProgress)
                    .progressViewStyle(.circular)
            }
        }
        .tint(tint)
        .frame(width: tiny ? 18 : 28, height: tiny ? 18 : 28)
        .accessibilityLabel("\(pomodoro.label), \(Int(pomodoro.frozenProgress * 100)) %")
    }
}

/// « CS-250 » — le cours, lu dans l'**état** (les attributs sont figés à la
/// création de l'activité, reprise de session en session).
enum StudyActivityTitle {
    static func course(_ context: ActivityViewContext<StudyActivityAttributes>) -> String {
        context.state.title ?? context.attributes.courseCode
    }

    static func text(_ context: ActivityViewContext<StudyActivityAttributes>) -> String {
        [course(context), StudyActivitySubtitle.text(context)].joined(separator: " · ")
    }
}

/// « Exercices · 3.2 ».
enum StudyActivitySubtitle {
    static func text(_ context: ActivityViewContext<StudyActivityAttributes>) -> String {
        if let subtitle = context.state.subtitle { return subtitle }
        var parts = [context.attributes.taskLabel]
        if let target = context.attributes.target, !target.isEmpty { parts.append(target) }
        return parts.joined(separator: " · ")
    }
}

/// Sous la ligne du titre : les sous-questions (barre et compte), ou le bloc
/// Pomodoro. Rien quand il n'y a ni l'un ni l'autre.
struct StudyActivityProgressLine: View {
    let state: StudyActivityAttributes.ContentState

    var body: some View {
        if let pomodoro = state.pomodoro {
            Text(pomodoro.isOnBreak ? pomodoro.breakLabel : "Bloc \(pomodoro.blockNumber) · \(pomodoro.completedBlocks) fait\(pomodoro.completedBlocks > 1 ? "s" : "")")
                .font(.caption.weight(.medium))
                .foregroundStyle(Paper.creamSecondary)
                .lineLimit(1)
        } else if let label = state.questionsLabel, let progress = state.questionsProgress {
            HStack(spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Paper.ruleNight)
                        Capsule().fill(StudyActivityTint.color(state))
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(width: 72, height: 4)
                Text("\(label) questions")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(Paper.creamSecondary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sous-questions faites : \(label)")
        } else {
            Text(state.isRunning ? "en cours" : "en pause")
                .font(.caption.weight(.medium))
                .foregroundStyle(Paper.creamSecondary)
        }
    }
}

/// Les boutons du chrono : des ronds crème sur le papier sombre.
///
/// Des `LiveActivityIntent`, exécutés dans le processus de l'app : mettre en
/// pause ou enregistrer depuis l'écran verrouillé n'ouvre pas l'app.
struct StudyActivityControls: View {
    let state: StudyActivityAttributes.ContentState
    var compact: Bool = false

    private var size: CGFloat { compact ? 34 : 42 }

    var body: some View {
        HStack(spacing: 8) {
            if state.pomodoro?.isOnBreak == true {
                Button(intent: SkipBreakIntent()) {
                    circle("forward.fill", filled: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Terminer la pause et reprendre le travail")
            } else {
                if state.hasNextQuestion {
                    Button(intent: NextQuestionIntent()) {
                        circle("checkmark", filled: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cocher la question suivante")
                    .accessibilityValue(state.questionsLabel ?? "")
                }
                if state.isRunning {
                    Button(intent: PauseFocusTimerIntent()) {
                        circle("pause.fill", filled: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mettre en pause")
                } else {
                    Button(intent: ResumeFocusTimerIntent()) {
                        circle("play.fill", filled: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reprendre")
                }
            }
            if !compact {
                Button(intent: FinishFocusTimerIntent()) {
                    circle("stop.fill", filled: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Enregistrer la session")
            }
        }
    }

    private func circle(_ icon: String, filled: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.36, weight: .bold))
            .foregroundStyle(filled ? Paper.night : Paper.cream)
            .frame(width: size, height: size)
            .background(filled ? Paper.cream : Paper.ruleNight, in: Circle())
    }
}

/// L'écran verrouillé : le cours et ce qu'on y fait, le temps en grand, la
/// progression, et les commandes à droite.
struct StudyActivityLockView: View {
    let context: ActivityViewContext<StudyActivityAttributes>

    var body: some View {
        let tint = StudyActivityTint.color(context.state)
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint)
                .frame(width: 4)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(StudyActivityTitle.course(context).uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(1)
                        .foregroundStyle(tint)
                    Text(StudyActivitySubtitle.text(context))
                        .font(.system(.footnote, design: .serif))
                        .foregroundStyle(Paper.cream)
                        .lineLimit(1)
                }
                StudyActivityTimer(state: context.state, font: .system(.largeTitle, design: .serif))
                    .foregroundStyle(Paper.cream)
                StudyActivityProgressLine(state: context.state)
            }
            Spacer(minLength: 6)
            StudyActivityControls(state: context.state)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}


/// Le compteur : vivant tant que la session tourne, figé en pause.
///
/// **La largeur de l'îlot replié se décide ici.** `Text(timerInterval:)` ne
/// mesure pas ce qu'il affiche : il réserve la place du **plus grand texte que
/// l'intervalle puisse produire**. Un îlot resté large alors qu'il affiche
/// « 1:20 » vient toujours de là.
///
/// Borner l'intervalle ne suffisait pas — cela ne fait que choisir *lequel* des
/// textes démesurés sera le plus large. Sur une journée et en `MM:SS`
/// (`showsHours: false`), le pire cas est « 1440:00 » : sept caractères réservés
/// en permanence pour en afficher quatre.
///
/// La forme repliée impose donc une **largeur fixe**, calculée pour « 59:59 » et
/// suivant la taille de texte du lecteur. Le compteur n'y décide plus rien : au
/// delà de cent minutes, c'est le texte qui se condense (`minimumScaleFactor`),
/// pas l'îlot qui s'élargit.
struct StudyActivityTimer: View {
    let state: StudyActivityAttributes.ContentState
    var font: Font
    /// Vrai dans l'îlot replié, où la place est comptée.
    var compact: Bool = false

    /// Place de « 59:59 » en chiffres à chasse fixe, à la taille du lecteur.
    @ScaledMetric(relativeTo: .caption2) private var compactWidth: CGFloat = 38

    var body: some View {
        Group {
            if let breakEnd = state.pomodoro?.breakEndsAt {
                // La pause décompte ; passé son terme, elle attend l'app.
                let now = Date()
                if now < breakEnd {
                    Text(timerInterval: now...breakEnd, countsDown: true, showsHours: false)
                        .foregroundStyle(.teal)
                } else {
                    Text("0:00").foregroundStyle(.teal)
                }
            } else if let since = state.countingSince {
                // Le système fait avancer ce texte tout seul, à partir de l'instant
                // reculé du total déjà écoulé : la reprise ne repart donc pas de zéro.
                //
                // L'intervalle reste borné à une journée, mais pour une autre
                // raison que la largeur : passé sa fin, le compteur s'arrêterait.
                // Une journée est déjà plus qu'une session d'étude.
                Text(timerInterval: since...Self.horizon(from: since),
                     countsDown: false,
                     showsHours: !compact)
            } else {
                Text(Self.frozen(state.frozenTotal, compact: compact))
            }
        }
        .font(font.monospacedDigit().weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        // `nil` hors de la forme repliée : l'écran verrouillé a la place, et une
        // largeur imposée y tronquerait un compteur à heures.
        .frame(width: compact ? compactWidth : nil, alignment: .trailing)
    }

    /// La borne haute de l'intervalle du chrono : une journée.
    ///
    /// Elle borne le **temps**, pas la largeur — le compteur cesserait d'avancer
    /// après elle. La largeur, elle, est imposée par `compactWidth`.
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
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } compactTrailing: {
                ExamActivityCountdown(attributes: context.attributes,
                                      state: context.state,
                                      font: .caption2,
                                      compact: true)
            } minimal: {
                Image(systemName: "graduationcap.fill")
                    .foregroundStyle(.orange)
            }
            .keylineTint(.orange)
        }
    }
}

/// Le temps qui reste avant l'épreuve — ou le fait qu'elle a commencé.
///
/// Même piège que le chrono : le compte à rebours s'ouvre jusqu'à douze heures
/// avant l'épreuve, donc `Text(timerInterval:)` réserverait la place de
/// « 12:00:00 » — huit caractères — dans une région repliée qui en affiche
/// quatre. La forme repliée impose donc sa largeur.
struct ExamActivityCountdown: View {
    let attributes: ExamActivityAttributes
    let state: ExamActivityState
    var font: Font
    /// Vrai dans l'îlot replié, où la place est comptée.
    var compact: Bool = false

    /// Place de « 9:59:59 » en chiffres à chasse fixe, à la taille du lecteur.
    @ScaledMetric(relativeTo: .caption2) private var compactWidth: CGFloat = 50

    var body: some View {
        Group {
            switch state.phase {
            case .upcoming:
                // La phase n'est recalculée que quand l'app tourne : passé
                // l'heure de l'épreuve, elle peut encore dire « à venir ».
                // `Date()...examDate` serait alors un intervalle inversé, et le
                // rendu planterait — l'activité s'afficherait vide.
                let now = Date()
                if now < attributes.examDate {
                    Text(timerInterval: now...attributes.examDate, countsDown: true)
                } else {
                    Text("en cours")
                }
            case .running:
                Text("en cours")
            case .over:
                Text("terminé")
            }
        }
        .font(font.monospacedDigit().weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .frame(width: compact ? compactWidth : nil, alignment: .trailing)
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
        WeekCoursesWidget()
        TodayScheduleWidget()
        StudyActivityWidget()
        ExamActivityWidget()
        if #available(iOS 18.0, *) {
            FocusControl()
            FocusPauseControl()
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
