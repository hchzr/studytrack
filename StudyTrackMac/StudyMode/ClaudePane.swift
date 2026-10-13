import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Claude dans le bureau : une conversation **par série**, gardée d'un
/// lancement à l'autre. Elle connaît la série (PDF joint au début), l'exercice
/// en cours et ses questions cochées ; changer d'exercice reste dans la même
/// conversation. « Post-mortem » et « Rapport » en fin de série ; les verdicts
/// d'un post-mortem ne sont notés qu'une fois confirmés. Par l'abonnement
/// Claude, pas d'une clé d'API.
struct ClaudePane: View {
    let course: Course?
    let courses: [Course]
    var desk: StudyDesk
    /// La fenêtre principale n'a que la conversation « EPFL » (le système).
    var onlySystem = false

    /// La conversation de la série, ou celle du système entier (brief, plan,
    /// revue, synchronisation), quand le fichier du projet a des boutons pour lui.
    enum Scope: String { case series, system }
    /// La « série » de la conversation du système.
    static let systemID = UUID(uuidString: "00000000-0000-0000-0000-0000000E9F10")!

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @State private var draft = ""
    @State private var attachments: [ClaudeTutor.Attachment] = []
    @State private var previews: [NSImage] = []
    @State private var attachSeries = true
    @State private var config: ClaudeChat.Config?
    @State private var scopeChoice: Scope = .series
    /// Le modèle d'une commande préparée (capture, fichier), pour l'envoi.
    @State private var pendingModel: String?
    @FocusState private var focused: Bool

    private var file: ClaudeProject.File? { config?.file }
    private var hasSystem: Bool { !(file?.commands(.system).isEmpty ?? true) }
    private var scope: Scope { onlySystem ? .system : (hasSystem ? scopeChoice : .series) }
    private var chatID: UUID? { scope == .system ? Self.systemID : series?.id }

    private var exercise: Exercise? { course?.allExercises.first { $0.id == timer.targetID } }

    /// La série de la conversation : celle de l'exercice en cours, sinon la
    /// série de la semaine.
    private var series: ExerciseSeries? {
        if let series = exercise?.series { return series }
        let all = course?.sortedSeries.filter { !$0.exercises.isEmpty } ?? []
        let week = course?.currentWeek ?? 0
        return all.first { $0.plannedWeek >= week && !$0.isComplete } ?? all.last
    }

    private var seriesAddress: String? {
        let address = exercise.map { $0.statementURLString.isEmpty ? ($0.series?.urlString ?? "") : $0.statementURLString }
            ?? series?.urlString ?? ""
        return address.isEmpty ? nil : address
    }

