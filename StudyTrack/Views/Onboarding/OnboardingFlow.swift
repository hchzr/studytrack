import SwiftUI
import EventKit

/// L'accueil par la connexion EPFL, une idée par écran :
///
///   1. **Bienvenue** — la promesse, et un seul bouton ;
///   2. **L'import** — en plein écran, ce qui est trouvé tombe ; un grand chiffre,
///      et une seule carte à la fois (ses cours, son objectif, son rappel) ;
///   3. **Le semestre** — né de l'effondrement final, la grille se déploie ;
///   4. **Tes to-do** — chacune d'un toucher ;
///   5. **À toi** — le chrono, essayé dix secondes.
struct OnboardingFlow: View {
    @Bindable var setup: OnboardingAutoSetup
    /// Lance l'import (une fois Moodle connecté).
    var start: () -> Void
    /// Le parcours sans Moodle (section et cours à la main).
    var goManual: () -> Void
    var finish: () -> Void

    enum Screen: Int { case welcome, importing, reveal, connections, finale }

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
                        // À l'instant du choc : pas de glissé, la grille naît sur place.
                        withAnimation(.easeOut(duration: 0.15)) { screen = .reveal }
                    }
                case .reveal:
                    RevealScreen(setup: setup) { advance(to: .connections) }
                case .connections:
                    ConnectionsScreen(setup: setup) { advance(to: .finale) }
                case .finale:
                    FinaleScreen(setup: setup, finish: finish)
                }
            }
            .transition(reduceMotion || screen == .reveal ? .opacity : .asymmetric(
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
            if demo >= 2 { screen = .reveal }
            if demo >= 3 { screen = .connections }
            if demo >= 4 { screen = .finale }
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
                Text("Tout ton semestre EPFL, lu sur Moodle et rangé semaine par semaine.")
                    .font(.title3)
                    .foregroundStyle(Carnet.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .rise(appeared, delay: 0.33)
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

/// L'import, en plein écran : ce que l'app trouve tombe, un seul grand chiffre
/// dit où on en est, et **une** carte à la fois propose ce qu'on peut faire en
/// attendant (trier ses cours, son objectif, son rappel). Les objets se posent
/// sur la carte ; chaque cours fini s'envole dans le chiffre. À la fin, tout
/// s'effondre au centre — et la grille du semestre en naît (écran suivant).
private struct ImportScreen: View {
    @Bindable var setup: OnboardingAutoSetup
    var retry: () -> Void
    var goManual: () -> Void
    var proceed: () -> Void

    @State private var smoother = Smoother()
    @State private var deckDone = false
    @State private var stageBottom: CGFloat = 0
    @State private var cardTop: CGFloat?
    @State private var counterCenter: CGPoint?
    @State private var implode = false
    @State private var bump = 0
    @State private var hintGone = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDone: Bool { setup.phase == .done }
    private var failure: String? {
        if case .failed(let message) = setup.phase { return message }
        return nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            counter
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 28)

            ImportPhysicsStage(setup: setup, floor: floor, collectPoint: counterCenter,
                               implode: implode, onImploded: proceed)
                .ignoresSafeArea()
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { stageBottom = $0 }

            chapter
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .frame(maxWidth: Layout.readableWidth)
        }
        .onChange(of: isDone && deckDone) { _, ready in
            guard ready else { return }
            Haptics.success()
            Task {
                // Le temps de voir « 100 », puis tout s'effondre.
                try? await Task.sleep(for: .seconds(0.7))
                implode = true
            }
        }
        .onChange(of: setup.totals.courses) { _, _ in bump += 1 }
    }

    /// Le sol de la scène : le haut de la carte du moment, ou le bas de l'écran.
    private var floor: CGFloat {
        guard let cardTop, !deckDone || failure != nil else { return 0 }
        return max(0, stageBottom - cardTop + 2)
    }

    // MARK: Le chiffre

    private var counter: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !setup.isWorking)) { context in
            let now = context.date
            let target: Double = isDone ? 1 : setup.progress.fraction(at: now)
            let fraction: Double = smoother.value(target)
            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(fraction * 100))")
                        .font(.system(size: 112, weight: .semibold, design: .serif).monospacedDigit())
                        .contentTransition(.numericText(value: fraction * 100))
                        .animation(.snappy(duration: 0.25), value: Int(fraction * 100))
                    Text("%")
                        .font(.system(size: 34, weight: .semibold, design: .serif))
                        .foregroundStyle(Carnet.inkTertiary)
                }
                .foregroundStyle(Carnet.ink)
                .phaseAnimator([1.0, 1.07, 1.0], trigger: bump) { view, scale in
                    view.scaleEffect(scale)
                } animation: { scale in
                    scale > 1 ? .spring(duration: 0.18, bounce: 0) : .spring(duration: 0.5, bounce: 0.5)
                }
                .onGeometryChange(for: CGPoint.self) { proxy in
                    let frame = proxy.frame(in: .global)
                    return CGPoint(x: frame.midX, y: frame.midY)
                } action: { counterCenter = $0 }

                Text(caption(at: now))
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(Carnet.inkSecondary)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.25), value: caption(at: now))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isDone ? "Import terminé" : "Import en cours, \(Int(fraction * 100)) pour cent")
        }
        .allowsHitTesting(false)
    }

    /// Une seule ligne : le cours lu et le temps qui reste.
    private func caption(at now: Date) -> String {
        if failure != nil { return "Import interrompu" }
        if isDone { return deckDone ? "Ton semestre est prêt" : "Prêt — finis ton réglage" }
        if setup.isPaused { return "En pause · reprend à l'ouverture de l'app" }
        let remaining = ImportProgress.remainingLabel(setup.progress.remainingSeconds(at: now))
        guard let line = setup.currentLine(at: now) else { return setup.headline }
        return "\(line.code) · \(remaining)"
    }

    // MARK: La carte du moment

    @ViewBuilder
    private var chapter: some View {
        Group {
            if let failure {
                failureCard(failure)
                    .transition(.chapter)
            } else if !deckDone {
                OnboardingDeck(setup: setup, finished: $deckDone)
                    .padding(18)
                    .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(Carnet.rule, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.10), radius: 24, y: 10)
                    .transition(.chapter)
            } else if !hintGone, !isDone {
                hint
                    .transition(.chapter)
                    .task {
                        try? await Task.sleep(for: .seconds(5))
                        withAnimation(.smooth(duration: 0.5)) { hintGone = true }
                    }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { cardTop = $0 }
        .animation(.spring(duration: 0.55, bounce: 0.18), value: deckDone)
        .animation(.spring(duration: 0.55, bounce: 0.18), value: failure)
    }

    /// Une fois tout réglé, la scène est à soi : une invitation, puis plus rien.
    private var hint: some View {
        Label("Incline le téléphone. Lance-les du doigt.", systemImage: "iphone.gen3.radiowaves.left.and.right")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Carnet.inkSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 12)
    }

    private func failureCard(_ message: String) -> some View {
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
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}

