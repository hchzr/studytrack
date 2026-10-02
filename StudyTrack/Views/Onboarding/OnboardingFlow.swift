import SwiftUI
import EventKit

/// L'accueil par la connexion EPFL, en quatre temps :
///
///   1. **Bienvenue** — la promesse, et un seul bouton ;
///   2. **Ton semestre se construit** — l'import *est* la visite : un anneau
///      donne l'avancement réel et le temps restant, la grille du semestre se
///      remplit cours par cours, et des cartes présentent l'app avec **ses**
///      cours à mesure qu'ils arrivent ;
///   3. **Relie le reste** — to-do, calendrier, groupes, Anki, chacun d'un toucher ;
///   4. **C'est prêt** — le semestre entier, d'un coup d'œil.
///
/// L'attente d'un import (une à trois minutes) était un écran de chargement :
/// elle devient le moment où l'on découvre l'app, sur ses propres données.
struct OnboardingFlow: View {
    @Bindable var setup: OnboardingAutoSetup
    /// Lance l'import (une fois Moodle connecté).
    var start: () -> Void
    /// Le parcours sans Moodle (section et cours à la main).
    var goManual: () -> Void
    var finish: () -> Void

    enum Screen: Int { case welcome, importing, connections, finale }

    @State private var screen: Screen = .welcome
    @State private var showingLogin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Le fond en `.background` : il prend la taille de l'écran sans jamais
        // l'imposer. Dans un `ZStack`, ses disques de 460 pt élargissaient la
        // vue, et tout le contenu débordait à gauche.
        ZStack {
            Group {
                switch screen {
                case .welcome:
                    WelcomeScreen(connect: { showingLogin = true }, goManual: goManual)
                case .importing:
                    ImportScreen(setup: setup, retry: { showingLogin = true }, goManual: goManual) {
                        advance(to: .connections)
                    }
                case .connections:
                    ConnectionsScreen(setup: setup) { advance(to: .finale) }
                case .finale:
                    FinaleScreen(setup: setup, finish: finish)
                }
            }
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .offset(x: 40).combined(with: .opacity),
                removal: .offset(x: -40).combined(with: .opacity)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { PaperAtmosphere(colors: setup.grid.map { Carnet.tint($0.colorHex) }) }
        #if DEBUG
        .task {
            guard let demo = PreviewLaunch.int(PreviewLaunch.onboardingDemoFlag), demo > 0 else { return }
            screen = .importing
            await setup.runDemo(fast: demo > 1)
            if demo >= 2 { screen = .connections }
            if demo >= 3 { screen = .finale }
        }
        #endif
        .sheet(isPresented: $showingLogin, onDismiss: {
            // Connexion faite (ou abandonnée) : l'import dit lui-même ce qu'il en est.
            if !setup.isWorking, setup.phase != .done {
                advance(to: .importing)
                start()
            }
        }) {
            ConnectionSheetContent(sheet: .moodle)
        }
    }

    private func advance(to next: Screen) {
        Haptics.tap()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.5)) { screen = next }
    }
}

// MARK: - Atmosphère

/// Le papier, éclairé : deux lueurs très douces qui dérivent lentement, aux
/// couleurs des cours dès qu'on les connaît. Rien qui se remarque — de la
/// profondeur.
private struct PaperAtmosphere: View {
    var colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let first = colors.first ?? Carnet.review
            let second = colors.dropFirst().first ?? Carnet.correct
            // Des disques flous plutôt que des dégradés radiaux : un dégradé
            // décalé laisse voir le bord de son cadre (une arête verticale nette
            // traversait l'écran) ; un disque flou n'a pas de bord.
            Carnet.ground.overlay {
                Circle().fill(first.opacity(0.22))
                    .frame(width: 420, height: 420)
                    .blur(radius: 110)
                    .offset(x: -110 + 40 * sin(t * 0.12), y: -280 + 30 * cos(t * 0.1))
                Circle().fill(second.opacity(0.16))
                    .frame(width: 460, height: 460)
                    .blur(radius: 120)
                    .offset(x: 140 + 40 * cos(t * 0.09), y: 320 + 40 * sin(t * 0.11))
            }
            .clipped()
            .animation(.smooth(duration: 1.2), value: colors.count)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - 1. Bienvenue

private struct WelcomeScreen: View {
    var connect: () -> Void
    var goManual: () -> Void

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            LivingGrid()
                .frame(maxWidth: .infinity)
                .frame(height: 210)
                .padding(.horizontal, -4)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.94)
                .animation(.smooth(duration: 0.9), value: appeared)
            Spacer(minLength: 28).frame(maxHeight: 56)