    var body: some View {
        Group {
            if let config {
                let chat = desk.chat(series: chatID, config: config)
                VStack(spacing: 0) {
                    header(chat)
                    Rectangle().fill(Carnet.rule).frame(height: 1)
                    if !ClaudeChat.isAvailable {
                        notInstalled
                    } else {
                        conversation(chat)
                    }
                    Rectangle().fill(Carnet.rule).frame(height: 1)
                    composer(chat)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: settingsKey) {
            // Le dossier du projet, son CLAUDE.md, ses compétences : une fois par
            // réglage, pas à chaque rendu.
            config = await ClaudeProjectSetup.config(settings: settings, courses: courses)
        }
        .onChange(of: config) { _, _ in
            takePending()
            #if DEBUG
            // `-claudeAsk "…"` : une vraie question, pour vérifier la chaîne entière.
            if let index = CommandLine.arguments.firstIndex(of: "-claudeAsk"), index + 1 < CommandLine.arguments.count,
               let config, desk.chat(series: chatID, config: config).messages.isEmpty {
                send(CommandLine.arguments[index + 1])
            }
            #endif
        }
        .onChange(of: desk.pendingQuestion) { _, _ in takePending() }
    }

    private var settingsKey: String {
        // Le fichier du projet relu quand il change (sa date).
        let modified = (try? FileManager.default.attributesOfItem(atPath: ClaudeProjectSetup.fileURL(settings: settings).path))?[.modificationDate] as? Date
        return "\(settings.claudeProject)|\(settings.claudeProjectFolder)|\(settings.claudeStudyTrackMCP)|\(modified?.timeIntervalSince1970 ?? 0)"
    }

    private var chat: ClaudeChat? {
        config.map { desk.chat(series: chatID, config: $0) }
    }

    // MARK: En-tête

    private func header(_ chat: ClaudeChat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle").foregroundStyle(Carnet.ink)
                if hasSystem, !onlySystem {
                    Picker("Conversation", selection: $scopeChoice) {
                        Text("Série").tag(Scope.series)
                        Text("EPFL").tag(Scope.system)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(scope == .system ? "EPFL" : (series.map(name) ?? "Claude")).font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
                    if scope == .series, let course { Text(course.displayCode).font(.caption).foregroundStyle(Carnet.inkSecondary) }
                }
                if scope == .series, let series {
                    Menu {
                        ForEach(series.sortedExercises) { item in
                            Button {
                                if let course { timer.retarget(courseID: course.id, taskType: .exercise, targetID: item.id) }
                            } label: {
                                if item.id == timer.targetID { Label(item.displayNumber, systemImage: "checkmark") } else { Text(item.displayNumber) }
                            }
                        }
                    } label: {
                        Text(exercise?.displayNumber ?? "Exercice")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Changer d'exercice")
                }
                Spacer()
                if scope == .series {
                    Picker("Mode", selection: Binding(get: { chat.mode }, set: { chat.mode = $0 })) {
                        ForEach(ClaudeTutor.Mode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
                if let usage = chat.usage {
                    Text("\(Int(usage * 100)) %")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(usage > 0.8 ? Carnet.wrong : Carnet.inkTertiary)
                        .help("Abonnement utilisé (5 h)")
                }
                Menu {
                    Button("Nouvelle conversation", systemImage: "square.and.pencil") { chat.startOver() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Carnet.inkSecondary)
            }
            status(chat)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// Comment tourne Claude : isolé ou projet, ce qu'il peut faire, et ce que
    /// coûte le contexte.
    private func status(_ chat: ClaudeChat) -> some View {
        HStack(spacing: 10) {
            Label(chat.config.profile == .project ? "Projet EPFL" : "Isolé",
                  systemImage: chat.config.profile == .project ? "folder" : "lock")
            Text("·")
            Text("permis : \(chat.config.permissions)")
            if let models = file?.models, let model = scope == .series ? models.tutor : models.system {
                Text("·")
                Text(model)
            }
            if let info = chat.info {
                if scope == .series, let skill = file?.seriesSkill {
                    Text("·")
                    Text(info.hasSkill(skill) ? skill : "sans \(skill)")
                        .foregroundStyle(info.hasSkill(skill) ? Carnet.inkTertiary : Carnet.wrong)
                }
                ForEach(info.mcpServers, id: \.name) { server in
                    Text("·")
                    Text("\(ClaudeTutor.toolLabel("mcp__" + server.name)) \(server.status == "connected" ? "connecté" : "à connecter")")
                        .foregroundStyle(server.status == "connected" ? Carnet.inkTertiary : Carnet.wrong)
                        .help(server.status == "connected" ? "" : "Tape `claude` puis `/mcp` dans le Terminal, dans le dossier du projet")
                }
            }
            if let tokens = chat.contextTokens {
                Text("·")
                Text("contexte \(tokens >= 1000 ? "\(tokens / 1000) k" : "\(tokens)")")
            }
        }
        .font(.caption2)
        .foregroundStyle(Carnet.inkTertiary)
        .lineLimit(1)
    }

    private func name(_ series: ExerciseSeries) -> String {
        series.title.isEmpty ? "Série \(series.seriesNumber)" : series.title
    }

    // MARK: Conversation

    private func conversation(_ chat: ClaudeChat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if chat.messages.isEmpty { welcome }
                    ForEach(chat.messages) { message in
                        MessageView(message: message, thinking: chat.isThinking && message.isStreaming,
                                    tool: message.isStreaming ? chat.activeTool : nil)
                            .id(message.id)
                        if message.role == .claude, !message.isStreaming, let series {
                            let verdicts = ClaudeTutor.verdicts(in: message.text)
                            if !verdicts.isEmpty { VerdictCard(verdicts: verdicts, series: series) }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(22)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(scope == .system ? "On fait quoi ?" : (series == nil ? "Une question ?" : "On attaque ?"))
                .font(Carnet.serif(28)).foregroundStyle(Carnet.ink)
            if scope == .series {
                Text("Joins ta copie GoodNotes, ou une photo prise à l'iPhone (clic droit).")
                    .foregroundStyle(Carnet.inkSecondary)
            }
            FlowChips(spacing: 8) { actionButtons(disabled: false, includeGeneric: true) }
        }
        .padding(.top, 20)
    }

    /// Les boutons : en série, les gestes du tuteur puis ceux du fichier du
    /// projet (ou « Post-mortem » / « Rapport » sans fichier) ; dans la
    /// conversation EPFL, les commandes du système (brief, semaine…).
    @ViewBuilder
    private func actionButtons(disabled: Bool, includeGeneric: Bool) -> some View {
        if scope == .series {
            if includeGeneric {
                ForEach(ClaudeTutor.QuickAction.allCases) { action in
                    Button {
                        // Vérifier une copie, rédiger une solution : il faut de la
                        // rigueur → le modèle « système » ; les indices restent légers.
                        if action == .check || action == .solution {
                            send(action.prompt, model: .some(file?.model(for: nil, scope: .system)))
                        } else {
                            send(action.prompt)
                        }
                    } label: { Label(action.label, systemImage: action.icon) }
                        .buttonStyle(.paper)
                        .disabled(disabled)
                }
            }
            if let commands = file?.commands(.series), !commands.isEmpty {
                ForEach(commands) { command in
                    Button { run(command) } label: { Label(command.label, systemImage: command.icon) }
                        .buttonStyle(.paper)
                        .disabled(disabled)
                }
            } else if let series {
                Button {
                    send(ClaudeTutor.postMortemPrompt(useSkill: usesSkill), label: "Post-mortem",
                         model: file?.model(for: nil, scope: .system))
                } label: { Label("Post-mortem", systemImage: "checklist") }
                    .buttonStyle(.paper)
                    .disabled(disabled || series.doneCount == 0)
                Button { send(ClaudeTutor.reportPrompt, label: "Rapport", model: file?.model(for: nil, scope: .system)) } label: {
                    Label("Rapport", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.paper)
                .disabled(disabled)
            }
        } else {
            ForEach(file?.commands(.system) ?? []) { command in
                Button { run(command) } label: { Label(command.label, systemImage: command.icon) }
                    .buttonStyle(.paper)
                    .disabled(disabled)
            }
        }
    }

    /// Les valeurs d'une commande du fichier : le cours, la série, l'exercice.
    private var placeholders: ClaudeProject.Placeholders {
        ClaudeProject.Placeholders(code: course?.displayCode ?? "", course: course.map { ClaudeProject.shortCourseName($0.name) } ?? "",
                                   seriesNumber: series.map { "\($0.seriesNumber)" } ?? "", seriesTitle: series.map(name) ?? "",
                                   exercise: exercise?.exerciseNumber ?? "")
    }

    private func run(_ command: ClaudeProject.File.Command) {
        var prompt = ClaudeProject.expand(command.prompt, placeholders)
        if command.verdicts == true { prompt += "\n\n" + ClaudeTutor.verdictInstruction }
        let model = file?.model(for: command, scope: command.scope)
        if command.capture == true || command.attach == true {
            // D'abord la copie ou le fichier ; l'envoi reste à l'étudiant·e.
            draft = prompt
            pendingModel = model
            if command.capture == true { capture() } else { pick() }
            return
        }
        send(prompt, label: command.label, model: model)
    }

    private var notInstalled: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal").font(.largeTitle).foregroundStyle(Carnet.inkSecondary)
            Text("Connecte Claude").font(Carnet.serif(.title2)).foregroundStyle(Carnet.ink)
            Text("Installe Claude Code, puis tape `claude` une fois dans le Terminal.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Carnet.inkSecondary)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Saisie

    private func composer(_ chat: ClaudeChat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !chat.messages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { actionButtons(disabled: chat.isAnswering, includeGeneric: true) }
                }
            }
            if !attachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                        HStack(spacing: 6) {
                            if index < previews.count {
                                Image(nsImage: previews[index]).resizable().scaledToFill().frame(width: 34, height: 34)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            } else {
                                Image(systemName: "doc.richtext")
                            }
                            Text(attachment.name).font(.caption).lineLimit(1)
                            Button {
                                attachments.remove(at: index)
                                if index < previews.count { previews.remove(at: index) }
                            } label: { Image(systemName: "xmark").font(.caption2) }
                            .buttonStyle(.plain)
                        }
                        .padding(6)
                        .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    if let copy = currentCopy {
                        Button("Ma copie : \(copy.title)", systemImage: "pencil.and.scribble") { attach(copy) }
                    }
                    Button("Joindre un fichier…", systemImage: "paperclip", action: pick)
                    Divider()
                    Toggle("Joindre la série", isOn: $attachSeries)
                } label: {
                    Image(systemName: "plus.circle").font(.title2)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Carnet.inkSecondary)
                if let copy = currentCopy {
                    Button { attach(copy) } label: { Image(systemName: "pencil.and.scribble").font(.title3) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Carnet.inkSecondary)
                        .help("Joindre ta copie (\(copy.title))")
                }
                TextField(scope == .system ? "Ta demande" : (chat.mode == .tutor ? "Où tu bloques ?" : "Ta question"), text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(10)
                    .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Carnet.rule))
                    .onSubmit { send(draft) }
                if chat.isAnswering {
                    Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.title) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Carnet.ink)
                        .help("Arrêter")
                } else {
                    Button { send(draft) } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .buttonStyle(.plain)
                        .foregroundStyle(draft.isEmpty && attachments.isEmpty ? Carnet.inkTertiary : Carnet.ink)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(draft.isEmpty && attachments.isEmpty)
                }
            }
        }
        .padding(14)
        .background(Carnet.ground)
        .onDrop(of: [.image, .pdf, .fileURL], isTargeted: nil) { providers in
            drop(providers)
            return true
        }
        .onPasteCommand(of: [.image, .png, .tiff]) { providers in drop(providers) }
        // Continuity Camera : clic droit › « Prendre une photo » / « Numériser
        // des documents » avec l'iPhone, sans quitter le mode étude.
        .importsItemProviders([.image, .pdf]) { providers in
            drop(providers)
            return true
        }
        .task { await NotesStore.shared.refresh() }
    }

    // MARK: Gestes

    private func takePending() {
        guard config != nil, let question = desk.pendingQuestion else { return }
        attachSeries = desk.pendingAttachSeries
        desk.pendingQuestion = nil
        if let attachment = desk.pendingAttachment {
            // « Vérifier ma copie » : ta copie GoodNotes part avec la question.
            desk.pendingAttachment = nil
            attachments.append(attachment)
            send(question)
        } else if question == ClaudeTutor.QuickAction.check.prompt {
            // Pas de copie trouvée dans tes notes : on te laisse la joindre.
            draft = question
            pick()
        } else {
            send(question)
        }
    }

    /// La compétence de série du fichier du projet, si elle est là.
    private var seriesSkill: String? {
        guard let chat, chat.config.profile == .project, let skill = file?.seriesSkill else { return nil }
        let loaded = chat.info?.hasSkill(skill) ?? ClaudeProjectSetup.linkedSkills(settings: settings).contains(skill)
        return loaded ? skill : nil
    }

    private var usesSkill: Bool { seriesSkill != nil }

    /// - Parameter model: `nil` → le modèle par défaut de la conversation
    ///   (`tutor` en série, `system` dans la conversation EPFL).
    private func send(_ text: String, label: String? = nil, model: String?? = nil) {
        guard let chat else { return }
        var files = attachments
        var pdfAttached = false
        if scope == .series, attachSeries, !chat.opened, let address = seriesAddress,
           case .ready(let url)? = desk.document(address), let data = try? Data(contentsOf: url) {
            files.insert(.init(kind: .pdf, data: data, name: series.map(name) ?? "Série"), at: 0)
            pdfAttached = true
        }
        let situation = scope == .series
            ? ClaudeChat.Situation(series: series.map { seriesContext($0, pdfAttached: pdfAttached) },
                                   exerciseID: exercise?.id, exercise: context, skill: seriesSkill)
            : ClaudeChat.Situation(series: nil, exerciseID: nil, exercise: ClaudeTutor.Context(), skill: nil)
        let chosen: String? = model ?? pendingModel ?? file?.model(for: nil, scope: scope == .series ? .series : .system)
        chat.send(text, label: label, attachments: files, images: previews, model: chosen, situation: situation)
        draft = ""
        attachments = []
        previews = []
        pendingModel = nil
    }

    private func seriesContext(_ series: ExerciseSeries, pdfAttached: Bool) -> ClaudeTutor.SeriesContext {
        ClaudeTutor.SeriesContext(
            courseCode: course?.displayCode, courseName: course?.name, title: name(series),
            week: series.plannedWeek > 0 ? series.plannedWeek : nil,
            due: series.dueDate.map { $0.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_CH"))) },
            exercises: series.sortedExercises.map { item in
                let status = item.correctness.map { $0.label.lowercased() } ?? (item.isDone ? "fait" : "à faire")
                return .init(number: item.exerciseNumber, title: item.title, status: status + (item.isBonus ? " (bonus)" : ""))
            },
            pdfAttached: pdfAttached)
    }

    private var context: ClaudeTutor.Context {
        let questions = exercise?.leafSubQuestions.map { "\($0.path) \($0.text)\($0.isDone ? " (fait)" : "")" } ?? []
        return ClaudeTutor.Context(courseCode: course?.displayCode, courseName: course?.name,
                                   exercise: exercise.map { "\($0.series.map { "Série \($0.seriesNumber) · " } ?? "")\($0.displayNumber)" },
                                   statement: exercise?.statement, questions: questions,
                                   doneQuestions: exercise?.subQuestionDoneCount ?? 0,
                                   correction: exercise?.correctness?.label, hint: exercise?.hint.isEmpty == false ? exercise?.hint : nil)
    }

    /// Ta copie de la série en cours, dans tes notes.
    private var currentCopy: NotesLibrary.Document? {
        guard scope == .series, let series, let course else { return nil }
        return NotesStore.shared.copy(for: series, course: course, among: courses)
    }

    private func attach(_ copy: NotesLibrary.Document) {
        guard let data = NotesStore.shared.attachmentData(copy) else { return }
        attachments.append(.init(kind: .pdf, data: data, name: copy.title))
        focused = true
    }

    /// La capture interactive du système (un viseur, comme ⇧⌘4).
    private func capture() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("studytrack-capture-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", file.path]
        process.terminationHandler = { _ in
            Task { @MainActor in
                guard let data = try? Data(contentsOf: file), let image = NSImage(data: data) else { return }
                attachments.append(.init(kind: .image(mime: "image/png"), data: data, name: "Capture"))
                previews.append(image)
                focused = true
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        try? process.run()
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(url) }
    }

    private func add(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        if url.pathExtension.lowercased() == "pdf" {
            attachments.append(.init(kind: .pdf, data: data, name: url.lastPathComponent))
        } else if let image = NSImage(data: data), let png = image.pngData {
            attachments.append(.init(kind: .image(mime: "image/png"), data: png, name: url.lastPathComponent))
            previews.append(image)
        }
    }

    private func drop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add(url) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage, let png = image.pngData else { return }
                    Task { @MainActor in
                        attachments.append(.init(kind: .image(mime: "image/png"), data: png, name: "Image"))
                        previews.append(image)
                    }
                }
            }
        }
    }
}

