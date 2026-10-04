import SwiftUI
import SwiftData

/// Le vocabulaire visuel du Mac : l'anneau du chrono, les boutons ronds, les
/// lignes qui réagissent au survol, les cartes. Un seul endroit, pour que la
/// barre des menus, la fenêtre et le chrono flottant parlent la même langue.
enum MacStyle {
    /// Les chiffres du chrono : arrondis, fins, à chasse fixe.
    static func clock(_ size: CGFloat, weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    /// Les titres de page : le serif de l'iPhone.
    static func title(_ size: CGFloat = 26) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }

    static let breakTint = Color.green
    /// L'objectif du jour, et une session sans cours.
    static let goalTint = Color.orange
    static let freeTint = Color.indigo
    static let cardRadius: CGFloat = 12
}

// MARK: - Anneau

/// Un anneau qui se remplit : le bloc, la pause, l'objectif du jour.
struct TimerRing: View {
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat = 8
    /// Une pause se vide au lieu de se remplir.
    var draining = false

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, draining ? 1 - progress : progress)))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.95), value: progress)
        }
        .padding(lineWidth / 2)
    }
}

/// Les blocs Pomodoro du cycle : pleins quand ils sont faits.
struct PomodoroDots: View {
    var completed: Int
    var every: Int
    var tint: Color

    var body: some View {
        let cycle = max(2, every)
        let inCycle = completed % cycle
        HStack(spacing: 5) {
            ForEach(0..<cycle, id: \.self) { index in
                Circle()
                    .fill(index < inCycle ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.2)))
                    .frame(width: 6, height: 6)
            }
        }
        .help("\(completed) bloc\(completed > 1 ? "s" : "") terminé\(completed > 1 ? "s" : "")")
    }
}

// MARK: - Boutons

/// Un bouton rond : plein pour le geste principal, discret sinon.
struct RoundButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    var prominent = false
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        RoundButtonBody(configuration: configuration, size: size, prominent: prominent, tint: tint)
    }

    private struct RoundButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let prominent: Bool
        let tint: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: size, height: size)
                .background {
                    Circle().fill(prominent ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.12 : 0.07)))
                }
                .overlay {
                    if prominent && hovering { Circle().fill(.white.opacity(0.1)) }
                }
                .shadow(color: prominent ? tint.opacity(0.35) : .clear, radius: hovering ? 8 : 4, y: 2)
                .scaleEffect(configuration.isPressed ? 0.93 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(.spring(duration: 0.18, bounce: 0.2), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Une ligne de liste qui s'éclaire au survol (hors `List`).
struct HoverRow: ViewModifier {
    var radius: CGFloat = 7
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// Une carte : un fond à peine détaché, un liseré.
struct MacCard: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: MacStyle.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MacStyle.cardRadius, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

extension View {
    func hoverRow(radius: CGFloat = 7) -> some View { modifier(HoverRow(radius: radius)) }
    func macCard(padding: CGFloat = 16) -> some View { modifier(MacCard(padding: padding)) }
}

/// Un titre de section, à la manière de Notes ou Rappels.
struct SectionTitle: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            if let trailing {
                Text(trailing).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Cibles

/// Ce que désigne une cible du chrono : un exercice, un élément de théorie.
enum MacTargets {
    /// « Série 3 · Ex 2 », « Théorie 4.2 » — le nom court d'une cible.
    static func label(_ targetID: UUID?, in course: Course?) -> String? {
        guard let targetID, let course else { return nil }
        if let exercise = course.allExercises.first(where: { $0.id == targetID }) {
            return exercise.displayNumber
        }
        if let item = course.theoryItems.first(where: { $0.id == targetID }) {
            return item.title.isEmpty ? (item.number.isEmpty ? item.kind.label : "Théorie \(item.number)") : item.title
        }
        return nil
    }

    /// Ce qu'on travaille, en une ligne : la cible, sinon le travail.
    static func headline(course: Course?, taskType: TaskType, targetID: UUID?) -> String {
        label(targetID, in: course) ?? (course == nil ? "Session libre" : taskType.label)
    }

    static func tint(_ course: Course?) -> Color {
        course.map { Color(hex: $0.colorHex) } ?? MacStyle.freeTint
    }
}