extension AnyTransition {
    /// La carte du moment monte du bas, et y redescend.
    static var chapter: AnyTransition {
        .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - 3. Le semestre, révélé

/// Né du choc de la fin d'import : la gerbe part du centre, la grille s'y
/// déploie case par case. Une seule chose à faire : toucher une semaine.
private struct RevealScreen: View {
    @Bindable var setup: OnboardingAutoSetup
    var proceed: () -> Void

    @State private var revealed = false
    @State private var opened: WeekSelection?
    @Namespace private var hero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion { Burst(colors: setup.grid.map { Carnet.tint($0.colorHex) }, origin: 0.5) }
            VStack(spacing: 0) {
                Spacer(minLength: 16)
                VStack(spacing: 8) {
                    Text("Ton semestre")
                        .font(Carnet.serif(.largeTitle, weight: .semibold))
                        .foregroundStyle(Carnet.ink)
                    Text(summary)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Carnet.inkSecondary)
                }
                .rise(revealed, delay: 0.55)
                Spacer(minLength: 24).frame(maxHeight: 40)
                SemesterGrid(rows: setup.grid, weeks: setup.weeks, currentID: nil, working: false,
                             celebrate: false, namespace: hero, openedID: opened?.id,
                             revealed: revealed) { row, week in
                    guard let line = setup.grid.first(where: { $0.id == row }),
                          let cell = line.cells[safe: week - 1], cell.isFilled else { return }
                    Haptics.tap()
                    withAnimation(.spring(duration: 0.45, bounce: 0.16)) {
                        opened = WeekSelection(rowID: row, week: week, code: line.code, colorHex: line.colorHex, cell: cell)
                    }
                }
                .padding(16)
                .background(Carnet.sheet.opacity(revealed ? 1 : 0), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .animation(.smooth(duration: 0.6).delay(0.2), value: revealed)
                Text("Touche une semaine pour l'ouvrir.")
                    .font(.footnote)
                    .foregroundStyle(Carnet.inkTertiary)
                    .padding(.top, 14)
                    .rise(revealed, delay: 1.1)
                Spacer(minLength: 24)
                Button(action: proceed) {
                    Label("Continuer", systemImage: "arrow.right")
                }
                .buttonStyle(.carnetPrimaryWide)
                .rise(revealed, delay: 1.3)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: Layout.readableWidth)
            .frame(maxWidth: .infinity)

            if let opened {
                WeekDetailCard(selection: opened, namespace: hero) {
                    withAnimation(.spring(duration: 0.34, bounce: 0.1)) { self.opened = nil }
                }
                .zIndex(2)
            }
        }
        .onAppear { revealed = true }
    }

