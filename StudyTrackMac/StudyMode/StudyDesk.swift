import AppKit
import CryptoKit
import Foundation
import Observation
import PDFKit
import SwiftUI

/// Le bureau du mode étude : un seul endroit pour tout ce qui sert à
/// travailler — la série, le cours (StudyTrack, Moodle, Botafogo), Claude, la
/// calculatrice, et le navigateur en dernier recours.
@MainActor
@Observable
final class StudyDesk {
    enum Pane: String, CaseIterable, Identifiable {
        case desk, exercise, course, claude, calc, web
        var id: String { rawValue }

        var title: String {
            switch self {
            case .desk: return "Bureau"
            case .exercise: return "Série"
            case .course: return "Cours"
            case .claude: return "Claude"
            case .calc: return "Calcul"
            case .web: return "Web"
            }
        }

        var icon: String {
            switch self {
            case .desk: return "moon.stars"
            case .exercise: return "doc.text"
            case .course: return "books.vertical"
            case .claude: return "sparkle"
            case .calc: return "function"
            case .web: return "globe"
            }
        }

        var shortcut: KeyEquivalent {
            switch self {
            case .desk: return "1"
            case .exercise: return "2"
            case .course: return "3"
            case .claude: return "4"
            case .calc: return "5"
            case .web: return "6"
            }
        }
    }

    /// Le cours et la série côte à côte (⌘\\).
    var sideBySide = false

    var pane: Pane = .desk {
        didSet {
            #if DEBUG
            if CommandLine.arguments.contains("-tracePane") { FileHandle.standardError.write(Data("PANE \(oldValue) → \(pane)\n\(Thread.callStackSymbols.prefix(12).joined(separator: "\n"))\n".utf8)) }
            #endif
        }
    }

    // MARK: Claude

    /// Une conversation par série : on retrouve la sienne en y revenant, et
    /// Claude Code la garde d'un lancement de l'app à l'autre. Une conversation
    /// libre (`nil`) quand la session ne vise pas d'exercice.
    private(set) var chats: [UUID?: ClaudeChat] = [:]

    func chat(series seriesID: UUID?, config: ClaudeChat.Config) -> ClaudeChat {
        // Le réglage « projet EPFL » a changé : une autre conversation.
        if let chat = chats[seriesID], chat.config == config { return chat }
        chats[seriesID]?.close()
        let chat = ClaudeChat(seriesID: seriesID, config: config)
        chats[seriesID] = chat
        return chat
    }

    /// Une question préparée ailleurs (« Demander à Claude » sur un exercice).
    var pendingQuestion: String?
    var pendingAttachSeries = false
    /// Une pièce jointe préparée avec la question (ta copie GoodNotes).
    var pendingAttachment: ClaudeTutor.Attachment?
    /// Montrer ta copie (GoodNotes) à la place de l'énoncé.
    var showingCopy = false

    /// Une question pour Claude, avec une pièce jointe (ta copie) ou le PDF de la série.
    func ask(_ question: String, attachment: ClaudeTutor.Attachment?) {
        pendingAttachment = attachment
        ask(question, attachSeries: attachment == nil)
    }

    func ask(_ question: String, attachSeries: Bool = true) {
        pendingQuestion = question
        pendingAttachSeries = attachSeries
        pane = .claude
    }

    // MARK: Calcul

    /// La calculatrice (partagée avec l'iPhone : `StudyKit/CalcPane.swift`).
    let calc = CalcModel()

    // MARK: Sites (partagés avec l'iPhone : `StudyKit/SiteHub.swift`)

    let sites = SiteHub.shared
    typealias Load = SiteHub.Load
    var documents: [String: Load] { sites.documents }
    func document(_ address: String) -> Load? { sites.document(address) }
    func loadPDF(_ address: String) { sites.loadPDF(address) }
    func retry(_ address: String) { sites.retry(address) }
    var openedDocument: (title: String, address: String)? {
        get { sites.openedDocument }
        set { sites.openedDocument = newValue }
    }
    var moodle: MoodleClient { sites.moodle }
    var moodleOutlines: [Int: MoodleCourseSnapshot] { get { sites.moodleOutlines } set { sites.moodleOutlines = newValue } }
    var moodlePages: [Int: MoodleCoursePage] { get { sites.moodlePages } set { sites.moodlePages = newValue } }
    var moodleError: [Int: String] { get { sites.moodleError } set { sites.moodleError = newValue } }
    var courseware: CoursewareClient { sites.courseware }
    var ed: EdClient { sites.ed }
    var edCourses: [EdDiscussion.Course]? { get { sites.edCourses } set { sites.edCourses = newValue } }
    var edNeedsLogin: Bool { get { sites.edNeedsLogin } set { sites.edNeedsLogin = newValue } }
    var edThreads: [Int: [EdDiscussion.Thread]] { get { sites.edThreads } set { sites.edThreads = newValue } }
    var edLessons: [Int: [EdDiscussion.Lesson]] { get { sites.edLessons } set { sites.edLessons = newValue } }
    func loadEdCourses() async { await sites.loadEdCourses() }
    var mediaspace: MediaSpaceClient { sites.mediaspace }
    var edxOutlines: [String: EdXOutline] { get { sites.edxOutlines } set { sites.edxOutlines = newValue } }
    var signIn: StudySite? { get { sites.signIn } set { sites.signIn = newValue } }
    var signInRevision: Int { sites.signInRevision }
    func signedIn(_ site: StudySite) { sites.signedIn(site) }

    func closeAll() {
        for chat in chats.values { chat.close() }
    }
}
