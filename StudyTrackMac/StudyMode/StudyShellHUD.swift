import AppKit
import Carbon.HIToolbox
import SwiftData
import SwiftUI

// MARK: - Raccourcis globaux

/// Plusieurs raccourcis globaux (Carbon `RegisterEventHotKey`, sans autorisation),
/// un seul gestionnaire. Pendant un blocage, ⌘Tab et ⌘Espace du système sont
/// éteints (`SystemLock`) : ce sont les nôtres qui répondent, d'où qu'on soit.
@MainActor
final class StudyHotKeys {
    static let shared = StudyHotKeys()

    private var references: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private var next: UInt32 = 1

    @discardableResult
    func register(key: Int, modifiers: Int, action: @escaping () -> Void) -> UInt32? {
        installHandler()
        let id = next
        next += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: OSType(0x53544F53), id: id),
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return nil }
        references[id] = reference
        actions[id] = action
        return id
    }

    func unregister(_ id: UInt32?) {
        guard let id, let reference = references.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(reference)
        actions[id] = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard identifier.signature == OSType(0x53544F53) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { StudyHotKeys.shared.actions[identifier.id]?() }
            return noErr
        }, 1, &type, nil, &handler)
    }
}

// MARK: - Le système d'étude

/// ⌘Tab et ⌘Espace du bureau d'étude : ce que le blocage a retiré du système
/// revient, au même raccourci, en version d'étude.
@MainActor
final class StudyShell {
    static let shared = StudyShell()

    struct Entry: Identifiable {
        let id: String
        var title: String
        var icon: String
        var bundleID: String?
        var action: () -> Void
    }

    @MainActor @Observable
    final class SwitcherState {
        var entries: [Entry] = []
        var selected = 0
    }

    let switcher = SwitcherState()
    private var model = StudySwitcherModel()
    private var keys: [UInt32] = []
    private var escape: UInt32?
    private var switcherPanel: HUDPanel?
    private var searchPanel: HUDPanel?
    private var poll: Timer?

    var controller: StudyModeController { .shared }

    // MARK: Cycle de vie

    func engage() {
        guard keys.isEmpty else { return }
        let hot = StudyHotKeys.shared
        let cmd = cmdKey, shift = shiftKey, option = optionKey
        keys = [
            hot.register(key: kVK_Tab, modifiers: cmd) { [weak self] in self?.advanceSwitcher(by: 1) },
            hot.register(key: kVK_Tab, modifiers: cmd | shift) { [weak self] in self?.advanceSwitcher(by: -1) },
            hot.register(key: kVK_Space, modifiers: cmd) { [weak self] in self?.showSearch() },
            hot.register(key: kVK_Space, modifiers: cmd | option) { [weak self] in self?.showSearch() },
        ].compactMap { $0 }
    }

    func disengage() {
        for key in keys { StudyHotKeys.shared.unregister(key) }
        keys = []
        hideSwitcher(commit: false)
        hideSearch()
    }

    // MARK: Sélecteur (⌘Tab)

    private var currentID: String {
        if NSApp.isActive { return "pane:\(controller.desk.pane.rawValue)" }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map { "app:\($0)" } ?? "pane:desk"
    }

    private func entries() -> [Entry] {
        let desk = controller.desk
        var all: [Entry] = StudyDesk.Pane.allCases.map { pane in
            Entry(id: "pane:\(pane.rawValue)", title: pane.title, icon: pane.icon, bundleID: nil) { [weak self] in
                desk.pane = pane
                self?.controller.present()
            }
        }
        all.append(Entry(id: "claude", title: "Claude", icon: "sparkle", bundleID: nil) { [weak self] in
            desk.showClaude()
            self?.controller.present()
        })
        for bundleID in controller.settings?.studyApps ?? [] where bundleID != StudyMode.finderBundleID
            && StudyModeController.isInstalled(bundleID) {
            all.append(Entry(id: "app:\(bundleID)", title: StudyModeController.name(for: bundleID), icon: "app",
                             bundleID: bundleID) { [weak self] in self?.controller.openApp(bundleID: bundleID) })
        }
        let ordered = model.order(available: all.map(\.id))
        return ordered.compactMap { id in all.first { $0.id == id } }
    }

    private func advanceSwitcher(by step: Int) {
        if switcherPanel?.isVisible != true {
            model.touch(currentID)
            switcher.entries = entries()
            // La première entrée est l'endroit où l'on est ; l'appui choisit la suivante.
            switcher.selected = StudySwitcherModel.move(from: 0, by: step, count: switcher.entries.count)
            showSwitcher()
        } else {
            switcher.selected = StudySwitcherModel.move(from: switcher.selected, by: step, count: switcher.entries.count)
        }
    }