    private var summary: String {
        let t = setup.totals
        var parts = ["\(t.courses) cours"]
        if t.series > 0 { parts.append("\(t.series) séries") }
        if t.theory > 0 { parts.append("\(t.theory) chapitres") }
        return parts.joined(separator: " · ")
    }
}

/// Une semaine ouverte depuis la grille.
struct WeekSelection: Equatable {
    var rowID: String
    var week: Int
    var code: String
    var colorHex: String
    var cell: SemesterGridRow.Cell
    var id: String { "\(rowID)-\(week)" }
}

/// La semaine, ouverte : la case grandit en carte (transition héro) et montre
/// ce que l'import y a rangé.
private struct WeekDetailCard: View {
    let selection: WeekSelection
    let namespace: Namespace.ID
    var close: () -> Void

    var body: some View {
        let tint = Carnet.tint(selection.colorHex)
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selection.code).font(.caption.weight(.bold)).foregroundStyle(tint.accessibleInk)
                        Text("Semaine \(selection.week)").font(Carnet.serif(.title2, weight: .semibold)).foregroundStyle(Carnet.ink)
                    }
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(Carnet.inkSecondary)
                            .frame(width: 36, height: 36).background(Carnet.sheetRaised, in: Circle())
                    }
                    .accessibilityLabel("Fermer")
                }
                ForEach(Array(selection.cell.entries.enumerated()), id: \.offset) { index, entry in
                    HStack(spacing: 12) {
                        Image(systemName: icon(entry.kind))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(entry.kind == .deadline ? Carnet.wrong : tint)
                            .frame(width: 32, height: 32)
                            .background((entry.kind == .deadline ? Carnet.wrong : tint).opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title.isEmpty ? label(entry.kind) : MathMarkup.plain(entry.title))
                                .font(.subheadline.weight(.medium)).foregroundStyle(Carnet.ink).lineLimit(2)
                            Text(entry.videos > 0 ? "\(label(entry.kind)) · \(entry.videos) vidéo\(entry.videos > 1 ? "s" : "")" : label(entry.kind))
                                .font(.caption).foregroundStyle(Carnet.inkSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .transition(.opacity.combined(with: .offset(y: 8)))
                    .animation(.spring(duration: 0.4, bounce: 0.2).delay(0.12 + Double(index) * 0.05), value: selection)
                }
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Carnet.sheet)
                    .matchedGeometryEffect(id: selection.id, in: namespace)
            }
            .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
            .padding(24)
        }
    }

    private func icon(_ kind: ContentItemKind) -> String {
        switch kind {
        case .theory: return "play.rectangle.fill"
        case .series: return "doc.text.fill"
        case .deadline: return "flag.fill"
        default: return "doc"
        }
    }

    private func label(_ kind: ContentItemKind) -> String {
        switch kind {
        case .theory: return "Théorie"
        case .series: return "Série"
        case .deadline: return "Échéance"
        default: return "Document"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
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
    var namespace: Namespace.ID? = nil
    var openedID: String? = nil
    /// Faux puis vrai : la grille se déploie depuis son centre, case par case.
    var revealed = true
    var onTap: ((String, Int) -> Void)? = nil

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
                            .opacity(revealed ? 1 : 0)
                            .offset(x: revealed ? 0 : -10)
                            .animation(.smooth(duration: 0.5).delay(0.5 + Double(rowIndex) * 0.06), value: revealed)
                    }
                    HStack(spacing: compact ? 2 : 3) {
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                            GridCell(cell: cell, tint: Carnet.tint(row.colorHex), index: index,
                                     wave: celebrate, waveDelay: Double(index + rowIndex) * 0.025,
                                     revealed: revealed,
                                     revealDelay: revealDelay(row: rowIndex, column: index))
                                .modifier(HeroSource(id: "\(row.id)-\(index + 1)", namespace: namespace,
                                                     hidden: openedID == "\(row.id)-\(index + 1)"))
                                .contentShape(Rectangle())
                                .onTapGesture { onTap?(row.id, index + 1) }
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

    /// Les cases partent du centre : leur retard croît avec la distance.
    private func revealDelay(row: Int, column: Int) -> Double {
        let dx = Double(column) - Double(weeks - 1) / 2
        let dy = (Double(row) - Double(rows.count - 1) / 2) * 1.6
        return 0.05 + (dx * dx + dy * dy).squareRoot() * 0.045
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

/// La case, source de la transition héro quand une semaine s'ouvre.
private struct HeroSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID?
    let hidden: Bool

    func body(content: Content) -> some View {
        if let namespace {
            content
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.clear)
                        .matchedGeometryEffect(id: id, in: namespace, isSource: !hidden)
                }
                .opacity(hidden ? 0 : 1)
        } else {
            content
        }
    }
}

