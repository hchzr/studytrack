#if DEBUG
import AppKit
import SwiftData
import SwiftUI

/// Arguments de lancement du Mac pour les essais et les captures — jamais
/// compilés en Release (`-debugTimer`, `-epflConnect`, `-dumpMoodle`, `-dumpEdX`,
/// `-claudeButtons`, `-signInSheet`, `-dumpEd`, `-mathPreview`, `-debugPage`).
@MainActor
enum MacDebugLaunch {
    static func apply(timer: MacTimer, store: MacStore) {
        // `-debugTimer start|discard` : vérifier le chrono partagé sans cliquer.
        if let index = CommandLine.arguments.firstIndex(of: "-debugTimer"), index + 1 < CommandLine.arguments.count {
            let action = CommandLine.arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if action == "start" { timer.start(taskType: .exercise, label: "Test du chrono partagé") }
                if action == "discard" { timer.discard() }
                if action == "study" {
                    let context = ModelContext(store.container)
                    let course = (try? context.fetch(FetchDescriptor<Course>()))?.first
                    // `-seedBotafogoSeries` : un exercice de la série Botafogo (la dernière).
                    let seriesChoice = CommandLine.arguments.contains("-seedBotafogoSeries") ? course?.sortedSeries.last : course?.sortedSeries.first
                    let exercise = seriesChoice?.sortedExercises.dropFirst().first
                    // `-studyMoment lecture|revision` : le bureau sous cette forme. Jamais
                    // de verrou en essai.
                    let moment = CommandLine.arguments.firstIndex(of: "-studyMoment").flatMap {
                        $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil
                    }
                    let type: TaskType = moment == "lecture" ? .lecture : (moment == "revision" ? .theory : .exercise)
                    // `-studyOpen` : une session sans fin.
                    timer.enterStudy(minutes: CommandLine.arguments.contains("-studyOpen") ? nil : 25, courseID: course?.id, taskType: type,
                                     targetID: type == .exercise && !CommandLine.arguments.contains("-noTarget") ? exercise?.id : nil, label: "Test du mode étude", locks: false)
                    if let index = CommandLine.arguments.firstIndex(of: "-studyPane"), index + 1 < CommandLine.arguments.count,
                       let pane = StudyDesk.Pane(rawValue: CommandLine.arguments[index + 1]) {
                        StudyModeController.shared.desk.pane = pane
                    }
                    // `-studyPane claude` : Claude, flottant ; `-sideBySide` : le volet d'à côté ouvert.
                    if CommandLine.arguments.contains("claude") { StudyModeController.shared.desk.showClaude() }
                    if CommandLine.arguments.contains("-sideBySide") { StudyModeController.shared.desk.sideOpen = true }
                }
            }
        }
        // `-epflConnect` : la connexion silencieuse à chaque site, avec le résultat.
        // `-musicRemoteDemo` : un iPhone qui joue (captures du lecteur partagé).
        if CommandLine.arguments.contains("-musicRemoteDemo") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let now = Date()
                StudyMusic.shared.receive(.state(MusicLink.State(
                    device: "00000000-0000-0000-0000-0000000000AB", platform: .iphone, title: "Wait for Me", artist: "Reeve Carney",
                    album: "Hadestown (Original Broadway Cast Recording)", duration: 242, elapsed: 64, readAt: now, isPlaying: true,
                    artworkURL: "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/7a/a5/4c/7aa54c1a-0b0d-d3a2-7fd0-1f3b1a6a1d34/19UMGIM43231.rgb.jpg/600x600bb.jpg",
                    upNext: [.init(title: "Livin' It Up on Top", artist: "Hadestown"), .init(title: "All I've Ever Known", artist: "Eva Noblezada")],
                    updatedAt: now)))
            }
        }
        if CommandLine.arguments.contains("-epflConnect") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if CommandLine.arguments.contains("-epflOnlyMedia") { await SchoolConnect.shared.connect(.mediaspace) } else { await SchoolConnect.shared.connectAll() }
                let states = SchoolConnect.Site.allCases.map { "\($0.rawValue)=\(SchoolConnect.shared.state($0))" }.joined(separator: " ")
                FileHandle.standardError.write(Data("EPFL \(states) email=\(SchoolConnect.shared.email != nil)\n".utf8))
            }
        }
        // `-dumpMoodle <id> <fichier>` : le plan d'un cours Moodle et ce que les
        // règles en tirent, écrits dans un fichier (lecture seule, rien d'importé).
        if let index = CommandLine.arguments.firstIndex(of: "-dumpMoodle"), index + 2 < CommandLine.arguments.count,
           let courseID = Int(CommandLine.arguments[index + 1]) {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await SchoolConnect.shared.ensure(.moodle)
                var lines: [String] = []
                do {
                    let client = SiteHub.shared.moodle
                    let ref = MoodleCourseRef(id: courseID, fullname: "", shortname: "")
                    let snapshot = try await client.snapshot(of: ref)
                    for section in snapshot.sections {
                        lines.append("## \(section.number) \(section.title)")
                        if !section.text.isEmpty { lines.append("   texte: \(section.text.prefix(300))") }
                        for link in section.links { lines.append("   lien[\(link.kind.rawValue)]: \(link.title) → \(link.url)") }
                        for activity in section.activities {
                            lines.append("  - [\(activity.module)\(activity.isVisible ? "" : " caché")] \(activity.name) → \(activity.link) dest=\(activity.destination ?? "-") sol=\(activity.solutionTarget ?? "-")")
                        }
                    }
                    let draft = MoodleCourseAnalyzer.draft(from: snapshot, termStart: nil, totalWeeks: 14)
                    lines.append("\n# Règles")
                    for section in draft.sections {
                        for item in section.items where item.kind == .series {
                            lines.append("S\(item.seriesNumber.map(String.init) ?? "?") sem \(item.week ?? section.week) « \(item.title) » \(item.pdfURL.isEmpty ? item.url : item.pdfURL)")
                        }
                    }
                } catch {
                    lines.append("erreur: \(error)")
                }
                try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
                FileHandle.standardError.write(Data("DUMP fini\n".utf8))
            }
        }
        // `-dumpEdX <course-v1:…> <dossier> [chapitre]` : le HTML brut des textes et
        // problèmes d'un chapitre de Courseware (lecture seule, rien n'est envoyé).
        if let index = CommandLine.arguments.firstIndex(of: "-dumpEdX"), index + 2 < CommandLine.arguments.count {
            let key = CommandLine.arguments[index + 1]
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            let chapter = index + 3 < CommandLine.arguments.count ? Int(CommandLine.arguments[index + 3]) ?? 0 : 0
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await SchoolConnect.shared.ensure(.courseware, prompting: false)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let client = SiteHub.shared.courseware
                if let outline = try? await client.outline(of: key), outline.chapters.indices.contains(chapter) {
                    var count = 0
                    for unit in outline.chapters[chapter].sequences.flatMap(\.units) {
                        for block in unit.blocks where count < 40 {
                            guard let address = block.viewURL, block.kind == .html || block.kind == .problem else { continue }
                            let html = (try? await client.blockHTML(address)) ?? ""
                            let name = String(format: "%02d-%@", count, block.kind == .html ? "html" : "problem")
                            try? ("<!-- \(unit.title) · \(block.title) · \(address) -->\n" + html)
                                .write(to: folder.appendingPathComponent(name + ".html"), atomically: true, encoding: .utf8)
                            if block.kind == .problem, let problem = try? await client.problem(address) {
                                try? ("PROMPT\n" + problem.prompt + "\n\nOPTIONS\n" + problem.groups.flatMap(\.options).map(\.label).joined(separator: "\n---\n"))
                                    .write(to: folder.appendingPathComponent(name + ".prompt.txt"), atomically: true, encoding: .utf8)
                            }
                            count += 1
                        }
                    }
                }
                FileHandle.standardError.write(Data("DUMP fini\n".utf8))
            }
        }
        // `-claudeButtons <fichier>` : l'éditeur des boutons de Claude sur ce
        // fichier (une copie, pour l'essayer sans toucher au vrai).
        if let index = CommandLine.arguments.firstIndex(of: "-claudeButtons"), index + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let window = NSWindow(contentViewController: NSHostingController(rootView: ClaudeButtonsEditor(url: url)))
                window.title = "Boutons de Claude"
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // `-signInSheet moodle|mediaspace` : la feuille de connexion seule.
        if let index = CommandLine.arguments.firstIndex(of: "-signInSheet"), index + 1 < CommandLine.arguments.count,
           let site = CommandLine.arguments[index + 1] == "mediaspace" ? StudySite.mediaspace : StudySite.moodle as StudySite? {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let window = NSWindow(contentViewController: NSHostingController(rootView: SignInSheet(site: site) {
                    FileHandle.standardError.write(Data("SIGNIN fini\n".utf8))
                }))
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // `-dumpEd <code> <dossier>` : les fils Ed bruts d'un cours (lecture seule).
        if let index = CommandLine.arguments.firstIndex(of: "-dumpEd"), index + 2 < CommandLine.arguments.count {
            let code = CommandLine.arguments[index + 1].lowercased()
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await SchoolConnect.shared.ensure(.ed, prompting: false)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let ed = SiteHub.shared.ed
                let courses = (try? await ed.courses()) ?? []
                if let course = courses.first(where: { $0.code.lowercased().contains(code) || $0.name.lowercased().contains(code) }) {
                    let list = (try? await ed.debugGET("courses/\(course.id)/threads?limit=100&sort=new")) ?? Data()
                    try? list.write(to: folder.appendingPathComponent("threads.json"))
                    for thread in EdDiscussion.threads(json: list).prefix(100) {
                        let raw = (try? await ed.debugGET("threads/\(thread.id)")) ?? Data()
                        let text = String(decoding: raw, as: UTF8.self)
                        if text.contains("poll") {
                            try? raw.write(to: folder.appendingPathComponent("thread-\(thread.id).json"))
                            if let match = text.range(of: #"poll id=\\?"(\d+)"#, options: .regularExpression) {
                                let id = text[match].filter(\.isNumber)
                                let poll = (try? await ed.debugGET("polls/\(id)")) ?? Data()
                                try? poll.write(to: folder.appendingPathComponent("poll-\(id).json"))
                            }
                        }
                    }
                }
                FileHandle.standardError.write(Data("DUMP fini \(courses.map(\.code))\n".utf8))
            }
        }
        // `-mathPreview [adresse d'un problème Courseware]` : les formules mises
        // en page (texte d'essai, et un vrai problème, sans rien envoyer).
        if let index = CommandLine.arguments.firstIndex(of: "-mathPreview") {
            let address = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if let address { await SchoolConnect.shared.ensure(Int(address) == nil ? .courseware : .ed, prompting: false) }
                let sample = #"""
Soient V=\(\mathbb{P}_4(\mathbb{R})\), et \(T:V\to W\) définie par \(T(p(t))=p'(t)\). Soient aussi \(\mathscr{B}_V=\{1,t,t^2,t^3,t^4\}\) et les matrices \[ A_1=\begin{pmatrix} 0 & 1 & 0 & 0 & 0 \\ 0 & 0 & 2 & 0 & 0 \\ 0 & 0 & 0 & 3 & 0 \\ 0 & 0 & 0 & 0 & 4 \end{pmatrix},~ A_2=\begin{pmatrix} 0 & 4 & 0 & 0 & 0 \\ 0 & 0 & 3 & 0 & 0 \\ 0 & 0 & 0 & 2 & 0 \\ 0 & 0 & 0 & 0 & 1 \end{pmatrix}, \] Parmi les possibilités suivantes, cochez celle qui vous paraît correcte. La matrice \([T]_{\mathscr{B}_W\mathscr{B}_V}\) est donnée par \(A_1\), et \(\dim (W_1+W_2) = \dim W_1 + \dim W_2 -\dim(W_1\cap W_2)\), avec \(\dfrac{a}{b}\) et \(\operatorname{rg}(A)\leqslant n\).

## Markdown
- un point avec $x_n \to \ell$
- un lien : [Moodle](https://moodle.epfl.ch)
"""#
                let root = ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        RichTextView(text: sample, size: 15).paperSheet(padding: 16)
                        if let address, let poll = Int(address) {
                            EdPollCard(id: poll, desk: SiteHub.shared, open: { _, _ in }, openWeb: { _, _ in })
                        } else if let address {
                            EdXProblemCard(address: address, desk: SiteHub.shared, open: { _, _ in }, openWeb: { _, _ in })
                        }
                        ForEach(Array(SiteHTML.blocks("<h2 class=\"problem-header\">Contenu de la leçon</h2><h3></h3><p>Dans cette leçon, les matrices.</p><h2></h2><div><h2>objectifs</h2><h3></h3></div><ol><li>de maîtriser les notions (taille) ;<strong></strong></li><li>de comparer deux matrices.</li></ol>").enumerated()), id: \.offset) { _, block in
                            if case .markdown(let text) = block { RichTextView(text: text, size: 15) }
                        }
                    }
                    .padding(24)
                }
                .frame(width: 760, height: 820)
                .background(Carnet.ground)
                let window = NSWindow(contentViewController: NSHostingController(rootView: root))
                window.title = "Formules"
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // `-debugPage focus|stats|today` : ouvrir une page sans cliquer.
        if let index = CommandLine.arguments.firstIndex(of: "-debugPage"), index + 1 < CommandLine.arguments.count {
            let page = CommandLine.arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if page == "palette" {
                    NotificationCenter.default.post(name: .macFocusSearch, object: nil)
                } else if page == "study" {
                    StudyModeController.shared.presentSetup()
                } else {
                    NotificationCenter.default.post(name: .macGoTo, object: page)
                }
            }
        }
    }
}
#endif
