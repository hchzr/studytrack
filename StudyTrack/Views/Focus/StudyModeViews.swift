import SwiftUI
import SwiftData
#if canImport(FamilyControls)
import FamilyControls
#endif

// MARK: - Entrer en mode étude

/// Dans le chrono : « Mode étude » et sa durée. Lance (ou verrouille) la
/// session ; le Mac suit, et se ferme au reste lui aussi.
struct StudyModeEntry: View {
    var courseID: UUID?
    var taskType: TaskType
    var targetID: UUID?

    @Environment(AppContainer.self) private var app
    @State private var showingSetup = false
    @State private var showingCustom = false
    /// Bloquer le reste (apps, sites) pendant le mode étude. Retenu d'une fois sur l'autre.
    @AppStorage("studyMode.blocking") private var blocking = true

    var body: some View {
        if app.focus.isStudying {
            Button {
                app.router.showingStudyMode = true
            } label: {
                Label("Mode étude", systemImage: "moon.stars.fill")
            }
            .buttonStyle(.carnetSecondaryWide)
        } else {
            Menu {
                Section("Mode étude") {
                    ForEach(StudyMode.durations, id: \.self) { minutes in
                        Button(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h\(minutes % 60 == 0 ? "" : " \(minutes % 60)")") {
                            enter(minutes)
                        }
                    }
                    Button("Autre durée…", systemImage: "clock") { showingCustom = true }
                }
                Toggle("Bloquer le reste", isOn: $blocking)
                if blocking, !StudyLock.shared.isAuthorized {
                    Button("Réglages", systemImage: "gearshape") { showingSetup = true }
                }
            } label: {
                Label("Mode étude", systemImage: "moon.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.carnetSecondaryWide)
            .sheet(isPresented: $showingSetup) {
                NavigationStack { StudyModeSettingsView() }
            }
            .sheet(isPresented: $showingCustom) {
                StudyCustomDuration { minutes in
                    showingCustom = false
                    enter(minutes)
                }
                .presentationDetents([.height(320)])
            }
        }
    }

    private func enter(_ minutes: Int) {
        app.focus.enterStudy(minutes: minutes, courseID: courseID, taskType: taskType, targetID: targetID, locks: blocking)
        app.router.showingStudyMode = true
        if blocking, !StudyLock.shared.isAuthorized { showingSetup = true }
    }
}

// MARK: - L'écran plein

/// L'écran du mode étude sur l'iPhone : le temps qui reste, ce qu'on fait,
/// les outils permis. Papier de nuit, comme sur le Mac.
struct StudyModeScreen: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]
    @State private var browsing: BrowsedLink?
    @State private var holding = false
    @State private var holdProgress: Double = 0
    @Environment(\.openURL) private var openURL

    private var focus: FocusController { app.focus }
    private var course: Course? { courses.first { $0.id == focus.state?.courseID } }
    private var tint: Color { course.map { Carnet.tint($0.colorHex) } ?? Carnet.ink }

    var body: some View {
        ZStack {
            Carnet.ground.ignoresSafeArea()
            RadialGradient(colors: [tint.opacity(0.18), .clear], center: .top, startRadius: 20, endRadius: 520)
                .ignoresSafeArea()
            if focus.studyIsOver {
                done
            } else {
                session
            }
        }
        .environment(\.colorScheme, .dark)
        .sheet(item: $browsing) { InAppBrowser(link: $0) }
    }

