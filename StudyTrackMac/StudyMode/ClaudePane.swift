import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Claude dans le bureau : une conversation **par exercice**, qui connaît
/// l'énoncé, les questions cochées, la série (PDF joint), et à qui l'on montre
/// sa copie d'une capture d'écran (une page de GoodNotes). Par l'abonnement
/// Claude, pas d'une clé d'API.
struct ClaudePane: View {
    let course: Course?
    var desk: StudyDesk

    @Environment(MacTimer.self) private var timer
    @State private var draft = ""
    @State private var attachments: [ClaudeTutor.Attachment] = []
    @State private var previews: [NSImage] = []
    @State private var attachSeries = true
    @FocusState private var focused: Bool

    private var exercise: Exercise? { course?.allExercises.first { $0.id == timer.targetID } }
    private var chat: ClaudeChat { desk.chat(for: timer.targetID) }
    private var seriesAddress: String? {
        guard let exercise else { return nil }
        let address = exercise.statementURLString.isEmpty ? (exercise.series?.urlString ?? "") : exercise.statementURLString
        return address.isEmpty ? nil : address
    }

    var body: some View {
        let chat = self.chat
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
        .onAppear {
            takePending()
            #if DEBUG
            // `-claudeAsk "…"` : une vraie question, pour vérifier la chaîne entière.
            if let index = CommandLine.arguments.firstIndex(of: "-claudeAsk"), index + 1 < CommandLine.arguments.count,
               self.chat.messages.isEmpty {
                send(CommandLine.arguments[index + 1])
            }
            #endif
        }
        .onChange(of: desk.pendingQuestion) { _, _ in takePending() }
    }

    // MARK: En-tête

    private func header(_ chat: ClaudeChat) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle").foregroundStyle(Carnet.ink)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude").font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
                Text(exercise.map { "sur \($0.displayNumber)\(course.map { " · \($0.displayCode)" } ?? "")" } ?? "conversation libre")
                    .font(.caption).foregroundStyle(Carnet.inkSecondary)
            }
            Spacer()
            Picker("Mode", selection: Binding(get: { chat.mode }, set: { chat.mode = $0 })) {
                ForEach(ClaudeTutor.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            .help("Tuteur : des indices, jamais la solution d'emblée. Explications : tout, solutions comprises.")
            if let usage = chat.usage {
                Text("abonnement \(Int(usage * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(usage > 0.8 ? Carnet.wrong : Carnet.inkTertiary)
                    .help("La part utilisée de la fenêtre de 5 h de ton abonnement Claude")
            }
            Button {
                desk.resetChat(for: timer.targetID)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Carnet.inkSecondary)
            .help("Nouvelle conversation")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: Conversation

    private func conversation(_ chat: ClaudeChat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if chat.messages.isEmpty { welcome }
                    ForEach(chat.messages) { message in
                        MessageView(message: message, thinking: chat.isThinking && message.isStreaming)
                            .id(message.id)
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
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(exercise == nil ? "Une question ?" : "On regarde \(exercise!.displayNumber) ensemble ?")
                .font(Carnet.serif(28)).foregroundStyle(Carnet.ink)
            Text("Claude connaît l'exercice en cours, ses questions et la série. En mode tuteur, il donne des indices, pas la solution. Montre-lui ta copie : « Capturer » prend une zone de l'écran (une page de GoodNotes).")
                .foregroundStyle(Carnet.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            FlowChips(spacing: 8) {
                ForEach(ClaudeTutor.QuickAction.allCases) { action in
                    Button { send(action.prompt) } label: { Label(action.label, systemImage: action.icon) }
                        .buttonStyle(.paper)
                }
            }
        }
        .padding(.top, 20)
    }

    private var notInstalled: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal").font(.largeTitle).foregroundStyle(Carnet.inkSecondary)
            Text("Claude passe par ton abonnement").font(Carnet.serif(.title2)).foregroundStyle(Carnet.ink)
            Text("Installe Claude Code (claude.com/code), puis tape `claude` une fois dans le Terminal pour te connecter avec ton compte Claude. StudyTrack s'en sert ensuite, sans clé d'API.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Carnet.inkSecondary)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Saisie

    private func composer(_ chat: ClaudeChat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !chat.messages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ClaudeTutor.QuickAction.allCases) { action in
                            Button { send(action.prompt) } label: { Label(action.label, systemImage: action.icon) }
                                .buttonStyle(.paper)
                                .disabled(chat.isAnswering)
                        }
                    }
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
                    Button("Capturer une zone de l'écran", systemImage: "camera.viewfinder", action: capture)
                    Button("Joindre une image ou un PDF…", systemImage: "paperclip", action: pick)
                    Divider()
                    Toggle("Joindre la série (PDF) au premier message", isOn: $attachSeries)
                } label: {
                    Image(systemName: "plus.circle").font(.title2)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Carnet.inkSecondary)
                Button(action: capture) { Image(systemName: "camera.viewfinder").font(.title3) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Carnet.inkSecondary)
                    .help("Capturer ta copie (une page de GoodNotes) et la montrer à Claude")
                TextField(chat.mode == .tutor ? "Ta question, ou où tu bloques…" : "Ta question…", text: $draft, axis: .vertical)
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
    }

    // MARK: Gestes

    private func takePending() {
        guard let question = desk.pendingQuestion else { return }
        attachSeries = desk.pendingAttachSeries
        desk.pendingQuestion = nil
        if question == ClaudeTutor.QuickAction.check.prompt {
            // Vérifier : d'abord la copie.
            draft = question
            capture()
        } else {
            send(question)
        }
    }

    private func send(_ text: String) {
        let chat = self.chat
        var files = attachments
        if attachSeries, chat.messages.isEmpty, let address = seriesAddress,
           case .ready(let url)? = desk.document(address), let data = try? Data(contentsOf: url) {
            files.insert(.init(kind: .pdf, data: data, name: exercise?.series.map { $0.title.isEmpty ? "Série \($0.seriesNumber)" : $0.title } ?? "Série"), at: 0)
        }
        chat.send(text, attachments: files, images: previews, context: context)
        draft = ""
        attachments = []
        previews = []
    }

    private var context: ClaudeTutor.Context {
        let questions = exercise?.leafSubQuestions.map { "\($0.path) \($0.text)\($0.isDone ? " (fait)" : "")" } ?? []
        return ClaudeTutor.Context(courseCode: course?.displayCode, courseName: course?.name,
                                   exercise: exercise.map { "\($0.series.map { "Série \($0.seriesNumber) · " } ?? "")\($0.displayNumber)" },
                                   statement: exercise?.statement, questions: questions,
                                   doneQuestions: exercise?.subQuestionDoneCount ?? 0,
                                   correction: exercise?.correctness?.label, hint: nil)
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
                if !message.text.isEmpty {
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
                            Text(thinking ? "Claude réfléchit…" : "…").foregroundStyle(Carnet.inkSecondary)
                        }
                    } else {
                        RichTextView(text: message.text, size: 14.5)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
