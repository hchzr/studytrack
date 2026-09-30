import SwiftUI
import SwiftData

/// Une ligne de théorie sur la feuille d'une semaine : la coche « vu », ce que
/// c'est (vidéo, transparents, section, leçon du MOOC), et le lien direct vers
/// le support — la vidéo elle-même quand il y en a une.
struct CarnetTheoryLine: View {
    @Bindable var item: TheoryItem
    /// Le détail commun à toute la section (« Lecture · Botafogo ») : dit une
    /// fois dans son titre, il n'est pas répété sur chaque ligne.
    var hiddenDetail: String? = nil
    var onOpen: () -> Void
    var onBrowse: (BrowsedLink) -> Void

    @Environment(\.modelContext) private var context

    var body: some View {
        HStack(spacing: 0) {
            CheckCircleButton(isOn: item.isWatched,
                              tint: Carnet.tint(item.course?.colorHex ?? "#6B655A"),
                              label: "Marquer \(item.title) vu") {
                item.watchedAt = item.isWatched ? nil : Date()
                if item.watchedAt == nil { item.summarizedAt = nil }
                try? context.save()
            }
            .padding(.leading, 4)

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(MathMarkup.plain(item.title.isEmpty ? item.number : item.title))
                        .font(.body)
                        .foregroundStyle(item.isWatched ? Carnet.inkSecondary : Carnet.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if detail != hiddenDetail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(Carnet.inkSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let link = primaryLink {
                Button { onBrowse(link) } label: {
                    Image(systemName: link.icon)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Carnet.ink)
                        .frame(width: 32, height: 32)
                        .background(Carnet.sheetRaised, in: Circle())
                        .frame(width: Layout.minTouch, height: Layout.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Ouvrir \(link.title)")
                .padding(.trailing, 4)
            }
        }
        .padding(.vertical, 2)
    }

    /// Le détail partagé par **toutes** les lignes, s'il y en a un.
    static func sharedDetail(_ items: [TheoryItem]) -> String? {
        let details = Set(items.map { CarnetTheoryLine.detail(for: $0) })
        return items.count > 1 && details.count == 1 ? details.first : nil
    }

    private var detail: String { Self.detail(for: item) }

    /// « Vidéo · 1 h 32 · MediaSpace » ; « 3 vidéos · Courseware ».
    static func detail(for item: TheoryItem) -> String {
        var parts: [String] = []
        let videos = item.links.filter { $0.kind == .video }.count
        if videos > 1 {
            parts.append("\(videos) vidéos")
        } else if item.videoCount > 1 {
            parts.append("\(item.videoCount) vidéos")
        } else {
            parts.append(item.kind.label)
        }
        if item.durationSeconds > 0 { parts.append(DateUtils.durationLabel(seconds: item.durationSeconds)) }
        let others = Set(item.links.map(\.kind)).subtracting([.video]).map { $0.shortLabel }.sorted()
        parts.append(contentsOf: others)
        if let host = URL(string: item.links.first?.url ?? item.urlString)?.host {
            parts.append(siteName(host))
        }
        return parts.joined(separator: " · ")
    }

    /// Le support à ouvrir d'un toucher : la vidéo d'abord.
    private var primaryLink: BrowsedLink? {
        let links = item.links
        let chosen = links.first { $0.kind == .video } ?? links.first
        let address = chosen?.url ?? item.urlString
        guard let url = ExerciseLinks.web(address) else { return nil }
        return BrowsedLink(title: chosen?.title ?? item.title, url: url,
                           icon: chosen?.kind.icon ?? item.kind.icon)
    }

    static func siteName(_ host: String) -> String {
        let host = host.lowercased()
        if host.contains("mediaspace") { return "MediaSpace" }
        if host.contains("courseware") { return "Courseware" }
        if host.contains("botafogo") { return "Botafogo" }
        if host.contains("moodle") { return "Moodle" }
        if host.contains("dropbox") { return "Dropbox" }
        if host.contains("github") { return "GitHub" }
        if host.contains("youtube") || host.contains("youtu.be") { return "YouTube" }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}

extension ContentLink.Kind {
    /// « transparents », « notes » : le mot d'une ligne de détail.
    var shortLabel: String {
        switch self {
        case .video: return "vidéo"
        case .slides: return "transparents"
        case .notes: return "notes"
        case .pdf: return "PDF"
        case .page: return "page"
        case .solution: return "corrigé"
        }
    }
}

/// Une ligne d'exercice sur la feuille d'une semaine : son état, son numéro, son
/// titre, ses sous-questions en pastilles et sa correction.
struct CarnetExerciseLine: View {
    let exercise: Exercise

    var body: some View {
        let stage = ExerciseStage(exercise)
        HStack(spacing: 12) {
            ExerciseStageMark(stage: stage, size: 24)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(exercise.exerciseNumber)
                        .font(Carnet.mono(.footnote))
                        .foregroundStyle(Carnet.inkSecondary)
                    Text(MathMarkup.plain(exercise.title.isEmpty ? exercise.displayNumber : exercise.title))
                        .font(.body)
                        .foregroundStyle(Carnet.ink)
                        .lineLimit(1)
                    if exercise.isBonus {
                        Text("bonus").font(.caption).foregroundStyle(Carnet.inkTertiary)
                    }
                }
                let leaves = exercise.leafSubQuestions
                if !leaves.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(leaves.prefix(10)) { question in
                            Text(question.displayLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(question.isDone ? Carnet.ground : Carnet.inkSecondary)
                                .frame(minWidth: 20, minHeight: 20)
                                .padding(.horizontal, 2)
                                .background(question.isDone ? Carnet.ink : Carnet.sheetRaised,
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        if leaves.count > 10 {
                            Text("+\(leaves.count - 10)").font(.caption2).foregroundStyle(Carnet.inkTertiary)
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("\(exercise.subQuestionDoneCount) sous-questions sur \(leaves.count)")
                }
            }
            Spacer(minLength: 4)
            stageLabel(stage)
        }
        .padding(.horizontal, Carnet.rowInset)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func stageLabel(_ stage: ExerciseStage) -> some View {
        switch stage {
        case .corrected(let result):
            Text(result.lineLabel).font(.footnote.weight(.semibold)).foregroundStyle(Carnet.color(for: result))
        case .redo:
            Text("à refaire").font(.footnote.weight(.semibold)).foregroundStyle(Carnet.wrong)
        case .toCorrect:
            Text("à corriger").font(.footnote).foregroundStyle(Carnet.inkSecondary)
        case .inProgress(let done, let total):
            Text("\(done)/\(total)").font(Carnet.mono(.footnote)).foregroundStyle(Carnet.inkSecondary)
        case .toDo:
            EmptyView()
        }
    }
}

extension Correctness {
    /// « juste », « à revoir », « faux » : le mot d'une ligne d'exercice.
    var lineLabel: String {
        switch self {
        case .correct: return "juste"
        case .partial: return "à revoir"
        case .wrong: return "faux"
        }
    }
}