            VStack(alignment: .leading, spacing: 14) {
                Text("StudyTrack")
                    .font(Carnet.serif(.largeTitle, weight: .semibold))
                    .foregroundStyle(Carnet.ink)
                    .rise(appeared, delay: 0.25)
                Text("Ton semestre EPFL, semaine par semaine : la théorie, les séries, et le temps que tu y passes vraiment.")
                    .font(.title3)
                    .foregroundStyle(Carnet.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .rise(appeared, delay: 0.33)
                HStack(spacing: 18) {
                    promise("graduationcap", "Tes cours, lus sur Moodle")
                    promise("sparkles", "Rangés pour toi")
                }
                .padding(.top, 4)
                .rise(appeared, delay: 0.41)
            }
            Spacer(minLength: 32)

            VStack(spacing: 14) {
                Button(action: connect) {
                    Label("Se connecter avec EPFL", systemImage: "person.badge.key.fill")
                }
                .buttonStyle(.carnetPrimaryWide)
                .sensoryFeedback(.impact(weight: .light), trigger: appeared)
                Text("Sur la vraie page de l'EPFL. Ton mot de passe ne passe jamais par l'app.")
                    .font(.caption)
                    .foregroundStyle(Carnet.inkTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Button("Je n'utilise pas Moodle", action: goManual)
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
                    .frame(minHeight: 44)
            }
            .rise(appeared, delay: 0.52)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: Layout.readableWidth)
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true }
    }

    private func promise(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Carnet.inkSecondary)
    }
}