private struct GridCell: View {
    var cell: SemesterGridRow.Cell
    var tint: Color
    var index: Int
    var wave: Bool
    var waveDelay: Double
    var revealed = true
    var revealDelay = 0.0

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
        .scaleEffect(revealed ? 1 : 0.01)
        .opacity(revealed ? 1 : 0)
        .animation(.spring(duration: 0.6, bounce: 0.45).delay(revealDelay), value: revealed)
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

    private static let providers: [TaskProvider] = [.reminders, .todoist, .googleTasks, .notion, .tickTick, .things]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tes to-do")
                        .font(Carnet.serif(.largeTitle, weight: .semibold))
                        .foregroundStyle(Carnet.ink)
                    Text("Elles apparaissent dans ton agenda. Facultatif.")
                        .font(.subheadline)
                        .foregroundStyle(Carnet.inkSecondary)
                }
                .rise(appeared, delay: 0.05)

                VStack(alignment: .leading, spacing: 10) {
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
                .rise(appeared, delay: 0.12)

                VStack(spacing: 10) {
                    row(icon: "calendar", title: "Calendrier de l'iPhone",
                        detail: "Ton horaire EPFL",
                        connected: calendarGranted) {
                        Task {
                            calendarGranted = await app.calendar.requestAccess()
                            if calendarGranted { Haptics.success() }
                        }
                    }
                    row(icon: "person.2", title: "Compte StudyTrack",
                        detail: "Pour étudier en groupe",
                        connected: app.social.isSignedIn) { sheet = .groups }
                }
                .rise(appeared, delay: 0.22)
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
                Label("Continuer", systemImage: "arrow.right")
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

// MARK: - 5. À toi

/// Une seule chose : lancer le chrono, dix secondes, sur sa vraie série. On
/// comprend en le faisant ce qu'il mesure — les exercices ne comptent qu'ainsi.
private struct FinaleScreen: View {
    @Bindable var setup: OnboardingAutoSetup
    var finish: () -> Void

    @State private var appeared = false
    @State private var start: Date?
    @State private var finished = false
    @State private var pulse = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let length: TimeInterval = 10

    private var highlight: OnboardingAutoSetup.Highlight? { setup.highlights.first }
    private var tint: Color { highlight.map { Carnet.tint($0.colorHex) } ?? Carnet.ink }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            VStack(spacing: 10) {
                Text(finished ? "Dix secondes, comptées." : "Essaie le chrono")
                    .font(Carnet.serif(.largeTitle, weight: .semibold))
                    .foregroundStyle(Carnet.ink)
                    .contentTransition(.opacity)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .rise(appeared, delay: 0.05)
            Spacer(minLength: 24).frame(maxHeight: 56)
            dial
                .rise(appeared, delay: 0.18)
            Spacer(minLength: 24)
            Button(action: finish) {
                Label("Ouvrir Aujourd'hui", systemImage: "sun.max.fill")
            }
            .buttonStyle(.carnetPrimaryWide)
            .rise(appeared, delay: 0.3)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: Layout.readableWidth)
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.4), value: finished)
        .onAppear { appeared = true }
    }

    private var subtitle: String {
        if finished { return "Lance-le pour de vrai quand tu fais une série : ta séance d'exercices ne compte qu'ainsi." }
        if let h = highlight { return "Sur la série de la semaine \(h.week) en \(h.code). Touche le cercle." }
        return "Touche le cercle."
    }

    /// Le grand cadran : on le touche, il se remplit à la couleur du cours, et
    /// éclate en coche à la dixième seconde.
    private var dial: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: start == nil || finished)) { context in
            let elapsed = start.map { min(length, context.date.timeIntervalSince($0)) } ?? 0
            let fraction = finished ? 1 : elapsed / length
            ZStack {
                Circle().fill(tint.opacity(start == nil ? 0.08 : 0.12 + 0.1 * fraction))
                Circle().stroke(Carnet.rule, lineWidth: 14)
                Circle().trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.5), radius: 10)
                Group {
                    if finished {
                        Image(systemName: "checkmark")
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .foregroundStyle(tint)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    } else if start == nil {
                        Image(systemName: "play.fill")
                            .font(.system(size: 54, weight: .bold))
                            .foregroundStyle(tint)
                            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                    } else {
                        Text(String(format: "%05.2f", elapsed))
                            .font(.system(size: 48, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Carnet.ink)
                    }
                }
                .animation(.spring(duration: 0.5, bounce: 0.45), value: finished)
            }
            .frame(width: 230, height: 230)
            .phaseAnimator([1.0, 1.08, 1.0], trigger: pulse) { view, scale in
                view.scaleEffect(scale)
            } animation: { scale in
                scale > 1 ? .spring(duration: 0.16, bounce: 0) : .spring(duration: 0.55, bounce: 0.5)
            }
            .contentShape(Circle())
            .onTapGesture {
                guard start == nil else { return }
                Haptics.tap()
                pulse += 1
                start = Date()
            }
            .onChange(of: Int(elapsed)) { _, second in
                guard start != nil, !finished else { return }
                if second >= Int(length) {
                    finished = true
                    pulse += 1
                    Haptics.success()
                } else if second > 0 {
                    Haptics.soft()
                }
            }
            .accessibilityElement()
            .accessibilityLabel(finished ? "Chrono terminé" : "Lancer le chrono dix secondes")
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// Une gerbe de petits carrés et de points — les marques de la grille — aux
/// couleurs des cours, une seule fois, deux secondes et demie.
private struct Burst: View {
    var colors: [Color]
    /// La hauteur du point d'origine, en fraction de l'écran.
    var origin: Double = 0.42
    @State private var start = Date()

    private struct Particle {
        var angle: Double, speed: Double, spin: Double, size: Double, colorIndex: Int, square: Bool
    }

    @State private var particles: [Particle] = (0..<140).map { i in
        Particle(angle: Double.random(in: -Double.pi ... Double.pi),
                 speed: Double.random(in: 220...640), spin: Double.random(in: -6...6),
                 size: Double.random(in: 5...10), colorIndex: i, square: i % 3 == 0)
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            Canvas { canvas, size in
                guard t < 2.6 else { return }
                let origin = CGPoint(x: size.width / 2, y: size.height * self.origin)
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