    private func showSwitcher() {
        let panel = switcherPanel ?? HUDPanel(content: AnyView(StudySwitcherView(state: switcher) { [weak self] index in
            self?.switcher.selected = index
            self?.hideSwitcher(commit: true)
        }))
        switcherPanel = panel
        panel.place(on: NSScreen.screens.first)
        panel.orderFrontRegardless()
        escape = StudyHotKeys.shared.register(key: kVK_Escape, modifiers: 0) { [weak self] in self?.hideSwitcher(commit: false) }
        // On valide au relâchement de ⌘ : lu sans permission, 60 fois par seconde.
        poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if !NSEvent.modifierFlags.contains(.command) { self?.hideSwitcher(commit: true) }
            }
        }
    }

    private func hideSwitcher(commit: Bool) {
        poll?.invalidate()
        poll = nil
        StudyHotKeys.shared.unregister(escape)
        escape = nil
        guard switcherPanel?.isVisible == true else { return }
        switcherPanel?.orderOut(nil)
        if commit, switcher.entries.indices.contains(switcher.selected) {
            let entry = switcher.entries[switcher.selected]
            model.touch(entry.id)
            entry.action()
        }
    }

    // MARK: Recherche (⌘Espace)

    func showSearch() {
        guard let container = controller.container, let timer = controller.timer, let settings = controller.settings else { return }
        if searchPanel?.isVisible == true { hideSearch(); return }
        let view = StudySearchView(dismiss: { [weak self] in self?.hideSearch() })
            .environment(timer).environment(settings).modelContainer(container)
        let panel = HUDPanel(content: AnyView(view), keyable: true)
        searchPanel = panel
        panel.place(on: NSScreen.screens.first)
        panel.makeKeyAndOrderFront(nil)
    }

    func hideSearch() {
        searchPanel?.orderOut(nil)
        searchPanel = nil
    }
}

/// Une fenêtre flottante sans bord, au-dessus de tout sauf des voiles ; elle ne
/// prend pas la main de l'app devant, sauf pour écrire (la recherche).
final class HUDPanel: NSPanel {
    private let keyable: Bool
    override var canBecomeKey: Bool { keyable }

    init(content: AnyView, keyable: Bool = false) {
        self.keyable = keyable
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
    }

    func place(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main, let host = contentView as? NSHostingView<AnyView> else { return }
        let size = host.fittingSize
        setContentSize(size)
        setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2 + 80))
    }
}

// MARK: - Vues