/// La grille d'un semestre qui vit : 14 semaines × 5 cours, qui se dessinent
/// en vague puis se remplissent et se vident doucement, comme un semestre qui
/// avance. C'est l'image de l'app — et celle qu'on retrouvera, remplie de ses
/// propres cours, pendant l'import.
private struct LivingGrid: View {
    private static let palette = ["#4F46E5", "#0891B2", "#059669", "#D97706", "#DB2777"]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSince(start)
            Canvas { canvas, size in
                let columns = 14, rows = 5
                let gap: CGFloat = 5
                let cell = min((size.width - gap * CGFloat(columns - 1)) / CGFloat(columns),
                               (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows))
                let width = cell * CGFloat(columns) + gap * CGFloat(columns - 1)
                let originX = (size.width - width) / 2
                for row in 0..<rows {
                    let tint = Carnet.tint(Self.palette[row])
                    for column in 0..<columns {
                        let rect = CGRect(x: originX + CGFloat(column) * (cell + gap),
                                          y: CGFloat(row) * (cell + gap), width: cell, height: cell)
                        // Apparition en vague diagonale.
                        let delay = Double(column + row) * 0.045
                        let appear = reduceMotion ? 1 : min(1, max(0, (t - delay) / 0.45))
                        let eased = 1 - pow(1 - appear, 3)
                        guard eased > 0 else { continue }
                        let inset = cell * 0.5 * (1 - eased)
                        let frame = rect.insetBy(dx: inset, dy: inset)
                        canvas.fill(Path(roundedRect: frame, cornerRadius: cell * 0.22),
                                    with: .color(Carnet.sheetRaised.opacity(0.9 * eased)))
                        // Remplissage : une onde qui balaie le semestre, cours par cours.
                        let seed: Double = Double((row * 31 + column * 17) % 23) / 23
                        let phase: Double = t * 0.9 - Double(column) * 0.42 + Double(row) * 0.9 + seed * 2
                        let wave: Double = sin(phase)
                        let raw: Double = (wave + 0.15) * 1.6
                        let fill: Double = max(0, min(1, raw)) * eased
                        guard fill > 0.02, t > 0.9 else { continue }
                        let isSeries = (row + column) % 3 == 0
                        let mark = cell * (isSeries ? 0.46 : 0.36) * fill
                        let markRect = CGRect(x: rect.midX - mark / 2, y: rect.midY - mark / 2, width: mark, height: mark)
                        let path = isSeries ? Path(roundedRect: markRect, cornerRadius: mark * 0.22) : Path(ellipseIn: markRect)
                        canvas.fill(path, with: .color(tint.opacity(min(1, 0.35 + fill))))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 2. Ton semestre se construit

private struct ImportScreen: View {
    @Bindable var setup: OnboardingAutoSetup
    var retry: () -> Void
    var goManual: () -> Void
    var proceed: () -> Void

    @State private var smoother = Smoother()
    @State private var celebrate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDone: Bool { setup.phase == .done }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if case .failed(let message) = setup.phase {
                    failure(message)
                } else {
                    SemesterGrid(rows: setup.grid, weeks: setup.weeks, currentID: setup.currentID,
                                 working: setup.isWorking, celebrate: celebrate, showsLegend: true)
                        .padding(14)
                        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Carnet.rule, lineWidth: 0.5))
                    FeatureCarousel(highlights: setup.highlights, paused: false)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 110)
            .frame(maxWidth: Layout.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            if isDone {
                Button(action: proceed) {
                    Label("Continuer", systemImage: "arrow.right")
                }
                .buttonStyle(.carnetPrimaryWide)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.2), value: isDone)
        .onChange(of: isDone) { _, done in
            guard done else { return }
            Haptics.success()
            guard !reduceMotion else { return }
            celebrate = true
            Task {
                try? await Task.sleep(for: .seconds(0.9))
                celebrate = false
            }
        }
    }

    /// L'anneau, le titre, le temps restant et ce qui se fait à l'instant.
    private var header: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !setup.isWorking)) { context in
            let now = context.date
            let target: Double = isDone ? 1 : setup.progress.fraction(at: now)
            let fraction: Double = smoother.value(target)
            HStack(alignment: .center, spacing: 20) {
                ImportRing(fraction: fraction, done: isDone,
                             colors: setup.grid.map { Carnet.tint($0.colorHex) })
                    .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 6) {
                    Text(setup.headline)
                        .font(Carnet.serif(.title2, weight: .semibold))
                        .foregroundStyle(Carnet.ink)
                        .contentTransition(.opacity)
                        .fixedSize(horizontal: false, vertical: true)
                    if isDone {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(Carnet.inkSecondary)
                            .transition(.opacity)
                    } else if setup.isWorking {
                        Text(ImportProgress.remainingLabel(setup.progress.remainingSeconds(at: now)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Carnet.inkSecondary)
                            .contentTransition(.numericText())
                        if let line = setup.currentLine(at: now) {
                            HStack(spacing: 6) {
                                Text(line.code).font(.caption.weight(.bold))
                                Text(line.step).font(.caption.monospacedDigit())
                                    .contentTransition(.numericText())
                            }
                            .foregroundStyle(Carnet.inkTertiary)
                            .animation(.snappy, value: line.step)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isDone ? "Import terminé. \(summary)" : "Import en cours, \(Int(fraction * 100)) pour cent")
        }
    }

    private var summary: String {
        let t = setup.totals
        var parts = ["\(t.courses) cours"]
        if t.series > 0 { parts.append("\(t.series) séries") }
        if t.theory > 0 { parts.append("\(t.theory) éléments de théorie") }
        return parts.joined(separator: " · ")
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(Carnet.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button("Réessayer la connexion", action: retry)
                .buttonStyle(.carnetPrimaryWide)
            Button("Continuer sans Moodle", action: goManual)
                .buttonStyle(.carnetSecondaryWide)
        }
        .padding(18)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Ne recule jamais : une estimation qui se corrige vers le bas ne doit pas
/// faire reculer l'anneau sous les yeux. Une référence, pas un état observé —
/// la lire pendant le rendu ne relance pas de rendu.
private final class Smoother {
    private var shown = 0.0
    func value(_ target: Double) -> Double {
        // Rattrape vite, sans sauter : 18 % de l'écart par image.
        if target > shown { shown += max(0.0008, (target - shown) * 0.18) }
        shown = min(shown, max(target, shown))
        return min(1, shown)
    }
}

/// L'anneau d'avancement : la trace aux couleurs des cours, une tête lumineuse,
/// le pourcentage qui roule — et une coche quand c'est fini.
private struct ImportRing: View {
    var fraction: Double
    var done: Bool
    var colors: [Color]

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let line = size * 0.085
            let gradient = colors.count >= 2 ? colors + [colors[0]] : [Carnet.ink.opacity(0.6), Carnet.ink]
            ZStack {
                Circle().stroke(Carnet.rule, lineWidth: line)
                Circle()
                    .trim(from: 0, to: max(0.002, fraction))
                    .stroke(AngularGradient(colors: gradient, center: .center),
                            style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                // La tête : un point qui brille, là où l'import en est.
                Circle()
                    .fill(Carnet.sheet)
                    .frame(width: line * 0.55, height: line * 0.55)
                    .shadow(color: (colors.first ?? Carnet.ink).opacity(0.7), radius: 5)
                    .offset(y: -size / 2 + line / 2)
                    .rotationEffect(.degrees(360 * fraction))
                    .opacity(done || fraction < 0.01 ? 0 : 1)
                Group {
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(.title, design: .rounded).weight(.bold))
                            .foregroundStyle(Carnet.ink)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(Int(fraction * 100))")
                                .font(Carnet.serif(.title, weight: .semibold).monospacedDigit())
                                .contentTransition(.numericText(value: fraction * 100))
                            Text("%").font(.caption.weight(.semibold)).foregroundStyle(Carnet.inkSecondary)
                        }
                        .foregroundStyle(Carnet.ink)
                        .transition(.opacity)
                    }
                }
                .animation(.spring(duration: 0.5, bounce: 0.35), value: done)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// La grille du semestre : une ligne par cours, une case par semaine. Une
/// semaine lue sur Moodle apparaît en contour ; une fois rangée, elle se
/// remplit — un point pour la théorie, un carré pour une série, une marque
/// pour une échéance.
struct SemesterGrid: View {
    var rows: [SemesterGridRow]
    var weeks: Int
    var currentID: String?
    var working: Bool
    var celebrate: Bool
    var compact = false
    var showsLegend = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            grid
            if showsLegend {
                HStack(spacing: 14) {
                    legend(Circle().frame(width: 7, height: 7), "théorie")
                    legend(RoundedRectangle(cornerRadius: 1.5).frame(width: 8, height: 8), "série")
                    legend(Circle().fill(Carnet.wrong).frame(width: 5, height: 5), "échéance")
                    Spacer()
                }
                .padding(.top, 6)
                .padding(.leading, compact ? 0 : 64)
            }
        }
    }

    private func legend(_ mark: some View, _ text: String) -> some View {
        HStack(spacing: 5) {
            mark.foregroundStyle(Carnet.inkSecondary)
            Text(text).font(.caption2).foregroundStyle(Carnet.inkTertiary)
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            if !compact {
                HStack(spacing: 0) {
                    Text("Semaine").font(.caption2.weight(.semibold)).foregroundStyle(Carnet.inkTertiary)
                        .frame(width: 64, alignment: .leading)
                    HStack(spacing: 3) {
                        ForEach(1...max(weeks, 1), id: \.self) { week in
                            Text("\(week)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(Carnet.inkTertiary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            if rows.isEmpty {
                ForEach(0..<4, id: \.self) { _ in placeholderRow }
                    .redacted(reason: .placeholder)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { rowIndex, row in
                HStack(spacing: 0) {
                    if !compact {
                        Text(row.code)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Carnet.tint(row.colorHex).accessibleInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: 64, alignment: .leading)
                    }
                    HStack(spacing: compact ? 2 : 3) {
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                            GridCell(cell: cell, tint: Carnet.tint(row.colorHex), index: index,
                                     wave: celebrate, waveDelay: Double(index + rowIndex) * 0.025)
                        }
                    }
                    .overlay {
                        if working, row.id == currentID {
                            Sheen().clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibility(row))
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.2), value: rows.count)
    }

    private var placeholderRow: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(weeks, 1), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4).fill(Carnet.sheetRaised).aspectRatio(1, contentMode: .fit)
            }
        }
        .padding(.leading, compact ? 0 : 64)
    }

    private func accessibility(_ row: SemesterGridRow) -> String {
        let filled = row.cells.filter(\.isFilled).count
        let series = row.cells.reduce(0) { $0 + $1.series }
        return "\(row.code) : \(filled) semaines rangées, \(series) séries"
    }
}

private struct GridCell: View {
    var cell: SemesterGridRow.Cell
    var tint: Color
    var index: Int
    var wave: Bool
    var waveDelay: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(cell.isFilled ? tint.opacity(0.16) : Carnet.sheetRaised.opacity(cell.outlined ? 1 : 0.6))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(tint.opacity(cell.outlined && !cell.isFilled ? 0.45 : 0), lineWidth: 1)
            GeometryReader { proxy in
                let side = proxy.size.width
                ZStack {
                    if cell.series > 0 {
                        RoundedRectangle(cornerRadius: side * 0.1, style: .continuous)
                            .fill(tint)
                            .frame(width: side * 0.46, height: side * 0.46)
                    } else if cell.theory > 0 {
                        Circle().fill(tint).frame(width: side * 0.36, height: side * 0.36)
                    }
                    if cell.deadline {
                        Circle().fill(Carnet.wrong)
                            .frame(width: side * 0.22, height: side * 0.22)
                            .offset(x: side * 0.28, y: -side * 0.28)
                    }
                }
                .frame(width: side, height: side)
                .scaleEffect(cell.isFilled ? 1 : 0.2)
                .opacity(cell.isFilled ? 1 : 0)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .scaleEffect(wave && cell.isFilled ? 1.16 : 1)
        .animation(.spring(duration: 0.55, bounce: 0.45).delay(Double(index) * 0.035), value: cell.isFilled)
        .animation(.smooth(duration: 0.35).delay(Double(index) * 0.02), value: cell.outlined)
        .animation(.spring(duration: 0.4, bounce: 0.5).delay(waveDelay), value: wave)
    }
}

/// Un reflet qui balaie la ligne du cours en cours d'import.
private struct Sheen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            GeometryReader { proxy in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                LinearGradient(colors: [.clear, Carnet.sheet.opacity(0.55), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.22)
                    .offset(x: (proxy.size.width * 1.22) * phase - proxy.size.width * 0.22)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: Cartes de présentation

/// L'app, présentée pendant l'import : une carte toutes les six secondes,
/// illustrée — et, dès qu'un cours est rangé, racontée avec **ses** données.
private struct FeatureCarousel: View {
    var highlights: [OnboardingAutoSetup.Highlight]
    var paused: Bool

    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cards: [FeatureCard.Kind] { FeatureCard.Kind.allCases }

    var body: some View {
        VStack(spacing: 12) {
            TabView(selection: $index) {
                ForEach(Array(cards.enumerated()), id: \.offset) { offset, kind in
                    FeatureCard(kind: kind, highlight: highlights.first, active: offset == index)
                        .padding(.horizontal, 2)
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 300)
            HStack(spacing: 6) {
                ForEach(cards.indices, id: \.self) { offset in
                    Capsule()
                        .fill(offset == index ? Carnet.ink : Carnet.rule)
                        .frame(width: offset == index ? 20 : 6, height: 6)
                }
            }
            .animation(.snappy(duration: 0.32), value: index)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
        .task(id: index) {
            guard !paused else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.6, bounce: 0.12)) {
                index = (index + 1) % cards.count
            }
        }
    }
}

private struct FeatureCard: View {
    enum Kind: CaseIterable {
        case week, series, time, groups, refresh
    }

    var kind: Kind
    var highlight: OnboardingAutoSetup.Highlight?
    var active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            illustration
                .frame(height: 112)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Carnet.serif(.title3, weight: .semibold))
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Du papier, pas du verre : dans une `TabView` paginée, le verre laissait
        // voir le rectangle de la page derrière ses coins arrondis.
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Carnet.rule, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color { highlight.map { Carnet.tint($0.colorHex) } ?? Carnet.ink }

    private var title: String {
        switch kind {
        case .week:
            if let h = highlight { return "Semaine \(h.week) · \(h.name)" }
            return "Ta semaine, d'un coup d'œil"
        case .series: return "Chaque série, question par question"
        case .time: return "Le temps qui compte vraiment"
        case .groups: return "Travailler à plusieurs"
        case .refresh: return "Rien à refaire"
        }
    }

    private var text: String {
        switch kind {
        case .week:
            if let h = highlight {
                var parts: [String] = []
                if h.videos > 0 { parts.append("\(h.videos) vidéo\(h.videos > 1 ? "s" : "")") }
                if h.theory > 0 { parts.append("\(h.theory) élément\(h.theory > 1 ? "s" : "") de théorie") }
                if h.series > 0 { parts.append("la série à faire") }
                let content = parts.isEmpty ? "ce qui est prévu" : parts.joined(separator: ", ")
                return "Cette semaine en \(h.code) : \(content). Aujourd'hui te dit par quoi commencer."
            }
            return "La théorie à voir, la série à rendre, et ce que tu as en retard — rangés dans la bonne semaine."
        case .series:
            return "L'énoncé imprimé, agrandi d'un toucher ; tu coches chaque sous-question et le corrigé arrive à sa date."
        case .time:
            return "Les heures de cours comptent seules. Les exercices, au chrono. Tu vois où tu en es face à la charge EPFL."
        case .groups:
            return "Vois qui travaille en direct, compare l'avancement série par série, pose une question — chiffrée de bout en bout."
        case .refresh:
            return "Une nouvelle série publiée sur Moodle arrive toute seule, énoncé lu. Ton semestre se tient à jour."
        }
    }

    @ViewBuilder
    private var illustration: some View {
        switch kind {
        case .week: WeekBarsIllustration(tint: tint, active: active)
        case .series: SubQuestionIllustration(tint: tint, active: active)
        case .time: TimeIllustration(tint: tint, active: active)
        case .groups: GroupIllustration(active: active)
        case .refresh: RefreshIllustration(tint: tint, active: active)
        }
    }
}

// MARK: Illustrations des cartes

/// Les heures de la semaine, qui montent jour après jour.
private struct WeekBarsIllustration: View {
    var tint: Color
    var active: Bool
    private let heights: [CGFloat] = [0.45, 0.7, 0.35, 0.9, 0.6, 0.2, 0.1]

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(heights.indices, id: \.self) { day in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(day == 3 ? tint : tint.opacity(0.35))
                        .frame(width: 18, height: active ? 70 * heights[day] : 4)
                        .animation(.spring(duration: 0.6, bounce: 0.25).delay(0.12 + Double(day) * 0.06), value: active)
                    Text(["L", "M", "M", "J", "V", "S", "D"][day])
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Carnet.inkTertiary)
                }
            }
        }
    }
}