    private var session: some View {
        ScrollView {
            VStack(spacing: 26) {
                HStack {
                    Label("Mode étude", systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(1.1)
                        .foregroundStyle(Carnet.inkSecondary)
                    Spacer()
                    Button { app.router.showingStudyMode = false } label: {
                        Image(systemName: "chevron.down").font(.headline)
                    }
                    .foregroundStyle(Carnet.inkSecondary)
                    .accessibilityLabel("Réduire")
                }
                TimelineView(.periodic(from: (focus.state?.studyUntil ?? .now).addingTimeInterval(0.05), by: 1)) { context in
                    let remaining = StudyMode.remaining(focus.state, at: context.date)
                    ZStack {
                        Circle().stroke(Carnet.rule, lineWidth: 5)
                        Circle()
                            .trim(from: 0, to: max(0.001, StudyMode.progress(focus.state, at: context.date)))
                            .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 6) {
                            Text("reste")
                                .font(.caption.weight(.semibold)).textCase(.uppercase).tracking(1.1)
                                .foregroundStyle(tint)
                            Text(TimerText.clock(remaining.rounded(.up)))
                                .font(.system(size: 64, weight: .regular, design: .serif))
                                .monospacedDigit()
                                .foregroundStyle(Carnet.ink)
                            Text("jusqu'à \(DateUtils.time.string(from: focus.state?.studyUntil ?? context.date))")
                                .font(.footnote)
                                .foregroundStyle(Carnet.inkSecondary)
                        }
                    }
                    .frame(width: 270, height: 270)
                }

                VStack(spacing: 4) {
                    if let course {
                        Text(course.displayCode).font(.caption.weight(.semibold)).foregroundStyle(tint)
                    }
                    Text(headline)
                        .font(Carnet.serif(.title2))
                        .foregroundStyle(Carnet.ink)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 14) {
                    Button {
                        if focus.isRunning { focus.pause() } else { focus.resume() }
                    } label: {
                        Image(systemName: focus.isRunning ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 64, height: 64)
                            .background(Carnet.ink, in: Circle())
                            .foregroundStyle(Carnet.ground)
                    }
                    .accessibilityLabel(focus.isRunning ? "Pause" : "Reprendre")
                    Button { focus.extendStudy(minutes: 25) } label: {
                        Label("25 min", systemImage: "plus")
                    }
                    .buttonStyle(.carnetSecondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Tes outils").font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
                    ForEach(tools) { tool in
                        Button { open(tool) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: tool.icon)
                                    .font(.body.weight(.medium))
                                    .frame(width: 40, height: 40)
                                    .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tool.title).foregroundStyle(Carnet.ink)
                                    Text(tool.subtitle).font(.caption).foregroundStyle(Carnet.inkSecondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Carnet.inkTertiary)
                            }
                            .padding(10)
                            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Carnet.ink)
                    }
                }

                if !StudyLock.shared.isAuthorized {
                    NavigationLink {
                        StudyModeSettingsView()
                    } label: {
                        Label("Blocage pas activé", systemImage: "exclamationmark.lock")
                            .font(.footnote)
                    }
                    .foregroundStyle(Carnet.review)
                }

                holdToFinish
                    .padding(.top, 6)
            }
            .padding(24)
        }
    }

    /// Tenir pour terminer : une seconde et demie pour y penser.
    private var holdToFinish: some View {
        Text(holding ? "Maintiens…" : "Maintiens pour finir")
            .font(.body.weight(.semibold))
            .foregroundStyle(Carnet.ink)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Carnet.sheetRaised)
                        Capsule().fill(Carnet.correct.opacity(0.55)).frame(width: proxy.size.width * holdProgress)
                    }
                }
            }
            .clipShape(Capsule())
            .onLongPressGesture(minimumDuration: 1.5) {
                holdProgress = 0
                focus.finish()
                app.router.showingStudyMode = false
            } onPressingChanged: { pressing in
                holding = pressing
                withAnimation(pressing ? .linear(duration: 1.5) : .easeOut(duration: 0.2)) { holdProgress = pressing ? 1 : 0 }
            }
            .accessibilityLabel("Terminer la session")
            .accessibilityAddTraits(.isButton)
    }

    private var done: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal").font(.system(size: 44, weight: .light)).foregroundStyle(Carnet.correct)
            Text("C'est fait.").font(.system(size: 48, design: .serif)).foregroundStyle(Carnet.ink)
            Text("Tout est rouvert.").foregroundStyle(Carnet.inkSecondary)
            Button {
                focus.finish()
                app.router.showingStudyMode = false
            } label: { Text("Terminer").frame(maxWidth: .infinity) }
                .buttonStyle(.carnetPrimaryWide)
            Button { focus.extendStudy(minutes: 25) } label: { Text("Encore 25 min").frame(maxWidth: .infinity) }
                .buttonStyle(.carnetSecondaryWide)
            Button("Continuer sans") {
                focus.leaveStudy()
                app.router.showingStudyMode = false
            }
            .foregroundStyle(Carnet.inkSecondary)
        }
        .padding(32)
    }

    private var headline: String {
        let target = FocusController.target(of: focus.state?.targetID, in: course)
        return target.exercise?.displayNumber ?? target.theoryItem?.displayNumber
            ?? (course == nil ? "Session libre" : (focus.state?.taskType.label ?? ""))
    }

    private var tools: [StudyMode.Tool] {
        var links: [String] = []
        if let course { links = [course.moodleURLString] + course.contentSources }
        return StudyMode.tools(courseName: course?.name, courseLinks: links)
    }

    private func open(_ tool: StudyMode.Tool) {
        switch tool.kind {
        case .web(let url):
            browsing = BrowsedLink(title: tool.title, url: url, icon: tool.icon)
        case .app(_, let scheme):
            if let url = URL(string: scheme) { openURL(url) }
        }
    }
}

