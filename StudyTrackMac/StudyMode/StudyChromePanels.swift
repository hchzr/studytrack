import AppKit
import SwiftData
import SwiftUI

/// Les niveaux des fenêtres du mode étude, du plus bas au plus haut : le bureau,
/// les barres, les notifications, le sélecteur et la recherche, les voiles, le
/// chrono flottant. Un seul endroit, pour que deux fenêtres ne se disputent
/// jamais la même hauteur.
enum StudyLevels {
    static let desk = NSWindow.Level.normal
    /// Les barres flottantes : au-dessus des apps (une app permise posée dans le
    /// centre ne les recouvre pas), au-dessous de tout le reste.
    static let chrome = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
    /// La barre du haut : au-dessus de la barre des menus de macOS et de ses icônes
    /// (niveau 25), donc elle la recouvre quand la souris monte en haut de l'écran.
    static let topBar = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    static let hud = NSWindow.Level.popUpMenu
    static let shield = NSWindow.Level.statusBar
    static let miniTimer = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
}

/// Une vue d'hébergement qui prend le clic même quand l'app n'est pas devant :
/// les barres flottantes répondent au premier clic.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Une barre flottante (la barre du haut, la colonne d'outils) : au-dessus des
/// apps permises, sans prendre la main de l'app devant.
final class ChromePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(content: AnyView, frame: NSRect, level: NSWindow.Level = StudyLevels.chrome) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        contentView = FirstMouseHostingView(rootView: content)
        setFrame(frame, display: true)
    }
}

/// La barre du haut dans sa propre fenêtre : le cours, la cible et les gestes
/// restent visibles quand une app permise est devant.
struct StudyTopBarHost: View {
    @Query(sort: \Course.code) private var courses: [Course]
    @Environment(MacTimer.self) private var timer

    var body: some View {
        let controller = StudyModeController.shared
        let course = courses.first { $0.id == timer.courseID }
        StudyTopBar(course: course, tint: MacTargets.tint(course),
                    moment: DeskSchedule.moment(taskType: timer.taskType, inGroup: timer.state?.groupSession != nil, course: course),
                    openMusic: { controller.desk.pane = .music },
                    openResource: { controller.openResource($0, course: course) })
            .environment(\.colorScheme, .dark)
            .environment(\.deskPanelHost, true)
    }
}

/// La colonne d'outils dans sa propre fenêtre.
struct StudyRailHost: View {
    @Query(sort: \Course.code) private var courses: [Course]
    @Environment(MacTimer.self) private var timer

    var body: some View {
        let controller = StudyModeController.shared
        StudyRail(desk: controller.desk, browser: controller.browser, course: courses.first { $0.id == timer.courseID })
            .environment(\.colorScheme, .dark)
            .environment(\.deskPanelHost, true)
    }
}

extension StudyModeController {
    static let barHeight: CGFloat = 66
    static let railWidth: CGFloat = 76

    /// `-studyPanels` : les barres flottantes, même en essai (rien n'est bloqué).
    static var panelsForced: Bool { CommandLine.arguments.contains("-studyPanels") }

    /// Où vont la barre, la colonne et le bureau (le centre et le volet) sur un écran.
    static func chromeFrames(on screen: NSScreen) -> (bar: NSRect, rail: NSRect, desk: NSRect) {
        let f = screen.frame
        let bar = NSRect(x: f.minX, y: f.maxY - barHeight, width: f.width, height: barHeight)
        let rail = NSRect(x: f.minX, y: f.minY, width: railWidth, height: f.height - barHeight)
        let desk = NSRect(x: f.minX + railWidth, y: f.minY, width: f.width - railWidth, height: f.height - barHeight)
        return (bar, rail, desk)
    }

    /// Une ressource gardée, ouverte à côté de ce qu'on fait (le signet de la barre du haut).
    func openResource(_ resource: SavedResource, course: Course?) {
        if resource.kind == .web, !resource.isFile, let url = URL(string: resource.address) {
            browser.open(url, title: resource.title)
            desk.pane = .web
            return
        }
        let reading: CoursePane.Reading? = resource.kind == .poly
            ? .botafogo(title: resource.title, url: resource.address)
            : ResourceLibrary.reading(for: resource)
        guard let reading else { return }
        let icon: String
        switch reading {
        case .pdf: icon = "doc.richtext"
        case .botafogo: icon = "book.closed"
        case .video, .edx, .edxMoment, .edxPlaylist: icon = "play.rectangle"
        case .edThread, .edLesson: icon = "bubble.left.and.bubble.right"
        default: icon = "doc"
        }
        desk.openSide(.init(kind: .reading(reading), title: resource.title, icon: icon, courseID: course?.id))
    }
}
