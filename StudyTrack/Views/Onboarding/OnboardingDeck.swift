import SwiftUI

/// Ce qu'on règle **pendant** l'import, d'un geste : chaque réglage est utile,
/// et s'anime. L'import ne l'attend pas ; il en tient compte.
///
///   1. trier les cours qui arrivent (glisser à droite : suivre ; à gauche :
///      ignorer) et choisir leur couleur ;
///   2. l'objectif d'heures par semaine, sur un cadran ;
///   3. l'heure du rappel du matin, en faisant glisser le soleil.
struct OnboardingDeck: View {
    @Bindable var setup: OnboardingAutoSetup
    /// Vrai une fois les trois réglages faits (les cartes de présentation prennent le relais).
    @Binding var finished: Bool
    @Environment(AppContainer.self) private var app

    enum Step { case courses, goal, reminder, done }
    @State private var step: Step = .courses

    var body: some View {
        ZStack {
            switch step {
            case .courses:
                CourseSortDeck(setup: setup) { advance(.goal) }
                    .transition(.deckStep)
            case .goal:
                GoalDialCard(totalCredits: totalCredits, weeks: setup.weeks) { hours in
                    let credits = max(totalCredits, 1)
                    app.settings.hoursPerCredit = min(45, max(12, hours * Double(setup.weeks) / credits))
                    advance(.reminder)
                }
                .transition(.deckStep)
            case .reminder:
                ReminderArcCard { hour in
                    if let hour {
                        app.settings.dailyReminderEnabled = true
                        app.settings.dailyReminderHour = hour
                    } else {
                        app.settings.dailyReminderEnabled = false
                    }
                    advance(.done)
                }
                .transition(.deckStep)
            case .done:
                EmptyView()
            }
        }
        .animation(.spring(duration: 0.55, bounce: 0.2), value: step)
        #if DEBUG
        .onAppear {
            switch PreviewLaunch.int(PreviewLaunch.onboardingDeckFlag) {
            case 1?: step = .goal
            case 2?: step = .reminder
            case 3?: step = .done; finished = true
            default: break
            }
        }
        #endif
    }

    /// Les crédits des cours suivis (4 par défaut quand on ne les connaît pas).
    private var totalCredits: Double {
        setup.cards.filter { !$0.decided || $0.kept }.count == 0 ? 4 :
            Double(setup.cards.filter { !$0.decided || $0.kept }.count) * 5
    }

    private func advance(_ next: Step) {
        Haptics.success()
        withAnimation(.spring(duration: 0.55, bounce: 0.2)) {
            step = next
            if next == .done { finished = true }
        }
    }
}

extension AnyTransition {
    static var deckStep: AnyTransition {
        .asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity).combined(with: .offset(y: 24)),
                    removal: .scale(scale: 1.05).combined(with: .opacity).combined(with: .offset(y: -24)))
    }
}

// MARK: - 1. Les cours

/// Les cours, en cartes empilées : glisser à droite pour suivre, à gauche pour
/// ignorer ; la couleur se choisit sous la carte et se propage à la grille.
struct CourseSortDeck: View {
    @Bindable var setup: OnboardingAutoSetup
    var finished: () -> Void

    @State private var drag: CGSize = .zero

    private var pending: [OnboardingAutoSetup.CourseCard] { setup.cards.filter { !$0.decided } }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(pending.isEmpty ? "Tes cours" : "Tu suis ce cours ?")
                    .font(Carnet.serif(.title3, weight: .semibold))
                    .foregroundStyle(Carnet.ink)
                Spacer()
                if !setup.cards.isEmpty {
                    Text("\(setup.cards.count - pending.count) / \(setup.cards.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Carnet.inkTertiary)
                        .contentTransition(.numericText())
                }
            }
            ZStack {
                if setup.cards.isEmpty {
                    waitingCard
                } else {
                    ForEach(Array(pending.prefix(3).enumerated().reversed()), id: \.element.id) { depth, card in
                        cardView(card, depth: depth)
                    }
                }
            }
            .frame(height: 118)
            if let top = pending.first {
                palette(for: top)
                HStack(spacing: 10) {
                    Button { decide(top.id, keep: false) } label: {
                        Label("Ignorer", systemImage: "xmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.carnetSecondaryWide)
                    Button { decide(top.id, keep: true) } label: {
                        Label("Suivre", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.carnetPrimaryWide)
                }
            }
        }
        .onChange(of: pending.isEmpty) { _, empty in
            if empty, !setup.cards.isEmpty { finished() }
        }
    }

    private var waitingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Tes cours arrivent…").font(.subheadline).foregroundStyle(Carnet.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func cardView(_ card: OnboardingAutoSetup.CourseCard, depth: Int) -> some View {
        let isTop = depth == 0
        let offset: CGSize = isTop ? drag : .zero
        let scale: CGFloat = 1 - CGFloat(depth) * 0.05
        let lift: CGFloat = CGFloat(depth) * 10 + offset.height * 0.2
        let angle: Double = Double(offset.width) / 18
        let hint: CourseCardFace.Hint = !isTop ? .none : (drag.width > 30 ? .keep : (drag.width < -30 ? .skip : .none))
        return CourseCardFace(card: card, hint: hint, isTop: isTop)
            .scaleEffect(scale)
            .offset(x: offset.width, y: lift)
            .rotationEffect(.degrees(angle))
            .gesture(dragGesture(card.id), including: isTop ? .all : .none)
            .animation(.spring(duration: 0.45, bounce: 0.25), value: card.colorHex)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(card.code), \(card.name)")
            .accessibilityAction(named: "Suivre") { decide(card.id, keep: true) }
            .accessibilityAction(named: "Ignorer") { decide(card.id, keep: false) }
    }

