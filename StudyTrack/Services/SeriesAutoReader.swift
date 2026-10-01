import Foundation
import PDFKit
import SwiftData
import Observation

/// Lance la lecture des énoncés en arrière-plan et annonce le résultat sur
/// l'accueil.
@MainActor
enum SeriesAutoReading {
    static func start(courses: [Course], context: ModelContext, settings: SettingsStore) {
        guard !courses.isEmpty else { return }
        Task { @MainActor in
            let report = await SeriesAutoReader.shared.readPending(courses: courses, context: context, settings: settings)
            guard !report.isEmpty else { return }
            let line = "Énoncés lus — " + report.joined(separator: " · ")
            settings.contentRefreshNews = settings.contentRefreshNews.isEmpty ? line : settings.contentRefreshNews + " · " + line
        }
    }
}

/// Remplit tout seul les séries importées **sans exercices** : on lit leur
/// énoncé là où il est publié.
///
/// Importer « Série 4 » depuis Moodle donnait une série vide et un bouton
/// « Lire les exercices dans le PDF » à toucher, série après série. Désormais,
/// après un import (et à chaque mise à jour automatique), l'app va chercher
/// l'énoncé elle-même :
///   • une page de série HTML (CS-107, `proginsc.epfl.ch`) se lit directement :
///     numéros, titres, niveaux, liens (`SeriesPageParser`) ;
///   • un PDF — sur Moodle, lu avec la session ; public (CS-101 sur GitHub),
///     lu directement — passe par la **même** chaîne que l'import manuel : mise
///     en page, motifs, puis le modèle de langage s'il est disponible.
/// Rien n'est effacé : l'écriture se fait en mode fusion (`SeriesDraftWriter`).
@MainActor
@Observable
final class SeriesAutoReader {
    static let shared = SeriesAutoReader()

    /// Les séries en cours de lecture, pour que la liste le dise.
    private(set) var reading: Set<UUID> = []
    /// Ce qui a échoué, par série, pour le proposer à la main.
    private(set) var failures: [UUID: String] = [:]
    @ObservationIgnored private var running = false

    /// Lit les séries vides des cours donnés, une à la fois.
    ///
    /// - Returns: « CS-107 série 3 : 12 exercices » pour chaque série remplie.
    @discardableResult
    func readPending(courses: [Course], context: ModelContext, settings: SettingsStore) async -> [String] {
        guard !running else { return [] }
        running = true
        defer { running = false }
        var report: [String] = []
        await repairLinks(courses: courses, context: context)
        for course in courses {
            for series in course.sortedSeries where series.exercises.isEmpty && failures[series.id] == nil {
                guard let url = URL(string: series.urlString), url.scheme?.hasPrefix("http") == true else { continue }
                reading.insert(series.id)
                defer { reading.remove(series.id) }
                do {
                    let count = try await read(series, from: url, course: course, context: context, settings: settings)
                    if count > 0 {
                        try? context.save()
                        report.append("\(course.displayCode) série \(series.seriesNumber) : \(count) exercice\(count > 1 ? "s" : "")")
                    }
                } catch {
                    failures[series.id] = error.localizedDescription
                    AppLog.record(.warning, "import", "Énoncé de la série \(series.seriesNumber) illisible",
                                  detail: "\(course.displayCode) — \(error.localizedDescription)")
                }
            }
        }
        return report
    }

    /// Les séries déjà tentées par `repairLinks`, pour ne pas relire Moodle à
    /// chaque lancement.
    @ObservationIgnored private var repaired: Set<UUID> = []

