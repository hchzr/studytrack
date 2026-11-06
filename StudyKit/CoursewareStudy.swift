import CryptoKit
import SwiftUI

// MARK: - Les transcriptions d'un cours

/// Ce que disent les vidéos d'un cours Courseware : lu une fois dans la
/// session (une requête par vidéo), gardé sur l'appareil. La recherche
/// (`CoursewareTranscripts.search`) part de là.
@MainActor
@Observable
final class CoursewareTranscriptStore {
    static let shared = CoursewareTranscriptStore()

    private(set) var videos: [String: [CoursewareTranscripts.Video]] = [:]
    /// Pendant la lecture : combien de vidéos lues sur combien.
    private(set) var loading: [String: (done: Int, total: Int)] = [:]

    func isLoading(_ key: String) -> Bool { loading[key] != nil }

    func load(_ outline: EdXOutline, key: String, client: CoursewareClient) async {
        guard loading[key] == nil else { return }
        var known = videos[key] ?? Self.cached(key)
        let all = outline.chapters.flatMap { chapter in
            chapter.sequences.flatMap { sequence in
                sequence.units.flatMap { unit in
                    unit.blocks.filter { $0.kind == .video && !$0.transcripts.isEmpty }.map { (unit, $0) }
                }
            }
        }
        let missing = all.filter { pair in !known.contains { $0.block == pair.1.id } }
        guard !missing.isEmpty else { videos[key] = known; return }
        loading[key] = (0, missing.count)
        var done = 0
        // Quatre à la fois : Courseware répond, sans être bousculé.
        var index = 0
        while index < missing.count {
            let batch = Array(missing[index..<min(index + 4, missing.count)])
            await withTaskGroup(of: CoursewareTranscripts.Video?.self) { group in
                for (unit, block) in batch {
                    group.addTask { @MainActor in
                        for address in block.transcripts {
                            let absolute = address.hasPrefix("/") ? Institution.current.coursewareBase + address : address
                            guard let raw = try? await client.blockHTML(absolute) else { continue }
                            let cues = CoursewareTranscripts.cues(from: raw)
                            if !cues.isEmpty {
                                return .init(block: block.id, unit: unit.id, title: block.title.isEmpty ? unit.title : block.title, cues: cues)
                            }
                        }
                        return nil
                    }
                }
                for await video in group {
                    done += 1
                    if let video { known.append(video) }
                }
            }
            index += batch.count
            loading[key] = (done, missing.count)
            videos[key] = known
        }
        loading[key] = nil
        Self.store(known, key: key)
    }

    private static func file(_ key: String) -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Polymestre/transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    private static func cached(_ key: String) -> [CoursewareTranscripts.Video] {
        guard let data = try? Data(contentsOf: file(key)) else { return [] }
        return (try? JSONDecoder().decode([CoursewareTranscripts.Video].self, from: data)) ?? []
    }

    private static func store(_ videos: [CoursewareTranscripts.Video], key: String) {
        guard let data = try? JSONEncoder().encode(videos) else { return }
        try? data.write(to: file(key), options: .atomic)
    }
}

// MARK: - Chercher dans les vidéos

/// Les passages trouvés : la vidéo, l'instant, la phrase. Un clic ouvre la
/// vidéo à cet instant.
struct CoursewareSearchResults: View {
    let outline: EdXOutline
    let key: String
    let query: String
    let tint: Color
    var desk: SiteHub
    var open: (EdXOutline.Unit, String, Double) -> Void

    private var store: CoursewareTranscriptStore { .shared }