private struct MessageView: View {
    let message: ClaudeChat.Message
    let thinking: Bool
    var tool: String?

    var body: some View {
        switch message.role {
        case .student:
            VStack(alignment: .trailing, spacing: 6) {
                if !message.images.isEmpty {
                    HStack {
                        ForEach(Array(message.images.enumerated()), id: \.offset) { _, image in
                            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                if !message.attachments.isEmpty {
                    Label(message.attachments.joined(separator: ", "), systemImage: "paperclip")
                        .font(.caption).foregroundStyle(Carnet.inkSecondary)
                }
                if let label = message.label {
                    Label(label, systemImage: "checklist")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Carnet.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else if !message.text.isEmpty {
                    Text(message.text)
                        .foregroundStyle(Carnet.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .claude:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkle")
                    .foregroundStyle(Carnet.ink)
                    .frame(width: 26, height: 26)
                    .background(Carnet.sheetRaised, in: Circle())
                VStack(alignment: .leading, spacing: 8) {
                    if let error = message.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Carnet.wrong)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if message.text.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(tool.map { "\($0)…" } ?? (thinking ? "Claude réfléchit…" : "…")).foregroundStyle(Carnet.inkSecondary)
                        }
                    } else {
                        RichTextView(text: ClaudeTutor.withoutVerdicts(message.text), size: 14.5)
                        if let tool, message.isStreaming {
                            Label("\(tool)…", systemImage: "wrench.and.screwdriver").font(.caption).foregroundStyle(Carnet.inkTertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Les verdicts d'un post-mortem : rien n'est noté sans un clic.
private struct VerdictCard: View {
    let verdicts: [ClaudeTutor.Verdict]
    let series: ExerciseSeries
    @State private var applied: Set<String> = []

    private var rows: [(verdict: ClaudeTutor.Verdict, exercise: Exercise?)] {
        let exercises = series.sortedExercises
        let numbers = exercises.map(\.exerciseNumber)
        return verdicts.map { verdict in
            (verdict, ClaudeTutor.matchExercise(verdict.exercise, numbers: numbers).map { exercises[$0] })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Kicker("À noter dans StudyTrack")
                Spacer()
                let pending = rows.filter { $0.exercise != nil && !applied.contains($0.verdict.exercise) }
                if pending.count > 1 {
                    Button("Tout noter") { for row in pending { apply(row.verdict, to: row.exercise!) } }
                        .buttonStyle(.ink)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    Text(row.exercise?.displayNumber ?? "Exercice \(row.verdict.exercise)")
                        .foregroundStyle(row.exercise == nil ? Carnet.inkTertiary : Carnet.ink)
                    Spacer()
                    Text(row.verdict.result.shortLabel)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Carnet.color(for: row.verdict.result).opacity(0.14)))
                        .foregroundStyle(Carnet.color(for: row.verdict.result))
                    if let exercise = row.exercise {
                        if applied.contains(row.verdict.exercise) || exercise.correctness == row.verdict.result {
                            Image(systemName: "checkmark").foregroundStyle(Carnet.inkSecondary)
                        } else {
                            Button("Noter") { apply(row.verdict, to: exercise) }.buttonStyle(.paper)
                        }
                    } else {
                        Text("introuvable").font(.caption).foregroundStyle(Carnet.inkTertiary)
                    }
                }
            }
        }
        .paperSheet(padding: 14)
        .padding(.leading, 38)
    }

    private func apply(_ verdict: ClaudeTutor.Verdict, to exercise: Exercise) {
        exercise.correct(verdict.result)
        applied.insert(verdict.exercise)
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