    /// Remplace l'adresse d'une page Moodle (page, dossier, lien) par celle du
    /// PDF qu'elle porte.
    ///
    /// Les séries importées avant que l'import ne suive ces pages gardaient
    /// l'adresse de la page : « Énoncé de la série » ouvrait Moodle, et la
    /// lecture des exercices échouait (« ce lien ne mène pas à un PDF »).
    func repairLinks(courses: [Course], context: ModelContext) async {
        var changed = false
        for course in courses {
            for series in course.sortedSeries where !repaired.contains(series.id) {
                guard let url = URL(string: series.urlString),
                      let module = MoodleLinks.activityModule(of: url), module != "resource" else { continue }
                repaired.insert(series.id)
                guard let found = await AuthenticatedDownloader.resolve(url) else { continue }
                series.urlString = found.statement.absoluteString
                if series.solutionURLString.isEmpty, let solution = found.solution {
                    series.solutionURLString = solution.absoluteString
                }
                failures[series.id] = nil
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    func retry(_ series: ExerciseSeries) {
        failures[series.id] = nil
    }

    // MARK: Lecture

    private func read(_ series: ExerciseSeries, from url: URL, course: Course,
                      context: ModelContext, settings: SettingsStore) async throws -> Int {
        let path = url.path.lowercased()
        if path.hasSuffix(".html") || path.hasSuffix(".htm") || path.hasSuffix("/") {
            let (data, _) = try await URLSession.shared.data(from: url)
            let html = String(decoding: data, as: UTF8.self)
            guard let page = SeriesPageParser.parseProginsc(html: html, baseURL: url) else { return 0 }
            write(page.exercises, into: series, course: course, context: context)
            if series.solutionURLString.isEmpty { series.solutionURLString = page.solutionURL }
            return series.exercises.count
        }

        let file = try await download(url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let document = PDFDocument(url: file) else {
            throw HiddenSiteSession.SiteError.failed("Ce lien ne mène pas à un PDF lisible.")
        }
        let lines = PDFLayoutExtractor.lines(from: document)
        guard lines.contains(where: { !$0.isEmpty }) else {
            throw HiddenSiteSession.SiteError.failed("Le PDF ne contient pas de texte (scan ?).")
        }
        var detected = SeriesLayoutParser.parse(lines, defaultSeries: series.seriesNumber)
        if settings.aiExtractionEnabled, SeriesAIExtractor.plannedSource(settings) != nil {
            let language = SeriesDocumentInference.languageName(of: lines.map(\.text).joined(separator: "\n"))
            let prepared = SeriesAIParsing.prepareLayout(lines, seriesHint: series.seriesNumber, language: language)
            if let result = try? await SeriesAIExtractor.extract(prepared: prepared,
                                                                 pageImages: PDFPageRenderer.jpegPages(of: document),
                                                                 seriesHint: series.seriesNumber,
                                                                 language: language, settings: settings) {
                detected = SeriesAIParsing.merge(heuristic: detected, ai: result.series,
                                                 preferredSeries: series.seriesNumber,
                                                 aiReadsLayout: result.source.readsLayout)
            }
        }
        guard let match = detected.first(where: { $0.number == series.seriesNumber }) ?? detected.first,
              !match.exercises.isEmpty else { return 0 }
        let exercises = match.exercises.map { exercise in
            ContentExerciseDraft(number: "\(series.seriesNumber).\(exercise.number.split(separator: ".").last.map(String.init) ?? exercise.number)",
                                 title: exercise.title, statement: exercise.statement,
                                 isBonus: exercise.isBonus, questions: exercise.subQuestions)
        }
        write(exercises, into: series, course: course, context: context)
        return series.exercises.count
    }

    private func write(_ exercises: [ContentExerciseDraft], into series: ExerciseSeries,
                       course: Course, context: ModelContext) {
        let draft = SeriesDraft(existingID: series.id, number: series.seriesNumber, title: "",
                                plannedWeek: series.plannedWeek,
                                exercises: exercises.map { spec in
                                    var exercise = ExerciseDraft(minor: spec.number.split(separator: ".").last.map(String.init) ?? spec.number,
                                                                 title: spec.title, isBonus: spec.isBonus,
                                                                 subQuestions: spec.questions)
                                    exercise.statement = spec.statement
                                    return exercise
                                })
        SeriesDraftWriter.write(draft, to: course, mode: .importMerge, context: context)
        for spec in exercises where !spec.url.isEmpty {
            series.exercises.first { $0.exerciseNumber == spec.number }?.statementURLString = spec.url
        }
    }

    /// Un PDF Moodle avec la session de l'app ; un PDF public directement.
    private func download(_ url: URL) async throws -> URL {
        if url.host?.contains("moodle") == true {
            return try await AuthenticatedDownloader.download(url)
        }
        // Dropbox sert une page HTML sans `dl=1`.
        var address = url
        if url.host?.contains("dropbox.com") == true,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = (components.queryItems ?? []).filter { $0.name != "dl" }
            items.append(URLQueryItem(name: "dl", value: "1"))
            components.queryItems = items
            address = components.url ?? url
        }
        let (temporary, response) = try await URLSession.shared.download(from: address)
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard type.contains("pdf") || address.pathExtension.lowercased() == "pdf" else {
            throw HiddenSiteSession.SiteError.failed("Ce lien ne mène pas à un PDF.")
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