/// Des sous-questions qui se cochent une à une.
private struct SubQuestionIllustration: View {
    var tint: Color
    var active: Bool
    private let labels = ["1a", "1b", "1c", "2", "3a", "3b"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.7)) { context in
            let step = active ? Int(context.date.timeIntervalSinceReferenceDate / 0.7) % (labels.count + 3) : 0
            HStack(spacing: 8) {
                ForEach(labels.indices, id: \.self) { i in
                    let done = i < step
                    Text(labels[i])
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(done ? Carnet.ground : Carnet.inkSecondary)
                        .frame(width: 36, height: 34)
                        .background(done ? tint : Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .scaleEffect(i == step - 1 ? 1.12 : 1)
                        .animation(.spring(duration: 0.35, bounce: 0.5), value: step)
                }
            }
        }
    }
}

/// Un anneau de charge qui se remplit : cours (seul) puis chrono.
private struct TimeIllustration: View {
    var tint: Color
    var active: Bool

    var body: some View {
        HStack(spacing: 22) {
            ZStack {
                Circle().stroke(Carnet.rule, lineWidth: 9)
                Circle().trim(from: 0, to: active ? 0.42 : 0)
                    .stroke(tint.opacity(0.45), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.9).delay(0.15), value: active)
                Circle().trim(from: 0.42, to: active ? 0.78 : 0.42)
                    .stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.9).delay(0.9), value: active)
            }
            .frame(width: 76, height: 76)
            VStack(alignment: .leading, spacing: 8) {
                legend(tint.opacity(0.45), "Cours, comptés seuls")
                legend(tint, "Exercices, au chrono")
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.caption.weight(.medium)).foregroundStyle(Carnet.inkSecondary)
        }
    }
}

