import SwiftUI

/// Un élément de théorie de la semaine, **avec tout ce qu'il faut regarder**.
///
/// La ligne compacte (titre + pastilles) suffit pour parcourir tout le cours ;
/// pour la semaine, on veut savoir quoi faire : chaque vidéo et chaque support
/// a sa ligne, nommée, ouvrable d'un toucher. « Cours de la semaine 3 » avec
/// une pastille « 5 vidéos ▾ » ne disait pas qu'il s'agissait d'un
/// enregistrement du cours et de deux chapitres du MOOC.
struct WeekTheoryCard: View {
    @Bindable var item: TheoryItem
    var onOpen: () -> Void
    var onBrowse: (BrowsedLink) -> Void

    @Environment(\.modelContext) private var context
    @State private var showsAll = false

    private var tint: Color { Carnet.tint(item.course?.colorHex ?? "#6B655A") }

    /// « Cours » ou « MOOC » : d'où vient ce travail.
    private var kicker: String {
        if item.title.hasPrefix("MOOC") { return "MOOC · à regarder" }
        let videos = links.filter { $0.kind == .video }.count
        let supports = links.count - videos
        switch (videos > 0, supports > 0) {
        case (true, true): return "Cours · enregistrement et supports"
        case (true, false): return "Cours · enregistrement"
        case (false, true): return "Cours · supports"
        default: return "Cours"
        }
    }

    private var title: String {
        let raw = item.title.isEmpty ? item.number : item.title
        return raw.hasPrefix("MOOC · ") ? String(raw.dropFirst("MOOC · ".count)) : raw
    }

    private var links: [ContentLink] {
        let all = item.links.isEmpty && ExerciseLinks.web(item.urlString) != nil
            ? [ContentLink(title: item.title, url: item.urlString, kind: item.kind == .video ? .video : .page)]
            : item.links
        // Les vidéos d'abord, puis les supports.
        let order: [ContentLink.Kind] = [.video, .slides, .notes, .pdf, .page, .solution]
        return all.filter { ExerciseLinks.web($0.url) != nil }
            .sorted { (order.firstIndex(of: $0.kind) ?? 9) < (order.firstIndex(of: $1.kind) ?? 9) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !links.isEmpty {
                CarnetRule(inset: 16)
                let shown = showsAll ? links : Array(links.prefix(5))
                ForEach(Array(shown.enumerated()), id: \.offset) { index, link in
                    resourceRow(link)
                    if index < shown.count - 1 { CarnetRule(inset: 52) }
                }
                if links.count > 5 {
                    CarnetRule(inset: 16)
                    Button {
                        withAnimation(Motion.snappy) { showsAll.toggle() }
                    } label: {
                        Text(showsAll ? "Moins" : "Voir les \(links.count) ressources")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Carnet.inkSecondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: Carnet.sheetCorner, bottomLeadingRadius: Carnet.sheetCorner, style: .continuous)
                .fill(item.isWatched ? Carnet.correct.opacity(0.6) : tint)
                .frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            CheckCircleButton(isOn: item.isWatched, tint: tint, label: "Marquer \(title) vu") {
                item.watchedAt = item.isWatched ? nil : Date()
                if item.watchedAt == nil { item.summarizedAt = nil }
                try? context.save()
                Haptics.soft()
            }
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    CarnetKicker(kicker, color: tint)
                    MathText(title, font: Carnet.serif(.headline))
                        .foregroundStyle(item.isWatched ? Carnet.inkSecondary : Carnet.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(Carnet.inkSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
    }

    /// « 2 vidéos · transparents · 1 h 32 ».
    private var summary: String {
        var parts: [String] = []
        let videos = links.filter { $0.kind == .video }.count
        if videos > 0 { parts.append(videos == 1 ? "1 vidéo" : "\(videos) vidéos") }
        let supports = Set(links.map(\.kind)).subtracting([.video]).map(\.shortLabel).sorted()
        parts.append(contentsOf: supports)
        if item.durationSeconds > 0 { parts.append(DateUtils.durationLabel(seconds: item.durationSeconds)) }
        if item.isWatched { parts.append("vu") }
        return parts.isEmpty ? item.kind.label : parts.joined(separator: " · ")
    }

    private func resourceRow(_ link: ContentLink) -> some View {
        Button {
            if let url = ExerciseLinks.web(link.url) {
                onBrowse(BrowsedLink(title: link.title.isEmpty ? title : link.title, url: url, icon: link.kind.icon))
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: link.kind == .video ? "play.circle.fill" : link.kind.icon)
                    .font(.body)
                    .foregroundStyle(link.kind == .video ? tint : Carnet.inkSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rowTitle(link))
                        .font(.subheadline)
                        .foregroundStyle(Carnet.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(rowDetail(link))
                        .font(.caption)
                        .foregroundStyle(Carnet.inkTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Carnet.inkTertiary)
            }
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(link.kind.chipLabel) : \(rowTitle(link))")
    }

    private func rowTitle(_ link: ContentLink) -> String {
        let text = link.title.isEmpty ? link.kind.chipLabel : link.title
        return text.replacingOccurrences(of: #"\s*\((?:\d+ pages? sur \d+|1 page sur 1)\)"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
    }

    /// « Vidéo · MediaSpace », « Transparents · proginsc.epfl.ch ».
    private func rowDetail(_ link: ContentLink) -> String {
        let site = URL(string: link.url)?.host.map(CarnetTheoryLine.siteName) ?? ""
        return [link.kind.chipLabel, site].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