    private func dragGesture(_ id: String) -> some Gesture {
        DragGesture()
            .onChanged { value in drag = value.translation }
            .onEnded { value in
                let predicted = value.predictedEndTranslation.width
                if predicted > 140 {
                    decide(id, keep: true)
                } else if predicted < -140 {
                    decide(id, keep: false)
                } else {
                    withAnimation(.spring(duration: 0.4, bounce: 0.35)) { drag = .zero }
                }
            }
    }

    private func palette(for card: OnboardingAutoSetup.CourseCard) -> some View {
        HStack(spacing: 10) {
            ForEach(Theme.coursePalette.prefix(8), id: \.self) { hex in
                Button {
                    withAnimation(.snappy) { setup.setColor(hex, for: card.id) }
                    Haptics.soft()
                } label: {
                    Circle()
                        .fill(Carnet.tint(hex))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Carnet.ink, lineWidth: card.colorHex == hex ? 2.5 : 0).padding(-4))
                        .scaleEffect(card.colorHex == hex ? 1.08 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Couleur \(hex)")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func decide(_ id: String, keep: Bool) {
        if keep { Haptics.success() } else { Haptics.removed() }
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) {
            drag = CGSize(width: keep ? 600 : -600, height: -40)
        }
        Task {
            try? await Task.sleep(for: .seconds(0.22))
            if keep { setup.keep(id) } else { setup.skip(id) }
            drag = .zero
        }
    }
}

/// La face d'une carte de cours, à sa couleur.
struct CourseCardFace: View {
    enum Hint { case none, keep, skip }
    let card: OnboardingAutoSetup.CourseCard
    let hint: Hint
    let isTop: Bool

    var body: some View {
        let tint = Carnet.tint(card.colorHex)
        VStack(alignment: .leading, spacing: 6) {
            Text(card.code)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
            Text(card.name)
                .font(Carnet.serif(.title3, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            HStack {
                switch hint {
                case .keep: Label("Suivre", systemImage: "checkmark.circle.fill")
                case .skip: Label("Ignorer", systemImage: "xmark.circle.fill")
                case .none: EmptyView()
                }
                Spacer()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Opaque : une carte translucide laissait lire le nom de celle d'en dessous.
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(tint)
                .overlay(LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.12)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)))
        }
        .shadow(color: tint.opacity(0.35), radius: isTop ? 14 : 4, y: isTop ? 8 : 2)
    }
}

// MARK: - 2. L'objectif

/// Les heures de la semaine sur un cadran : on le tourne du doigt, un cran
/// par heure, et l'anneau se compare à la charge prévue par l'EPFL.
struct GoalDialCard: View {
    var totalCredits: Double
    var weeks: Int
    var confirm: (Double) -> Void

    @State private var hours: Double = 0
    @State private var lastTick = 0

