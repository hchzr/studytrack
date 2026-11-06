import Foundation

/// Tout ce qu'un assistant peut lire d'un cours, **sans réseau** : la liste, pas
/// les octets. Les octets viennent à la demande (`read_file`), téléchargés dans
/// la session Moodle du Mac, ou copiés depuis le dossier de notes.
///
/// Pur : les modèles entrent, des lignes sortent — testé dans `Validation`.
enum LocalFileCatalog {

    /// D'où viennent les octets.
    enum Source {
        /// Un texte déjà connu (notes, fiche, corrigés rédigés).
        case text(String)
        /// Une adresse à télécharger (`file://` compris).
        case remote(URL)
        /// Un fichier déjà sur le Mac (un cahier du dossier de notes).
        case disk(URL)
        /// Un fichier ajouté à un cours, rangé dans la base.
        case data(Data, fileName: String)
    }

    struct Entry {
        var id: String
        var courseID: String
        var courseCode: String
        var courseName: String
        var type: String
        var title: String
        var seriesNumber: Int?
        var week: Int?
        /// Nom de fichier, sans extension quand elle n'est connue qu'au téléchargement.
        var baseName: String
        var source: Source
        var address: String?
        /// La série dont le PDF est aussi gardé par l'app (son cache sert d'abord).
        var seriesID: String?
    }

    /// Un cahier du dossier de notes, déjà rattaché à son cours.
    struct Notebook {
        var courseID: UUID
        var document: NotesLibrary.Document
        var url: URL
    }

    static let types = ["enonce", "corrige", "examen", "corrige-examen", "support", "document", "ressource",
                        "cahier", "notes", "fiche", "corrige-texte", "notes-examen"]

    // MARK: Liste