struct StudySwitcherView: View {
    var state: StudyShell.SwitcherState
    var choose: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(state.entries.enumerated()), id: \.element.id) { index, entry in
                VStack(spacing: 6) {
                    Group {
                        if let bundleID = entry.bundleID, let icon = StudyModeController.icon(for: bundleID) {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: entry.icon).font(.title).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(width: 44, height: 44)
                    Text(entry.title).font(.caption).lineLimit(1)
                }
                .foregroundStyle(StudyPalette.ink)
                .frame(width: 76, height: 78)
                .background(index == state.selected ? StudyPalette.ink.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { choose(index) }
            }
        }
        .padding(12)
        .deskGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

struct StudySearchView: View {
    var dismiss: () -> Void

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Query(sort: \Course.code) private var courses: [Course]
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    struct Result: Identifiable {
        let id: String
        var title: String
        var subtitle = ""
        var icon: String
        var section: String
        var run: () -> Void
    }

    private var tracked: [Course] { courses.filter(\.isTracked) }
    private var controller: StudyModeController { .shared }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(StudyPalette.inkSecondary)
                TextField("Un outil, une série, un calcul…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onKeyPress(.downArrow) { move(1, items.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, items.count); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            if !items.isEmpty {
                Divider().overlay(StudyPalette.rule)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || items[index - 1].section != item.section {
                                Text(item.section).font(.caption.weight(.semibold)).foregroundStyle(StudyPalette.inkTertiary)
                                    .padding(.horizontal, 12).padding(.top, index == 0 ? 6 : 10).padding(.bottom, 3)
                            }
                            row(item, selected: index == selected)
                                .onTapGesture { selected = index; run(items) }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 340)
            }
        }
        .frame(width: 620)
        .deskGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selected = 0 }
    }

    private func row(_ item: Result, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon).frame(width: 22)
            Text(item.title).lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).foregroundStyle(StudyPalette.inkSecondary).lineLimit(1)
            }
            Spacer()
        }
        .foregroundStyle(StudyPalette.ink)
        .padding(.horizontal, 10).frame(height: 34)
        .background(selected ? StudyPalette.ink.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int, _ count: Int) {
        guard count > 0 else { return }
        selected = StudySwitcherModel.move(from: selected, by: delta, count: count)
    }

    private func run(_ items: [Result]) {
        guard items.indices.contains(selected) else { return }
        items[selected].run()
        dismiss()
    }

    // MARK: Résultats

    private var results: [Result] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        var found: [Result] = []
        if let expression = StudySearchQuery.mathExpression(needle), let answer = Self.evaluate(expression) {
            found.append(Result(id: "math", title: "= \(answer)", subtitle: "↩ copie le résultat", icon: "equal.circle", section: "Calcul") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
            })
        }
        found += actions.filter { needle.isEmpty || matches($0.title, needle) }
        found += tools.filter { !needle.isEmpty && matches($0.title, needle) }
        if !needle.isEmpty {
            let documents = SearchIndexBuilder.documents(courses: tracked)
            for hit in SearchEngine.search(needle, in: documents).prefix(30) {
                guard let target = resolve(hit) else { continue }
                found.append(Result(id: hit.document.id, title: hit.document.title,
                                    subtitle: [hit.document.courseCode, hit.document.subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                    icon: hit.kind.icon, section: hit.kind.label) { open(target.course, target.item, theory: target.theory) })
            }
        }
        return found
    }

    private var actions: [Result] {
        let desk = controller.desk
        var list: [Result] = StudyDesk.Pane.allCases.map { pane in
            Result(id: "pane.\(pane.rawValue)", title: pane.title, icon: pane.icon, section: "Aller à") {
                desk.pane = pane
                controller.present()
            }
        }
        list.append(Result(id: "a.claude", title: "Claude", subtitle: "Demander", icon: "sparkle", section: "Actions") {
            desk.showClaude()
            controller.present()
        })
        list.append(Result(id: "a.pause", title: timer.phase == .running ? "Mettre en pause" : "Reprendre", icon: "playpause", section: "Actions") {
            timer.toggle()
        })
        if !StudyMode.isOpenEnded(timer.state) {
            list.append(Result(id: "a.more", title: "Encore 25 min", icon: "plus", section: "Actions") { timer.extendStudy(minutes: 25) })
        }
        return list
    }

    /// Les outils permis : apps installées et sites du cours.
    private var tools: [Result] {
        let course = tracked.first { $0.id == timer.courseID }
        return StudyTools.tools(for: course, settings: settings).map { tool in
            Result(id: "tool.\(tool.id)", title: tool.title, subtitle: tool.subtitle, icon: tool.icon, section: "Outils") {
                switch tool.kind {
                case .app(let bundleID, _): controller.openApp(bundleID: bundleID)
                case .web(let url):
                    controller.browser.open(url, title: tool.title)
                    controller.desk.pane = .web
                    controller.present()
                }
            }
        }
    }

    private func open(_ course: UUID, _ item: UUID?, theory: Bool) {
        timer.retarget(courseID: course, taskType: theory ? .theory : .exercise, targetID: item)
        controller.desk.pane = theory ? .course : .exercise
        controller.present()
    }

    private func resolve(_ hit: SearchHit) -> (course: UUID, item: UUID?, theory: Bool)? {
        let parts = hit.document.id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch hit.kind {
        case .course: return (id, nil, false)
        case .series:
            return tracked.first { $0.series.contains { $0.id == id } }
                .map { ($0.id, $0.series.first { $0.id == id }?.sortedExercises.first?.id, false) }
        case .exercise: return tracked.first { $0.allExercises.contains { $0.id == id } }.map { ($0.id, id, false) }
        case .theory: return tracked.first { $0.theoryItems.contains { $0.id == id } }.map { ($0.id, id, true) }
        default: return nil
        }
    }

    private func matches(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func evaluate(_ expression: String) -> String? {
        var session = MathWorkbench.Session()
        guard let output = try? MathWorkbench.run(expression, in: &session) else { return nil }
        switch output {
        case .value(let value): return value
        case .complex(let algebraic, _): return algebraic
        case .solutions(let variable, let values): return values.map { "\(variable) = \($0)" }.joined(separator: " ; ")
        case .matrix(let rows): return rows.map { $0.joined(separator: " ") }.joined(separator: " ; ")
        case .plotted, .defined: return nil
        }
    }
}