    /// La charge EPFL d'une semaine : ~27,5 h par crédit sur le semestre.
    private var epfl: Double { (totalCredits * 27.5 / Double(max(weeks, 1))).rounded() }
    private let range: ClosedRange<Double> = 8...70

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Ton objectif par semaine")
                    .font(Carnet.serif(.title3, weight: .semibold))
                    .foregroundStyle(Carnet.ink)
                Spacer()
            }
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let fraction = (hours - range.lowerBound) / (range.upperBound - range.lowerBound)
                let epflFraction = (epfl - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack {
                    Circle().trim(from: 0, to: 0.75).stroke(Carnet.rule, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    Circle().trim(from: 0, to: 0.75 * fraction)
                        .stroke(AngularGradient(colors: [Carnet.correct.opacity(0.6), Carnet.correct], center: .center,
                                                startAngle: .degrees(0), endAngle: .degrees(270 * fraction + 1)),
                                style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    // La marque de l'EPFL.
                    Capsule().fill(Carnet.ink).frame(width: 3, height: 22)
                        .offset(y: -side / 2 + 7)
                        .rotationEffect(.degrees(270 * epflFraction + 90))
                    VStack(spacing: 0) {
                        Text("\(Int(hours))")
                            .font(Carnet.serif(.largeTitle, weight: .semibold).monospacedDigit())
                            .contentTransition(.numericText(value: hours))
                        Text("h / semaine").font(.caption).foregroundStyle(Carnet.inkSecondary)
                    }
                    .rotationEffect(.degrees(225))
                }
                .rotationEffect(.degrees(-225))
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    var angle = atan2(value.location.y - center.y, value.location.x - center.x) * 180 / .pi
                    // 0° du cadran = en bas à gauche (135°), sens horaire sur 270°.
                    angle = (angle - 135 + 360).truncatingRemainder(dividingBy: 360)
                    guard angle <= 285 else { return }
                    let f = min(1, max(0, angle / 270))
                    let value = (range.lowerBound + f * (range.upperBound - range.lowerBound)).rounded()
                    if Int(value) != lastTick { lastTick = Int(value); Haptics.soft() }
                    hours = value
                })
            }
            .frame(height: 150)
            HStack {
                Text(hours >= epfl ? "Au niveau de la charge EPFL (\(Int(epfl)) h)" : "La charge EPFL prévoit \(Int(epfl)) h")
                    .font(.footnote)
                    .foregroundStyle(Carnet.inkSecondary)
                Spacer()
                Button("Valider") { confirm(hours) }
                    .buttonStyle(.carnetPrimary)
            }
        }
        .onAppear { if hours == 0 { hours = min(range.upperBound, max(range.lowerBound, epfl)) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Objectif : \(Int(hours)) heures par semaine")
        .accessibilityAdjustableAction { direction in
            hours = min(range.upperBound, max(range.lowerBound, hours + (direction == .increment ? 1 : -1)))
        }
    }
}

// MARK: - 3. Le rappel

/// Le soleil sur un arc, de 6 h à 11 h : on le fait glisser, la notification
/// d'exemple suit.
struct ReminderArcCard: View {
    var confirm: (Int?) -> Void
    @State private var hour = 8

    private let hours = 6...11

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Ton rappel du matin")
                    .font(Carnet.serif(.title3, weight: .semibold))
                    .foregroundStyle(Carnet.ink)
                Spacer()
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height
                let fraction = Double(hour - hours.lowerBound) / Double(hours.upperBound - hours.lowerBound)
                let angle = Double.pi * (1 - fraction)
                let radius = min(width / 2 - 20, height - 16)
                let center = CGPoint(x: width / 2, y: height - 4)
                let sun = CGPoint(x: center.x + cos(angle) * radius, y: center.y - sin(angle) * radius)
                ZStack {
                    Path { path in
                        path.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                    }
                    .stroke(Carnet.inkTertiary.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 7]))
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Carnet.review)
                        .shadow(color: Carnet.review.opacity(0.6), radius: 10)
                        .position(sun)
                        .animation(.spring(duration: 0.35, bounce: 0.3), value: hour)
                    Text("\(hour) h")
                        .font(Carnet.serif(.title, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText(value: Double(hour)))
                        .position(x: center.x, y: center.y - 24)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let f = min(1, max(0, (value.location.x - (center.x - radius)) / (radius * 2)))
                    let next = hours.lowerBound + Int((f * Double(hours.upperBound - hours.lowerBound)).rounded())
                    if next != hour { hour = next; Haptics.soft() }
                })
            }
            .frame(height: 104)
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill").foregroundStyle(Carnet.inkSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("StudyTrack · \(hour):00").font(.caption2.weight(.semibold)).foregroundStyle(Carnet.inkTertiary)
                    Text("Aujourd'hui : la série de la semaine et 2 vidéos.").font(.caption).foregroundStyle(Carnet.ink)
                }
                Spacer()
            }
            .padding(10)
            .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack {
                Button("Pas de rappel") { confirm(nil) }
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
                Spacer()
                Button("Valider") { confirm(hour) }
                    .buttonStyle(.carnetPrimary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