/// Trois membres, dont un en direct ; un cadenas pour l'entraide.
private struct GroupIllustration: View {
    var active: Bool

    var body: some View {
        HStack(spacing: -10) {
            ForEach(Array(["A", "M", "C"].enumerated()), id: \.offset) { offset, initial in
                Text(initial)
                    .font(.headline)
                    .foregroundStyle(Carnet.ink)
                    .frame(width: 52, height: 52)
                    .background(Carnet.sheetRaised, in: Circle())
                    .overlay(Circle().strokeBorder(Carnet.sheet, lineWidth: 3))
                    .overlay(alignment: .bottomTrailing) {
                        if offset == 1 {
                            Circle().fill(Carnet.correct)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(Carnet.sheet, lineWidth: 2.5))
                                .symbolEffect(.pulse, isActive: active)
                        }
                    }
                    .offset(y: active ? 0 : 12)
                    .opacity(active ? 1 : 0)
                    .animation(.spring(duration: 0.5, bounce: 0.3).delay(Double(offset) * 0.08), value: active)
            }
            Image(systemName: "lock.fill")
                .font(.title3)
                .foregroundStyle(Carnet.inkSecondary)
                .padding(.leading, 26)
                .opacity(active ? 1 : 0)
                .animation(.easeOut(duration: 0.4).delay(0.35), value: active)
        }
    }
}