// MARK: - Réglages

/// Configurer le blocage de l'iPhone : l'autorisation du Temps d'écran, les
/// apps permises, les sites permis (les mêmes que sur le Mac).
struct StudyModeSettingsView: View {
    @State private var lock = StudyLock.shared
    @State private var showingPicker = false
    @State private var newSite = ""
    /// Copie locale : la liste vit dans iCloud clé-valeur, qui n'est pas observé.
    @State private var sites: [String] = []

    var body: some View {
        Form {
            Section {
                if lock.isAuthorized {
                    Label("Autorisé", systemImage: "checkmark.shield")
                        .foregroundStyle(Carnet.correct)
                } else {
                    Button {
                        Task { await lock.requestAuthorization() }
                    } label: {
                        Label("Autoriser", systemImage: "lock.shield")
                    }
                    if let error = lock.lastError {
                        Text(error).font(.footnote).foregroundStyle(Carnet.wrong)
                    }
                }
            } header: {
                CarnetFormHeader("Temps d'écran")
            } footer: {
                Text("Seulement tes apps et sites de cours, jusqu'à la fin.")
            }

            Section {
                #if canImport(FamilyControls)
                Button {
                    showingPicker = true
                } label: {
                    LabeledContent("Apps permises", value: lock.allowedAppCount == 0 ? "aucune" : "\(lock.allowedAppCount)")
                }
                .disabled(!lock.isAuthorized)
                .familyActivityPicker(isPresented: $showingPicker, selection: $lock.selection)
                #endif
            } header: {
                CarnetFormHeader("Apps")
            } footer: {
                Text("Par exemple GoodNotes, Claude et Safari.")
            }

            Section {
                ForEach(sites, id: \.self) { site in
                    Text(site)
                }
                .onDelete { offsets in
                    sites.remove(atOffsets: offsets)
                    lock.sites = sites
                }
                HStack {
                    TextField("Ajouter un site", text: $newSite)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onSubmit(addSite)
                    Button("Ajouter", action: addSite).disabled(StudyMode.normalizedDomain(newSite) == nil)
                }
            } header: {
                CarnetFormHeader("Sites permis")
            } footer: {
                Text("« epfl.ch » ouvre aussi Moodle, Botafogo…")
            }
        }
        .carnetForm()
        .navigationTitle("Mode étude")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { sites = lock.sites }
    }

    private func addSite() {
        guard let domain = StudyMode.normalizedDomain(newSite) else { return }
        if !sites.contains(domain) {
            sites.append(domain)
            lock.sites = sites
        }
        newSite = ""
    }
}

/// Une durée choisie à la main : en minutes, ou jusqu'à une heure.
private struct StudyCustomDuration: View {
    var start: (Int) -> Void
    @State private var minutes = 75
    @State private var byEnd = false
    @State private var end = Date().addingTimeInterval(75 * 60)

    var body: some View {
        NavigationStack {
            Form {
                Picker("Choisir", selection: $byEnd) {
                    Text("Durée").tag(false)
                    Text("Heure de fin").tag(true)
                }
                .pickerStyle(.segmented)
                if byEnd {
                    DatePicker("Jusqu'à", selection: $end, displayedComponents: .hourAndMinute)
                } else {
                    Stepper("\(minutes) min", value: $minutes, in: StudyMode.minuteRange, step: 5)
                }
            }
            .navigationTitle("Mode étude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Commencer") { start(byEnd ? StudyMode.minutes(until: end) : minutes) }
                }
            }
        }
    }
}