    var body: some View {
        let hits = CoursewareTranscripts.search(query, in: store.videos[key] ?? [])
        List {
            if let progress = store.loading[key] {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Lecture des transcriptions… \(progress.done)/\(progress.total)")
                        .font(.caption).foregroundStyle(Carnet.inkSecondary)
                }
            }
            if hits.isEmpty, !store.isLoading(key) {
                Text(store.videos[key]?.isEmpty == false ? "Aucune vidéo ne dit « \(query) »." : "Ces vidéos n'ont pas de transcription.")
                    .font(.callout).foregroundStyle(Carnet.inkSecondary)
            }
            ForEach(hits) { hit in
                Button {
                    if let unit = outline.units.first(where: { $0.id == hit.unit }) { open(unit, hit.block, hit.start) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(NativeVideo.clock(hit.start)).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(tint)
                            Text(hit.title).font(.caption).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
                        }
                        Text(highlighted(hit.snippet)).font(.callout).foregroundStyle(Carnet.ink).lineLimit(3)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .task(id: key) { await store.load(outline, key: key, client: desk.courseware) }
    }

    /// Les mots cherchés en gras dans la phrase.
    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let words = CoursewareTranscripts.fold(query).split(separator: " ").map(String.init).filter { $0.count >= 2 }
        let folded = CoursewareTranscripts.fold(text)
        for word in words {
            var searchStart = folded.startIndex
            while let range = folded.range(of: word, range: searchStart..<folded.endIndex) {
                let lower = folded.distance(from: folded.startIndex, to: range.lowerBound)
                let length = folded.distance(from: range.lowerBound, to: range.upperBound)
                let start = result.index(result.startIndex, offsetByCharacters: lower)
                let end = result.index(start, offsetByCharacters: length)
                result[start..<end].inlinePresentationIntent = .stronglyEmphasized
                searchStart = range.upperBound
            }
        }
        return result
    }
}

// MARK: - Les vidéos d'un chapitre, à la suite

/// Toutes les vidéos d'un chapitre, l'une après l'autre : la suivante part
/// seule à la fin de la précédente, à la vitesse choisie ; chacune vue compte
/// (dans le cours, et sur Courseware).
struct CoursewarePlaylistPage: View {
    let outline: EdXOutline
    let chapterID: String
    let key: String
    let tint: Color
    var desk: SiteHub
    var openWeb: (URL, String) -> Void

    @Environment(\.markStudied) private var markStudied
    @State private var index: Int?

    private var chapter: EdXOutline.Chapter? { outline.chapters.first { $0.id == chapterID } }

    private var videos: [(unit: EdXOutline.Unit, block: EdXOutline.Block)] {
        (chapter?.sequences ?? []).flatMap { sequence in
            sequence.units.flatMap { unit in unit.blocks.filter { $0.kind == .video }.map { (unit, $0) } }
        }
    }

    private func isWatched(_ pair: (unit: EdXOutline.Unit, block: EdXOutline.Block)) -> Bool {
        TheoryTracking.isPartWatched(pair.block.id) || pair.unit.completed
    }

    var body: some View {
        let list = videos
        let current = index ?? list.firstIndex { !isWatched($0) } ?? 0
        let remaining = list.indices.filter { $0 >= current && !isWatched(list[$0]) }.compactMap { list[$0].block.duration }.reduce(0, +)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Kicker("Vidéos à la suite", color: tint)
                Text(chapter?.title ?? "").font(Carnet.serif(28)).foregroundStyle(Carnet.ink)
                Text(remaining > 0
                     ? "\(list.count) vidéos · \(DateUtils.durationLabel(seconds: Int(remaining))) encore à voir"
                     : "\(list.count) vidéos")
                    .font(.callout).foregroundStyle(Carnet.inkSecondary)
                if list.indices.contains(current) {
                    let pair = list[current]
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pair.block.title.isEmpty ? pair.unit.title : pair.block.title).font(.headline).foregroundStyle(Carnet.ink)
                        if let address = pair.block.videoURL ?? pair.block.youTubeID.map({ "https://www.youtube.com/watch?v=\($0)" }) {
                            NativeVideo(title: pair.block.title.isEmpty ? pair.unit.title : pair.block.title, address: address, desk: desk,
                                        openWeb: openWeb, studiedKey: pair.block.id, autoplay: index != nil,
                                        onEnd: { if current + 1 < list.count { index = current + 1 } })
                                .id(pair.block.id)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.offset) { offset, pair in
                        Button { index = offset } label: {
                            HStack(spacing: 10) {
                                Image(systemName: offset == current ? "play.fill" : (isWatched(pair) ? "checkmark.circle.fill" : "circle"))
                                    .foregroundStyle(offset == current ? tint : (isWatched(pair) ? Carnet.correct : Carnet.inkTertiary))
                                    .frame(width: 18)
                                Text(pair.block.title.isEmpty ? pair.unit.title : pair.block.title)
                                    .foregroundStyle(offset == current ? Carnet.ink : Carnet.inkSecondary)
                                    .lineLimit(1)
                                Spacer()
                                if let duration = pair.block.duration {
                                    Text(NativeVideo.clock(duration)).font(.caption.monospacedDigit()).foregroundStyle(Carnet.inkTertiary)
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(offset == current ? tint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // Vue ici : cochée dans le cours, et achevée sur Courseware.
        .environment(\.markStudied) { block in
            markStudied?(block)
            Task { await desk.courseware.complete(block: block, course: key) }
        }
    }
}