/// Une nouvelle série qui arrive d'elle-même.
private struct RefreshIllustration: View {
    var tint: Color
    var active: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title)
                .foregroundStyle(Carnet.inkSecondary)
                .symbolEffect(.bounce, value: active)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).fill(row == 0 ? tint : tint.opacity(0.3))
                            .frame(width: 12, height: 12)
                        RoundedRectangle(cornerRadius: 3).fill(Carnet.sheetRaised)
                            .frame(width: row == 0 ? 120 : 96, height: 10)
                    }
                    .offset(x: row == 0 && !active ? 30 : 0)
                    .opacity(row == 0 && !active ? 0 : 1)
                    .animation(.spring(duration: 0.55, bounce: 0.3).delay(0.5), value: active)
                }
            }
        }
    }
}

// MARK: - 3. Relie le reste

private struct ConnectionsScreen: View {
    @Bindable var setup: OnboardingAutoSetup
    var proceed: () -> Void

    @Environment(AppContainer.self) private var app
    @State private var appeared = false
    @State private var working: TaskProvider?
    @State private var message: String?
    @State private var sheet: ConnectionSheet?
    @State private var showingTasks = false
    @State private var calendarGranted = false
    @State private var refresh = 0

    private static let providers: [TaskProvider] = [.reminders, .todoist, .microsoftToDo, .googleTasks, .notion, .tickTick]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Relie le reste")
                        .font(Carnet.serif(.largeTitle, weight: .semibold))
                        .foregroundStyle(Carnet.ink)
                    Text("Tout est facultatif, et se règle aussi plus tard dans le profil.")
                        .font(.subheadline)
                        .foregroundStyle(Carnet.inkSecondary)
                }
                .rise(appeared, delay: 0.05)

                epflCard.rise(appeared, delay: 0.12)

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Tes to-do", "Les tâches datées dans l'agenda, celles d'un cours dans le cours.")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(Self.providers) { provider in
                            providerTile(provider)
                        }
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Carnet.inkSecondary)
                            .transition(.opacity)
                    }
                }
                .rise(appeared, delay: 0.2)

                VStack(spacing: 10) {
                    row(icon: "calendar", title: "Calendrier de l'iPhone",
                        detail: "Ton horaire et tes sessions dans l'agenda",
                        connected: calendarGranted) {
                        Task {
                            calendarGranted = await app.calendar.requestAccess()
                            if calendarGranted { Haptics.success() }
                        }
                    }
                    row(icon: "person.2", title: "Compte StudyTrack",
                        detail: "Groupes en direct, entraide chiffrée",
                        connected: app.social.isSignedIn) { sheet = .groups }
                    row(icon: "rectangle.stack", title: "AnkiWeb",
                        detail: "Tes cartes et ton temps de révision",
                        connected: AnkiWebSync.shared.isSignedIn) { sheet = .ankiweb }
                }
                .rise(appeared, delay: 0.28)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 110)
            .frame(maxWidth: Layout.readableWidth)
            .frame(maxWidth: .infinity)
            .id(refresh)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button(action: proceed) {
                Label("Voir mon semestre", systemImage: "arrow.right")
            }
            .buttonStyle(.carnetPrimaryWide)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .sheet(item: $sheet, onDismiss: { refresh += 1 }) { ConnectionSheetContent(sheet: $0) }
        .sheet(isPresented: $showingTasks, onDismiss: { refresh += 1 }) {
            NavigationStack {
                TaskIntegrationsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { showingTasks = false } } }
            }
        }
        .onAppear {
            calendarGranted = app.calendar.hasAccess
            appeared = true
        }
    }

    private var epflCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(Carnet.correct)
                .symbolEffect(.bounce, value: appeared)
            VStack(alignment: .leading, spacing: 2) {
                Text("EPFL connecté").font(.headline).foregroundStyle(Carnet.ink)
                Text((["Moodle"] + setup.extraSites).joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
            }
            Spacer()
        }
        .padding(16)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func sectionTitle(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Carnet.serif(.title3, weight: .semibold)).foregroundStyle(Carnet.ink)
            Text(detail).font(.footnote).foregroundStyle(Carnet.inkSecondary)
        }
    }

    private func providerTile(_ provider: TaskProvider) -> some View {
        let connected = TaskConnector.isConnected(provider, settings: app.settings)
        return Button {
            Task { await connect(provider) }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    if working == provider {
                        ProgressView()
                    } else {
                        Image(systemName: connected ? "checkmark.circle.fill" : provider.icon)
                            .font(.title2)
                            .foregroundStyle(connected ? Carnet.correct : Carnet.ink)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(height: 30)
                Text(provider.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(connected ? Carnet.correct.opacity(0.6) : Carnet.rule, lineWidth: connected ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .disabled(connected || working != nil)
        .accessibilityLabel("\(provider.label), \(connected ? "connecté" : "relier")")
        .animation(.snappy, value: connected)
    }

    private func connect(_ provider: TaskProvider) async {
        if provider == .reminders {
            working = provider
            message = await TaskConnector.authorizeReminders(settings: app.settings)
            working = nil
            refresh += 1
            return
        }
        guard let oauth = TaskConnector.oauth(for: provider) else {
            // Pas encore d'OAuth dans cette build : la page complète, avec la
            // configuration manuelle et l'aide.
            showingTasks = true
            return
        }
        working = provider
        let outcome = await TaskConnector.connect(provider, via: oauth, settings: app.settings)
        working = nil
        withAnimation(.snappy) { message = outcome.message }
        if !outcome.notionDatabases.isEmpty { showingTasks = true }
        refresh += 1
    }

    private func row(icon: String, title: String, detail: String, connected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: connected ? "checkmark.circle.fill" : icon)
                    .font(.title3)
                    .foregroundStyle(connected ? Carnet.correct : Carnet.ink)
                    .frame(width: 30)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(Carnet.ink)
                    Text(detail).font(.footnote).foregroundStyle(Carnet.inkSecondary)
                }
                Spacer()
                if !connected {
                    Text("Relier").font(.subheadline.weight(.semibold)).foregroundStyle(Carnet.ink)
                }
            }
            .padding(16)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .disabled(connected)
    }
}