    static func entries(courses: [Course], notebooks: [Notebook] = []) -> [Entry] {
        var result: [Entry] = []
        for course in courses where course.isTracked {
            let code = course.displayCode
            let slugCode = slug(code)
            func entry(_ id: String, _ type: String, _ title: String, base: String, source: Source, series: ExerciseSeries? = nil,
                       week: Int? = nil, address: String? = nil) -> Entry {
                Entry(id: id, courseID: course.id.uuidString, courseCode: code, courseName: course.name, type: type, title: title,
                      seriesNumber: series?.seriesNumber, week: week ?? series.map(\.plannedWeek).flatMap { $0 > 0 ? $0 : nil },
                      baseName: base, source: source, address: address, seriesID: nil)
            }

            if !course.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(entry("notes:\(course.id)", "notes", "Notes — \(course.name)", base: "\(slugCode)-notes.md", source: .text(course.notes)))
            }
            if let sheet = course.revisionSheet {
                let text = NotebookExport.sheetText(courseName: course.name, sheet: sheet, map: course.studyMap)
                if !text.isEmpty {
                    result.append(entry("fiche:\(course.id)", "fiche", "Fiche de révision — \(course.name)", base: "\(slugCode)-fiche.md", source: .text(text)))
                }
            }

            for series in course.sortedSeries {
                let n = String(format: "%02d", series.seriesNumber)
                // Un titre qui dit déjà « Série 3 » n'est pas répété.
                let label = series.title.isEmpty ? "Série \(series.seriesNumber)"
                    : (fold(series.title).contains("serie \(series.seriesNumber)") || fold(series.title).contains("serie\(series.seriesNumber)") ? series.title : "Série \(series.seriesNumber) — \(series.title)")
                if let url = documentURL(series.urlString) {
                    var line = entry("serie:\(series.id)", "enonce", "\(label) (énoncé)", base: "serie-\(n)-enonce", source: .remote(url),
                                     series: series, address: series.urlString)
                    line.seriesID = series.id.uuidString
                    result.append(line)
                }
                if let url = documentURL(series.solutionURLString) {
                    result.append(entry("corrige:\(series.id)", "corrige", "\(label) (corrigé)", base: "serie-\(n)-corrige", source: .remote(url),
                                        series: series, address: series.solutionURLString))
                }
                let solved = series.sortedExercises.filter { !$0.solution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if !solved.isEmpty {
                    let body = (["# Corrigé — \(code), série \(series.seriesNumber)"]
                        + solved.map { "## Exercice \($0.exerciseNumber)\($0.title.isEmpty ? "" : " — " + $0.title)\n\n\($0.solution)" })
                        .joined(separator: "\n\n")
                    result.append(entry("corrige-texte:\(series.id)", "corrige-texte", "Corrigé rédigé — série \(series.seriesNumber)",
                                        base: "serie-\(n)-corrige-redige.md", source: .text(body), series: series))
                }
            }

            for exam in course.pastExams {
                let name = slug("\(exam.year)-\(exam.title)")
                if let url = documentURL(exam.urlString) {
                    result.append(entry("examen:\(exam.id)", "examen", "\(exam.title) (\(exam.year))", base: "examen-\(name)", source: .remote(url), address: exam.urlString))
                }
                if let url = documentURL(exam.solutionURLString) {
                    result.append(entry("corrige-examen:\(exam.id)", "corrige-examen", "\(exam.title) (\(exam.year)) — corrigé",
                                        base: "examen-\(name)-corrige", source: .remote(url), address: exam.solutionURLString))
                }
                if !exam.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(entry("notes-examen:\(exam.id)", "notes-examen", "Notes — \(exam.title)", base: "examen-\(name)-notes.md", source: .text(exam.notes)))
                }
            }

            // Transparents, notes et PDF rattachés aux éléments de théorie, puis les documents du cours.
            var seen = Set<String>()
            for item in course.sortedTheoryItems {
                for link in item.links where supportKinds.contains(link.kind) {
                    guard let url = documentURL(link.url), seen.insert(link.url).inserted else { continue }
                    result.append(entry("support:\(item.id):\(hash(link.url))", "support", "\(item.number) \(item.title) — \(link.title)",
                                        base: "\(slug(item.number))-\(slug(link.title))-\(hash(link.url))", source: .remote(url),
                                        week: item.plannedWeek > 0 ? item.plannedWeek : nil, address: link.url))
                }
            }
            for document in course.documents where supportKinds.contains(document.kind) {
                guard let url = documentURL(document.url), seen.insert(document.url).inserted else { continue }
                result.append(entry("document:\(course.id):\(hash(document.url))", "document",
                                    document.group.isEmpty ? document.title : "\(document.group) — \(document.title)",
                                    base: "\(slug(document.title))-\(hash(document.url))", source: .remote(url), address: document.url))
            }

            for resource in course.sortedResources {
                let title = resource.title.isEmpty ? resource.fileName : resource.title
                if let data = resource.fileData, !resource.fileName.isEmpty {
                    result.append(entry("ressource:\(resource.id)", "ressource", title,
                                        base: "\(slug(title))-\(hash(resource.id.uuidString))", source: .data(data, fileName: resource.fileName)))
                } else if [.pdf, .file, .image].contains(resource.kind), let url = documentURL(resource.address), seen.insert(resource.address).inserted {
                    result.append(entry("ressource:\(resource.id)", "ressource", title, base: "\(slug(title))-\(hash(resource.id.uuidString))",
                                        source: .remote(url), address: resource.address))
                }
            }

            for notebook in notebooks where notebook.courseID == course.id {
                let document = notebook.document
                let kind = document.isSolution ? "corrigé" : "copie"
                let label = [document.notebook, document.title].filter { !$0.isEmpty }.joined(separator: " — ")
                result.append(entry("cahier:\(hash(document.path))", "cahier", "\(label) (\(kind))",
                                    base: "\(slug(document.notebook))-\(slug(document.title))-\(hash(document.path))", source: .disk(notebook.url),
                                    week: document.week))
                if let number = document.seriesNumber { result[result.count - 1].seriesNumber = number }
            }
        }
        return result
    }

    // MARK: Filtres

    static func filter(_ entries: [Entry], course: Course?, type: String?, series: Int?, query: String?) -> [Entry] {
        // Par mots, sans accents ni ponctuation : « aide mémoire » trouve « Aide-mémoire ».
        let words = query.map(wordsOf) ?? []
        return entries.filter { entry in
            if let course, entry.courseID != course.id.uuidString { return false }
            if let type, !type.isEmpty, entry.type != type { return false }
            if let series, entry.seriesNumber != series { return false }
            if !words.isEmpty {
                let haystack = wordsOf("\(entry.courseCode) \(entry.title) \(entry.baseName)").joined(separator: " ")
                if !words.allSatisfy({ haystack.contains($0) }) { return false }
            }
            return true
        }
    }

    // MARK: Outils

    private static let supportKinds: Set<ContentLink.Kind> = [.pdf, .slides, .notes, .solution]

    private static let documentExtensions: Set<String> = ["pdf", "ppt", "pptx", "key", "doc", "docx", "xls", "xlsx", "odt", "odp", "ods",
                                                            "txt", "md", "tex", "csv", "zip", "png", "jpg", "jpeg", "ipynb"]

    /// L'adresse d'un **document** (et non d'une page web) : un fichier, un PDF
    /// Moodle ou Dropbox, ou une activité Moodle qui n'est qu'un intermédiaire.
    static func documentURL(_ address: String) -> URL? {
        guard !address.isEmpty, let url = URL(string: address) else { return nil }
        if url.isFileURL { return url }
        guard url.scheme?.hasPrefix("http") == true else { return nil }
        if MoodleLinks.activityModule(of: url) != nil || MoodleLinks.isDocument(address) { return url }
        if url.host?.contains("dropbox.com") == true { return url }
        return documentExtensions.contains(url.pathExtension.lowercased()) ? url : nil
    }

    static func wordsOf(_ text: String) -> [String] {
        fold(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Un nom de fichier lisible : minuscules, sans accents, des tirets.
    static func slug(_ text: String) -> String {
        let parts = fold(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return parts.isEmpty ? "fichier" : String(parts.joined(separator: "-").prefix(80))
    }

    /// Une empreinte courte et stable (FNV-1a) : désambiguïse deux documents de même titre.
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x100000001b3 }
        return String(String(value, radix: 16).prefix(8))
    }

    // MARK: Pages

    /// « 1-5,8 » → [0, 1, 2, 3, 4, 7] (indices à partir de 0), bornées à `total`,
    /// sans doublon, dans l'ordre. Une plage hors du document est ignorée ;
    /// `nil` si rien d'utilisable n'est demandé.
    static func pageIndices(_ spec: String, total: Int) -> [Int]? {
        guard total > 0 else { return nil }
        var seen = Set<Int>()
        var result: [Int] = []
        for part in spec.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard bounds.count == 1 || bounds.count == 2, let low = bounds[0] else { continue }
            let high = bounds.count == 2 ? (bounds[1] ?? total) : low
            guard low >= 1, high >= low else { continue }
            for page in low...min(high, total) where seen.insert(page).inserted { result.append(page - 1) }
        }
        return result.isEmpty ? nil : result
    }
}