// MARK: - 4. C'est prêt

private struct FinaleScreen: View {
    @Bindable var setup: OnboardingAutoSetup
    var finish: () -> Void

    @State private var appeared = false
    @State private var counts = (courses: 0, series: 0, theory: 0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion { Burst(colors: setup.grid.map { Carnet.tint($0.colorHex) }) }
            VStack(alignment: .leading, spacing: 26) {
                Spacer(minLength: 20)
                Text("C'est prêt.")
                    .font(Carnet.serif(.largeTitle, weight: .semibold))
                    .foregroundStyle(Carnet.ink)
                    .rise(appeared, delay: 0.1)
                SemesterGrid(rows: setup.grid, weeks: setup.weeks, currentID: nil,
                             working: false, celebrate: appeared, compact: false)
                    .padding(14)
                    .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .rise(appeared, delay: 0.2)
                HStack(spacing: 12) {
                    stat(counts.courses, "cours")
                    stat(counts.series, "séries")
                    stat(counts.theory, "théorie")
                }
                .rise(appeared, delay: 0.3)
                Text("Chaque matin, Aujourd'hui te dit quoi faire. Les nouvelles séries arrivent seules.")
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .rise(appeared, delay: 0.38)
                Spacer(minLength: 20)
                Button(action: finish) {
                    Label("Ouvrir Aujourd'hui", systemImage: "sun.max.fill")
                }
                .buttonStyle(.carnetPrimaryWide)
                .rise(appeared, delay: 0.46)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: Layout.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .sensoryFeedback(.success, trigger: appeared)
        .onAppear {
            appeared = true
            // Les chiffres roulent jusqu'à leur valeur, l'un après l'autre.
            let target = setup.totals
            withAnimation(.smooth(duration: 1.0).delay(0.35)) { counts.courses = target.courses }
            withAnimation(.smooth(duration: 1.2).delay(0.5)) { counts.series = target.series }
            withAnimation(.smooth(duration: 1.4).delay(0.65)) { counts.theory = target.theory }
        }
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(Carnet.serif(.title, weight: .semibold).monospacedDigit())
                .foregroundStyle(Carnet.ink)
                .contentTransition(.numericText(value: Double(value)))
            Text(label).font(.footnote).foregroundStyle(Carnet.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Une gerbe de petits carrés et de points — les marques de la grille — aux
/// couleurs des cours, une seule fois, deux secondes et demie.
private struct Burst: View {
    var colors: [Color]
    @State private var start = Date()

    private struct Particle {
        var angle: Double, speed: Double, spin: Double, size: Double, colorIndex: Int, square: Bool
    }

    @State private var particles: [Particle] = (0..<90).map { i in
        Particle(angle: Double.random(in: -Double.pi * 0.95 ... -Double.pi * 0.05),
                 speed: Double.random(in: 260...620), spin: Double.random(in: -6...6),
                 size: Double.random(in: 5...10), colorIndex: i, square: i % 3 == 0)
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            Canvas { canvas, size in
                guard t < 2.6 else { return }
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.42)
                let palette = colors.isEmpty ? [Carnet.ink] : colors
                for particle in particles {
                    let x = origin.x + cos(particle.angle) * particle.speed * t
                    let y = origin.y + sin(particle.angle) * particle.speed * t + 520 * t * t
                    let fade = max(0, 1 - t / 2.6)
                    var piece = canvas
                    piece.opacity = fade
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(particle.spin * t))
                    let rect = CGRect(x: -particle.size / 2, y: -particle.size / 2, width: particle.size, height: particle.size)
                    let path = particle.square ? Path(roundedRect: rect, cornerRadius: 2) : Path(ellipseIn: rect)
                    piece.fill(path, with: .color(palette[particle.colorIndex % palette.count]))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Outils

/// Un bouton qui s'enfonce sous le doigt, haptique à l'appui.
private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.16, bounce: 0), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

private extension View {
    /// Monte et apparaît, en décalé : les éléments d'un écran arrivent en vague.
    func rise(_ visible: Bool, delay: Double) -> some View {
        self
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 14)
            .animation(.spring(duration: 0.6, bounce: 0.15).delay(delay), value: visible)
    }
}

